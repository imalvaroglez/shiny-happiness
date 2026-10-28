import Foundation
import SwiftData
import Testing
@testable import FinanceTracker

@Suite("Property assignment continuation") @MainActor
struct PropertyAssignmentTests {
    private enum Failure: Error { case save }
    private var month: Date { YearMonth(year: 2026, month: 3).startDate }
    private func container() throws -> ModelContainer {
        try ModelContainer(for: AppSchema.schema,
            configurations: [ModelConfiguration(schema: AppSchema.schema, isStoredInMemoryOnly: true)])
    }
    private func fixture() -> (PropertyLedger, PropertyRecord, PropertyResident, PropertyResident) {
        let house = PropertyRecord(name: "Casa de prueba")
        let first = PropertyResident(propertyID: house.id, name: "Integrante uno", activeFrom: month, referenceMonthlyIncome: 1000)
        let second = PropertyResident(propertyID: house.id, name: "Integrante dos", activeFrom: month, referenceMonthlyIncome: 1000)
        var ledger = PropertyLedger(); ledger.properties = [house]; ledger.residents = [first, second]
        ledger.incomes = [first, second].map { PropertyIncome(propertyID: house.id, residentID: $0.id, monthStart: month, amount: 1000, confirmedAt: month) }
        return (ledger, house, first, second)
    }
    private func source(_ amount: Decimal = -100) -> PropertyTransactionInput {
        PropertyTransactionInput(id: UUID(), amount: amount, postedAt: month, description: "Concepto de prueba", accountName: "Cuenta de prueba")
    }
    private func report(_ ledger: PropertyLedger, _ house: PropertyRecord, _ inputs: [PropertyTransactionInput]) -> PropertyMonthlyReport {
        PropertySettlementCalculator.report(propertyID: house.id, month: month, ledger: ledger, transactions: inputs)
    }

    @Test("An editor rejects a financial movement changed in another context")
    func transactionEditorRejectsStaleMovement() throws {
        let container = try container()
        let context = container.mainContext
        let account = Account(institution: "Banco sintético", type: .checking)
        let transaction = Transaction(account: account, postedAt: month, amount: -100, descriptionRaw: "Compra sintética")
        context.insert(account); context.insert(transaction)
        try context.save()
        let source = PropertyTransactionInput(capturing: transaction)
        let revision = transaction.lastModifiedAt
        let id = transaction.id
        try TransactionEditRevisionGuard.validate(transactionID: id, revision: revision,
            accountID: account.id, expected: source, container: container)
        let other = ModelContext(container)
        let changed = try #require(other.fetch(FetchDescriptor<Transaction>(predicate: #Predicate<Transaction> { $0.id == id })).first)
        changed.amount = -200
        try other.save()
        #expect(throws: TransactionEditRevisionGuard.EditError.self) {
            try TransactionEditRevisionGuard.validate(transactionID: id, revision: revision,
                accountID: account.id, expected: source, container: container)
        }
    }

    @Test("A failed promotion write retries only the pending step after clearing the due date")
    func transactionCompletionRetriesOnlyPendingWork() throws {
        var state = TransactionEditCompletion(movementSaved: true, dueDatePending: true,
                                              propertyPending: true, promotionPending: true)
        var calls: [String] = []
        do {
            try state.run(purgeDueDate: { calls.append("due") }, saveProperty: { calls.append("property") },
                savePromotions: { calls.append("promotion"); throw Failure.save })
            Issue.record("The promotion write should fail")
        } catch let error as TransactionEditCompletion.Failure {
            #expect(error.stage == .promotion)
        }
        #expect(calls == ["due", "property", "promotion"])
        #expect(!state.dueDatePending && !state.propertyPending && state.promotionPending)
        calls.removeAll()
        try state.run(purgeDueDate: { calls.append("due") }, saveProperty: { calls.append("property") },
                      savePromotions: { calls.append("promotion") })
        #expect(calls == ["promotion"])
        #expect(!state.promotionPending)
    }

    @Test("Rental bulk assignments preserve metadata, identity, source signs and exact report sums")
    func rentalAssignments() throws {
        let (base, house, first, second) = fixture()
        let a = source(-101.25); let b = source(-500)
        var ledger = base
        let original = PropertyTransactionAttribution(propertyID: house.id, transactionID: a.id, kind: .maintenance,
            responsibility: .owner, coverageStart: month, coverageEnd: month, maintenanceProgramID: UUID(), notes: "Nota conservada")
        ledger.attributions = [original]
        for responsibility in [PropertyResponsibility.owner, .shared, .individual(residentID: first.id), .selected(residentIDs: [first.id, second.id])] {
            ledger = try PropertyAssignmentService.assigning(responsibility, to: [a.id, b.id], propertyID: house.id, ledger: ledger, inputs: [a, b])
            let saved = try #require(ledger.attributions.first { $0.transactionID == a.id && $0.deletedAt == nil })
            #expect(saved.id == original.id)
            #expect(saved.notes == original.notes)
            #expect(saved.coverageStart == original.coverageStart)
            #expect(saved.maintenanceProgramID == original.maintenanceProgramID)
            #expect(saved.sourceSnapshots == original.sourceSnapshots)
            #expect(saved.responsibility == responsibility)
            let result = report(ledger, house, [a, b])
            #expect(result.expenses == 601.25)
            #expect(a.amount == -101.25)
        }
    }

    @Test("Invalid groups, foreign destinations and frozen source rows reject the entire batch")
    func rejectInvalidAssignments() throws {
        let (base, house, first, _) = fixture(); let input = source()
        #expect(throws: (any Error).self) {
            try PropertyAssignmentService.assigning(.selected(residentIDs: [UUID()]), to: [input.id], propertyID: house.id, ledger: base, inputs: [input])
        }
        var ledger = try PropertyAssignmentService.assigning(.shared, to: [input.id], propertyID: house.id, ledger: base, inputs: [input])
        let close = try #require(PropertySettlementCalculator.close(report(ledger, house, [input])))
        ledger.closes = [close]
        #expect(throws: (any Error).self) {
            try PropertyAssignmentService.assigning(.owner, to: [input.id], propertyID: house.id, ledger: ledger, inputs: [input])
        }
        let other = PropertyRecord(name: "Otra casa"); ledger.properties.append(other)
        #expect(!PropertyAssignmentService.isAvailable(input, propertyID: other.id, ledger: ledger))
        #expect(ledger.closes == [close])
        #expect(first.referenceMonthlyIncome == 1000)
    }

    @Test("Departed individual and selected-group members retain charges and block closure")
    func departedMembers() throws {
        let (base, house, first, second) = fixture(); let input = source(-333)
        for responsibility in [PropertyResponsibility.individual(residentID: first.id), .selected(residentIDs: [first.id, second.id])] {
            var ledger = try PropertyAssignmentService.assigning(responsibility, to: [input.id], propertyID: house.id, ledger: base, inputs: [input])
            ledger.residents[0].activeThrough = Calendar.current.date(byAdding: .month, value: -1, to: month)
            let result = report(ledger, house, [input])
            #expect(result.expenses == 333)
            #expect(result.obligations.first?.amount == 333)
            #expect(result.obligations.first?.allocations.isEmpty == true)
            #expect(!result.canClose)
            #expect(result.warnings.contains { $0 == String(format: String(localized: "Assignment needs review: %@. A member no longer participates in this period."), input.description) })
            #expect(ledger.incomes.count == 2)
        }
    }

    @Test("Activity shows source account, positive magnitudes and one row per financial receipt")
    func activityPresentation() throws {
        let (base, house, first, second) = fixture(); let charge = source(-600)
        var receipt = source(500); receipt.isCashAccount = true
        let reimbursement = source(50)
        var ledger = try PropertyAssignmentService.assigning(.shared, to: [charge.id], propertyID: house.id, ledger: base, inputs: [charge])
        let expense = try #require(report(ledger, house, [charge]).obligations.first)
        ledger.attributions.append(PropertyTransactionAttribution(propertyID: house.id, transactionID: reimbursement.id, kind: .reimbursement, responsibility: .owner))
        ledger.paymentApplications = [first, second].map { PropertyPaymentApplication(propertyID: house.id, paymentTransactionID: receipt.id, obligationID: expense.id, residentID: $0.id, amount: 100) }
        let inputs = [charge, receipt, reimbursement]; let result = report(ledger, house, inputs)
        let before = ledger
        let rows = PropertyActivityPresenter.rows(propertyID: house.id, month: month, asOf: .distantFuture, filter: .linked, ledger: ledger, report: result, inputs: inputs)
        #expect(rows.count == 3)
        #expect(rows.first { $0.id == receipt.id }?.amount == 500)
        #expect(rows.first { $0.id == charge.id }?.account == "Cuenta de prueba")
        #expect(rows.first { $0.id == charge.id }?.amount == 600)
        #expect(rows.first { $0.id == reimbursement.id }?.kind == .reimbursement)
        #expect(rows.first { $0.id == receipt.id }?.canAssign == false)
        #expect(ledger == before)
        #expect(report(ledger, house, inputs) == result)
    }

    @Test("Missing and changed sources remain visible with a snapshot and no invented account")
    func sourceFallback() throws {
        let (base, house, _, _) = fixture(); let input = source(-444)
        let ledger = try PropertyAssignmentService.assigning(.shared, to: [input.id], propertyID: house.id, ledger: base, inputs: [input])
        let original = report(ledger, house, [input])
        let missing = PropertyActivityPresenter.rows(propertyID: house.id, month: month, asOf: .distantFuture, filter: .linked, ledger: ledger, report: original, inputs: [])
        #expect(missing.first?.amount == 444)
        #expect(missing.first?.account == nil)
        #expect(missing.first?.canAssign == false)
        #expect(missing.first?.issue != nil)
        var changed = input; changed.amount = -555
        let rows = PropertyActivityPresenter.rows(propertyID: house.id, month: month, asOf: .distantFuture, filter: .linked, ledger: ledger, report: original, inputs: [changed])
        #expect(rows.first?.amount == 555)
        #expect(rows.first?.issue != nil)
    }

    @Test("Unassigned filter excludes existing links, other homes, Household and future sources")
    func unassignedCandidates() throws {
        let (base, house, _, _) = fixture(); let linked = source(); let free = source()
        var household = source(); household.isHouseholdAssigned = true
        var future = source(); future.postedAt = Calendar.current.date(byAdding: .month, value: 1, to: month)!
        var ledger = try PropertyAssignmentService.assigning(.shared, to: [linked.id], propertyID: house.id, ledger: base, inputs: [linked])
        let other = PropertyRecord(name: "Casa distinta"); ledger.properties.append(other)
        let occupied = source()
        ledger.attributions.append(PropertyTransactionAttribution(propertyID: other.id, transactionID: occupied.id, kind: .operation, responsibility: .owner))
        let inputs = [linked, free, household, future, occupied]
        let rows = PropertyActivityPresenter.rows(propertyID: house.id, month: month, asOf: month, filter: .unassigned,
            ledger: ledger, report: report(ledger, house, inputs), inputs: inputs)
        #expect(rows.map(\.id) == [free.id])
    }

    @Test("A movement destined to one property cannot be claimed by another and keeps its single attribution")
    func singleFinancialDestinationMovesBetweenProperties() throws {
        let (base, house, _, _) = fixture(); let input = source(-222)
        var ledger = try PropertyAssignmentService.assigning(.owner, to: [input.id], propertyID: house.id, ledger: base, inputs: [input])
        let original = try #require(ledger.attributions.first { $0.transactionID == input.id && $0.deletedAt == nil })
        let rival = PropertyRecord(name: "Casa rival"); ledger.properties.append(rival)
        #expect(throws: PropertyAssignmentService.AssignmentError.self) {
            _ = try PropertyAssignmentService.assigning(.shared, to: [input.id], propertyID: rival.id, ledger: ledger, inputs: [input])
        }
        var direct = ledger
        do {
            try PropertyAssignmentService.upsert(PropertyTransactionAttribution(propertyID: rival.id,
                transactionID: input.id, kind: .operation, responsibility: .shared), source: input, ledger: &direct)
            Issue.record("The rival destination must be rejected")
        } catch is PropertyAssignmentService.AssignmentError {
            #expect(direct == ledger)
        }
        let live = ledger.attributions.filter { $0.transactionID == input.id && $0.deletedAt == nil }
        #expect(live.map(\.propertyID) == [house.id])
        #expect(live.first?.id == original.id)
        // Re-assigning to the owning house still replaces the same attribution.
        let updated = try PropertyAssignmentService.assigning(.shared, to: [input.id], propertyID: house.id, ledger: ledger, inputs: [input])
        #expect(updated.attributions.filter { $0.transactionID == input.id && $0.deletedAt == nil }.map(\.id) == [original.id])
    }

    @Test("Household isolated save supports custom allocations, preserves repeated shared overrides and rolls back failures")
    func householdAtomicAssignments() throws {
        let container = try container(); let context = container.mainContext
        let account = Account(institution: "Pruebas", type: .checking); context.insert(account)
        let tx = Transaction(account: account, postedAt: month, amount: -500, descriptionRaw: "Gasto")
        tx.setHouseholdScope(.included); tx.setExpenseAssignment(.shared); tx.setSplitMethodOverride(.fiftyFifty); context.insert(tx); try context.save()
        var input = PropertyTransactionInput(id: tx.id, amount: tx.amount, postedAt: tx.postedAt, description: tx.descriptionRaw, isHouseholdAssigned: true)
        let expected = [tx.id: HouseholdAssignmentSnapshot(tx)]
        let same = try PropertyAssignmentService.assignHousehold(.shared, ids: [tx.id], expected: expected, inputs: [input], ledger: PropertyLedger(), container: container)
        #expect(same.transactions.first?.splitMethodOverride == .fiftyFifty)
        let updated = try #require(same.transactions.first)
        let custom = try PropertyAssignmentService.assignHousehold(.custom(ferAmount: 123), ids: [tx.id], expected: [tx.id: HouseholdAssignmentSnapshot(updated)], inputs: [input], ledger: PropertyLedger(), container: container)
        let customTx = try #require(custom.transactions.first)
        #expect(customTx.resolvedHouseholdAllocation == .custom(ferAmount: 123))
        #expect(customTx.amount == -500)
        #expect(throws: Failure.self) {
            try PropertyAssignmentService.assignHousehold(.user, ids: [tx.id], expected: [tx.id: HouseholdAssignmentSnapshot(customTx)], inputs: [input], ledger: PropertyLedger(), container: container, commit: { _ in throw Failure.save })
        }
        let reopened = ModelContext(container); let reloaded = try #require(reopened.fetch(FetchDescriptor<Transaction>()).first)
        #expect(reloaded.resolvedHouseholdAllocation == .custom(ferAmount: 123))
        input.amount = -100
        #expect(throws: (any Error).self) {
            try PropertyAssignmentService.assignHousehold(.partner, ids: [tx.id], expected: [tx.id: HouseholdAssignmentSnapshot(customTx)], inputs: [input], ledger: PropertyLedger(), container: container)
        }
    }
    @Test("Workspace rental edits persist and recompute from a single period fetch")
    func workspaceRentalCacheAndReopen() async throws {
        let container = try container(); let context = container.mainContext
        let account = Account(institution: "Pruebas", type: .checking); context.insert(account)
        let tx = Transaction(account: account, postedAt: month, amount: -800, descriptionRaw: "Gasto compartido")
        tx.setHouseholdScope(.excluded); context.insert(tx); try context.save()
        let (ledger, house, first, _) = fixture()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("assignment-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try PropertyLedgerStore.replace(with: ledger, at: url, notify: false)
        let workspace = PropertyWorkspaceModel(month: month, asOf: .distantFuture, fileURL: url)
        workspace.configure(context: context, hasAccounts: true)
        await workspace.loadLedger(); await workspace.refreshPeriod(); workspace.destination = .property(house.id)
        #expect(workspace.activityRows(filter: .unassigned).map(\.id) == [tx.id])
        #expect(workspace.assign(ids: [tx.id], choice: .member(first.id)))
        #expect(workspace.reports[house.id]?.residents.first { $0.id == first.id }?.individualExpenses == 800)
        #expect(workspace.activityRows(filter: .unassigned).isEmpty)
        #expect(workspace.transactionFetchCount == 1)
        #expect(workspace.assign(ids: [tx.id], choice: .shared))
        #expect(workspace.assign(ids: [tx.id], choice: .member(first.id)))
        let read = try PropertyLedgerStore.read(fileURL: url)
        #expect(read.attributions.first?.responsibility == .individual(residentID: first.id))
        var external = read; external.properties[0].name = "Edición externa"; external.properties[0].updatedAt = .now
        try PropertyLedgerStore.replace(with: external, at: url, notify: false)
        #expect(!workspace.assign(ids: [tx.id], choice: .owner))
        #expect(try PropertyLedgerStore.read(fileURL: url).properties[0].name == "Edición externa")
    }

    @Test("Household assignments never write JSON, reuse cached inputs, and reject concurrent role edits")
    func householdCacheAndConflict() async throws {
        let container = try container(); let context = container.mainContext
        let account = Account(institution: "Pruebas", type: .checking); context.insert(account)
        let tx = Transaction(account: account, postedAt: month, amount: -600, descriptionRaw: "Gasto")
        tx.setHouseholdScope(.excluded); context.insert(tx); try context.save()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("household-assignment-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try PropertyLedgerStore.replace(with: PropertyLedger(), at: url, notify: false)
        let bytes = try Data(contentsOf: url)
        let workspace = PropertyWorkspaceModel(month: month, asOf: .distantFuture, fileURL: url)
        workspace.configure(context: context, hasAccounts: true)
        await workspace.loadLedger(); await workspace.refreshPeriod(); workspace.destination = .household
        #expect(workspace.assign(ids: [tx.id], choice: .shared))
        #expect(workspace.assign(ids: [tx.id], choice: .custom, customAmount: 220))
        #expect(workspace.householdAllocation(for: tx.id) == .custom(ferAmount: 220))
        #expect(tx.resolvedHouseholdAllocation == .custom(ferAmount: 220))
        #expect(workspace.transactionFetchCount == 1)
        #expect(try Data(contentsOf: url) == bytes)
        let external = ModelContext(container)
        let other = try #require(external.fetch(FetchDescriptor<Transaction>()).first)
        try other.setHouseholdAllocation(.partner); try external.save()
        #expect(!workspace.assign(ids: [tx.id], choice: .owner))
        let reopened = ModelContext(container)
        #expect(try reopened.fetch(FetchDescriptor<Transaction>()).first?.resolvedHouseholdAllocation == .partner)
    }

    @Test("A thousand activity rows retain source identity and record presentation cost without screen capture")
    func representativeActivityPerformance() throws {
        let (base, house, _, _) = fixture()
        var ledger = base
        let inputs = (0..<1000).map { index in
            PropertyTransactionInput(id: UUID(), amount: -10, postedAt: month, description: "Gasto \(index)", accountName: "Cuenta de prueba")
        }
        ledger.attributions = inputs.map { PropertyTransactionAttribution(propertyID: house.id, transactionID: $0.id, kind: .operation, responsibility: .owner) }
        let report = report(ledger, house, inputs)
        let start = ContinuousClock.now
        let rows = PropertyActivityPresenter.rows(propertyID: house.id, month: month, asOf: .distantFuture,
            filter: .linked, ledger: ledger, report: report, inputs: inputs)
        let elapsed = start.duration(to: .now)
        print("Property continuation: 1000 activity rows = \(elapsed)")
        #expect(rows.count == 1000)
        #expect(rows.allSatisfy { $0.amount == 10 && $0.account == "Cuenta de prueba" })
    }

    @Test("Rental save rejects a source reassigned externally to Household")
    func rentalStaleSource() async throws {
        let container = try container(); let context = container.mainContext
        let account = Account(institution: "Pruebas", type: .checking); context.insert(account)
        let tx = Transaction(account: account, postedAt: month, amount: -200, descriptionRaw: "Gasto")
        tx.setHouseholdScope(.excluded); context.insert(tx); try context.save()
        let (ledger, house, _, _) = fixture()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stale-source-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try PropertyLedgerStore.replace(with: ledger, at: url, notify: false)
        let workspace = PropertyWorkspaceModel(month: month, asOf: .distantFuture, fileURL: url)
        workspace.configure(context: context, hasAccounts: true)
        await workspace.loadLedger(); await workspace.refreshPeriod(); workspace.destination = .property(house.id)
        let external = ModelContext(container)
        let changed = try #require(external.fetch(FetchDescriptor<Transaction>()).first)
        changed.setHouseholdScope(.included); try external.save()
        #expect(!workspace.assign(ids: [tx.id], choice: .shared))
        #expect(!workspace.linkAttribution(PropertyTransactionAttribution(propertyID: house.id,
            transactionID: tx.id, kind: .operation, responsibility: .shared)))
        #expect(try PropertyLedgerStore.read(fileURL: url).attributions.isEmpty)
    }

    @Test("Household rejects reporting adjustments and rolls back an invalid multi-row custom split")
    func householdEligibilityAndBatchFailure() throws {
        let container = try container(); let context = container.mainContext
        let account = Account(institution: "Pruebas", type: .checking); context.insert(account)
        let adjustment = Transaction(account: account, postedAt: month, amount: -500, descriptionRaw: "Ajuste")
        adjustment.setReportingTreatment(.valuationAdjustment); context.insert(adjustment)
        let small = Transaction(account: account, postedAt: month, amount: -10, descriptionRaw: "Gasto pequeño"); context.insert(small)
        let large = Transaction(account: account, postedAt: month, amount: -500, descriptionRaw: "Gasto grande"); context.insert(large)
        for tx in [adjustment, small, large] { tx.setHouseholdScope(.excluded) }
        try context.save()
        let input = PropertyTransactionInput(capturing: adjustment)
        #expect(!input.isHouseholdEligible)
        #expect(!PropertyAssignmentService.isAvailable(input, propertyID: nil, ledger: PropertyLedger()))
        #expect(throws: (any Error).self) {
            try PropertyAssignmentService.assignHousehold(.shared, ids: [adjustment.id], expected: [adjustment.id: HouseholdAssignmentSnapshot(adjustment)], inputs: [input], ledger: PropertyLedger(), container: container)
        }
        let txs = [large, small]
        #expect(throws: (any Error).self) {
            try PropertyAssignmentService.assignHousehold(.custom(ferAmount: 100), ids: Set(txs.map(\.id)), expected: Dictionary(uniqueKeysWithValues: txs.map { ($0.id, HouseholdAssignmentSnapshot($0)) }), inputs: txs.map { PropertyTransactionInput(capturing: $0) }, ledger: PropertyLedger(), container: container)
        }
        let reopened = ModelContext(container)
        #expect(try reopened.fetch(FetchDescriptor<Transaction>()).allSatisfy { !$0.isIncludedInHouseholdSettlement })
    }

    @Test("Shared-context commit failures restore owned fields and preserve unrelated drafts")
    func sharedContextFailure() throws {
        let container = try container(); let context = container.mainContext
        let account = Account(institution: "Pruebas", type: .checking); context.insert(account)
        let tx = Transaction(account: account, postedAt: month, amount: -100, descriptionRaw: "Gasto")
        tx.setHouseholdScope(.included); tx.setExpenseAssignment(.shared); context.insert(tx)
        let unrelated = Transaction(account: account, postedAt: month, amount: -200, descriptionRaw: "Original")
        context.insert(unrelated); try context.save()
        unrelated.descriptionRaw = "Borrador pendiente"
        let before = HouseholdAssignmentSnapshot(tx)
        #expect(throws: Failure.self) {
            try PropertyAssignmentService.assignHousehold(.partner, ids: [tx.id], expected: [tx.id: before],
                inputs: [PropertyTransactionInput(capturing: tx)], ledger: PropertyLedger(), container: container,
                editingContext: context, registered: [tx], commit: { _ in throw Failure.save })
        }
        #expect(HouseholdAssignmentSnapshot(tx) == before)
        #expect(unrelated.descriptionRaw == "Borrador pendiente")
        try context.save()
        let reopened = ModelContext(container)
        #expect(try reopened.fetch(FetchDescriptor<Transaction>()).first { $0.id == tx.id }?.resolvedHouseholdAllocation == .shared)
    }

    @Test("Leaving an edited row saves only its captured home and month")
    func departingIncomeRowTargetsOriginalPeriod() async throws {
        let container = try container()
        let (ledger, house, member, _) = fixture()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("income-row-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try PropertyLedgerStore.replace(with: ledger, at: url, notify: false)
        let workspace = PropertyWorkspaceModel(month: month, fileURL: url)
        workspace.configure(context: container.mainContext, hasAccounts: false)
        await workspace.loadLedger(); await workspace.refreshPeriod()
        workspace.destination = .property(house.id)
        workspace.shiftMonth(1); workspace.destination = .household
        // Join the period task before releasing the in-memory container at test teardown.
        await workspace.refreshPeriod()
        #expect(workspace.saveMonthlyIncome(residentID: member.id, amount: 1700, confirmed: false,
            month: month, editedDestination: .property(house.id)))
        let stored = try PropertyLedgerStore.read(fileURL: url)
        #expect(stored.incomes.first { $0.residentID == member.id && $0.monthStart == month && $0.deletedAt == nil }?.amount == 1700)
        #expect(stored.incomes.first { $0.residentID == member.id && $0.monthStart == workspace.selectedMonth } == nil)
        #expect(stored.householdLink == nil)
    }

    @Test("Explicit custom amounts replace equal legacy percentages and stay fixed after source corrections")
    func customEqualityNormalizesLegacyOverride() throws {
        let container = try container(); let context = container.mainContext
        let account = Account(institution: "Pruebas", type: .checking); context.insert(account)
        let tx = Transaction(account: account, postedAt: month, amount: -500, descriptionRaw: "Gasto")
        tx.setHouseholdScope(.included); tx.setExpenseAssignment(.shared); tx.setSplitMethodOverride(.fiftyFifty)
        context.insert(tx); try context.save()
        #expect(tx.resolvedHouseholdAllocation == .custom(ferAmount: 250))
        _ = try PropertyAssignmentService.assignHousehold(.custom(ferAmount: 250), ids: [tx.id],
            expected: [tx.id: HouseholdAssignmentSnapshot(tx)], inputs: [PropertyTransactionInput(capturing: tx)],
            ledger: PropertyLedger(), container: container, editingContext: context, registered: [tx])
        #expect(tx.expenseAssignment == .custom)
        #expect(tx.splitMethodOverride == .monthlyDefault)
        tx.amount = -600
        #expect(tx.resolvedHouseholdAllocation == .custom(ferAmount: 250))
    }

    @Test("Household removal changes shared participation, preserves individual charges and survives reopening")
    func householdMemberRemoval() async throws {
        let container = try container(); let context = container.mainContext
        let account = Account(institution: "Pruebas", type: .checking); context.insert(account)
        let shared = Transaction(account: account, postedAt: month, amount: -100, descriptionRaw: "Gasto compartido")
        let individual = Transaction(account: account, postedAt: month, amount: -50, descriptionRaw: "Gasto individual")
        let deferred = Transaction(account: account, postedAt: month, amount: -75, descriptionRaw: "Gasto aplazado")
        let nextMonth = YearMonth(date: month).addingMonths(1).startDate
        for tx in [shared, individual, deferred] { context.insert(tx); tx.setHouseholdScope(.included) }
        shared.setExpenseAssignment(.shared); individual.setExpenseAssignment(.partner); deferred.setExpenseAssignment(.partner)
        context.insert(SettlementDueDateOverride(transactionID: deferred.id, dueDate: nextMonth))
        try context.save()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("member-actions-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let workspace = PropertyWorkspaceModel(month: month, asOf: .distantFuture, fileURL: url)
        workspace.configure(context: context, hasAccounts: true)
        await workspace.loadLedger(); await workspace.refreshPeriod(); workspace.destination = .household
        let roles = PropertyHouseholdAdapter.link
        #expect(workspace.ledger.householdLink == nil)
        #expect(workspace.member(id: roles.partnerID)?.name == "Fer")
        #expect(workspace.ledger.householdLink == nil) // Opening rename is a read.
        #expect(workspace.renameMember(id: roles.partnerID, name: "Integrante de prueba"))
        #expect(workspace.saveMonthlyIncome(residentID: roles.userID, amount: 1000, confirmed: true, month: month))
        #expect(workspace.saveMonthlyIncome(residentID: roles.partnerID, amount: 1000, confirmed: true, month: month))
        let original = try #require(workspace.householdMonthlyReport)
        #expect(original.canClose)
        let close = try #require(PropertySettlementCalculator.close(original))
        let fetches = workspace.transactionFetchCount
        #expect(workspace.removeMember(id: roles.partnerID, today: month))
        #expect(workspace.householdActiveMemberIDs == [roles.userID])
        #expect(workspace.householdReport?.userFairShare == 100)
        #expect(workspace.householdReport?.partnerFairShare == 0)
        #expect(workspace.householdReport?.partnerOnlyTotal == 50)
        #expect(workspace.householdReport?.pendingForUpcomingMonths == 75)
        #expect(workspace.householdDueDates[deferred.id] == nextMonth)
        let open = try #require(workspace.householdMonthlyReport)
        #expect(open.obligations.first { $0.transactionID == individual.id }?.allocations[roles.partnerID] == 50)
        #expect(!open.canClose)
        #expect(workspace.activityRows(filter: .linked).first { $0.id == individual.id }?.issue == String(localized: "Assignment needs review"))
        #expect(workspace.activityRows(filter: .linked).first { $0.id == deferred.id }?.issue == String(localized: "Assignment needs review"))
        #expect(!open.obligations.contains { $0.transactionID == deferred.id })
        #expect(open.warnings.contains { $0.contains(deferred.descriptionRaw) })
        #expect(!workspace.assign(ids: [shared.id], choice: .partner))
        #expect(workspace.transactionFetchCount == fetches)
        #expect(shared.amount == -100 && individual.amount == -50)
        let stored = try PropertyLedgerStore.read(fileURL: url)
        #expect(stored.householdMonths?.first?.partnerConfirmedAt != nil)
        #expect(stored.residents.first { $0.id == roles.partnerID }?.name == "Integrante de prueba")
        #expect(PropertyHouseholdAdapter.activeMemberIDs(ledger: stored, month: month) == [roles.userID])
        let previous = Calendar.current.date(byAdding: .month, value: -1, to: month)!
        #expect(PropertyHouseholdAdapter.activeMemberIDs(ledger: stored, month: previous).count == 2)
        var closedLedger = stored; closedLedger.closes = [close]
        let frozen = PropertyHouseholdAdapter.report(try #require(workspace.householdReport), ledger: closedLedger,
            transactions: workspace.transactionInputs, asOf: .distantFuture)
        #expect(frozen.obligations == close.obligations)
        #expect(frozen.residents.count == 2)
        let former = try #require(frozen.residents.first { $0.id == roles.partnerID })
        #expect(former.sharedExpenses + former.individualExpenses == 100)
        workspace.ledger = closedLedger; workspace.recompute()
        let afterRemovalSummary = try #require(workspace.householdSummary)
        let memberIndex = try #require(workspace.ledger.residents.firstIndex { $0.id == roles.partnerID })
        workspace.ledger.residents[memberIndex].activeThrough = nil; workspace.recompute()
        #expect(workspace.householdReport?.partnerFairShare == 50)
        #expect(workspace.householdSummary == afterRemovalSummary)
    }

    @Test("Direct rental actions rename only the name and retain history; failed removal restores memory and disk")
    func rentalMemberActions() async throws {
        let container = try container()
        var (ledger, house, first, _) = fixture()
        ledger.residents[0].notes = "Nota previa"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rental-member-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try PropertyLedgerStore.replace(with: ledger, at: url, notify: false)
        let workspace = PropertyWorkspaceModel(month: month, fileURL: url)
        workspace.configure(context: container.mainContext, hasAccounts: false)
        await workspace.loadLedger(); await workspace.refreshPeriod(); workspace.destination = .property(house.id)
        #expect(workspace.renameMember(id: first.id, name: "Nombre nuevo"))
        #expect(workspace.member(id: first.id)?.notes == "Nota previa")
        #expect(workspace.member(id: first.id)?.activeFrom == first.activeFrom)
        let before = try PropertyLedgerStore.read(fileURL: url)
        workspace.ledger.incomes[0].amount = -1 // Invalid draft forces atomic save failure.
        #expect(!workspace.removeMember(id: first.id, today: month))
        #expect(workspace.member(id: first.id)?.activeThrough == nil)
        #expect(try PropertyLedgerStore.read(fileURL: url) == before)
        #expect(workspace.removeMember(id: first.id, today: month))
        let saved = try PropertyLedgerStore.read(fileURL: url)
        #expect(saved.residents(for: house.id, month: month).map(\.id) == [ledger.residents[1].id])
        #expect(saved.incomes == before.incomes)
        #expect(saved.residents.first { $0.id == first.id }?.deletedAt == nil)
        #expect(saved.residents.first { $0.id == first.id }?.notes == "Nota previa")
    }

    @Test("Household participation handles either remaining role and no active roles without changing stored amounts")
    func householdParticipationRoles() throws {
        let container = try container(); let context = container.mainContext
        let account = Account(institution: "Pruebas", type: .checking); context.insert(account)
        let tx = Transaction(account: account, postedAt: month, amount: -123, descriptionRaw: "Gasto compartido")
        context.insert(tx); tx.setHouseholdScope(.included); tx.setExpenseAssignment(.shared)
        let setup = HouseholdSettlementSetup(partnerIncomeEstimate: 1000)
        let partner = HouseholdSettlementReportService.build(monthStart: month, transactions: [tx], dueDates: [:],
            setup: setup, participatingUser: false, participatingPartner: true)
        #expect(partner.partnerFairShare == 123 && partner.userFairShare == 0 && partner.splitAvailable)
        let zero = HouseholdSettlementReportService.build(monthStart: month, transactions: [tx], dueDates: [:],
            setup: .empty, participatingUser: false, participatingPartner: true)
        #expect(!zero.splitAvailable && zero.partnerFairShare == 0 && zero.totalSharedExpenses == 123)
        let neither = HouseholdSettlementReportService.build(monthStart: month, transactions: [tx], dueDates: [:],
            setup: setup, participatingUser: false, participatingPartner: false)
        #expect(!neither.splitAvailable)
        #expect(neither.totalSharedExpenses == 123 && neither.partnerFairShare == 0 && neither.userFairShare == 0)
        #expect(tx.amount == -123 && tx.expenseAssignment == .shared)
    }

    @Test("Activity footer counts unique visible rows and separates currencies, types and unknown amounts")
    func activityFooterAndFilters() {
        let a = PropertyActivityRow(id: UUID(), date: month, concept: "Compra A", account: "Cuenta A",
            kind: .expense, amount: 10.25, currency: "MXN", responsibility: "Compartido", canAssign: true, isClosed: false)
        var b = a; b.id = UUID(); b.amount = 20.75; b.account = "Cuenta B"
        var receipt = a; receipt.id = UUID(); receipt.kind = .collection; receipt.amount = 50
        var refund = a; refund.id = UUID(); refund.kind = .reimbursement; refund.amount = 5
        var foreign = a; foreign.id = UUID(); foreign.currency = "USD"; foreign.amount = 7; foreign.responsibility = "Individual"
        var missing = foreign; missing.id = UUID(); missing.amount = nil; missing.account = nil
        let rows = [a, b, receipt, refund, foreign, missing, a]
        let summary = PropertyActivitySummary(rows: rows)
        #expect(summary.count == 6 && summary.missingAmountCount == 1)
        #expect(summary.totals.first { $0.kind == .expense && $0.currency == "MXN" }?.amount == 31)
        #expect(summary.totals.first { $0.kind == .expense && $0.currency == "USD" }?.amount == 7)
        #expect(summary.totals.first { $0.kind == .collection }?.amount == 50)
        #expect(summary.totals.first { $0.kind == .reimbursement }?.amount == 5)
        let activity = PropertyActivitySummary.linkedExpensesAndReimbursements(rows)
        let activitySummary = PropertyActivitySummary(rows: activity)
        #expect(!activity.contains { $0.kind == .collection })
        #expect(activitySummary.count == 5)
        #expect(activitySummary.totals.first { $0.kind == .expense && $0.currency == "MXN" }?.amount == 31)
        #expect(activitySummary.totals.first { $0.kind == .reimbursement }?.amount == 5)
        let filters = PropertyActivityColumnFilters(accounts: ["Cuenta A", "Cuenta B"], responsibilities: ["Compartido"])
        #expect(filters.isActive)
        let filtered = filters.apply(to: rows)
        #expect(PropertyActivitySummary(rows: filtered).count == 4)
        let noMatch = PropertyActivityColumnFilters(accounts: ["Cuenta B"], responsibilities: ["Individual"]).apply(to: rows)
        #expect(PropertyActivitySummary(rows: noMatch).count == 0)
        #expect(PropertyActivitySummary(rows: noMatch).totals.isEmpty)
        #expect(PropertyActivitySummary(rows: [missing]).totals.first?.amount == nil)
        #expect(PropertyActivityColumnFilters(accounts: [String(localized: "Account unavailable")]).apply(to: rows).map(\.id) == [missing.id])
    }

    @Test("Category distribution contains only linked expenses, exact magnitudes and separate currencies")
    func propertyCategoryDistribution() {
        let category = UUID()
        let a = PropertyActivityRow(id: UUID(), date: month, concept: "Compra", account: "Cuenta A",
            kind: .expense, amount: 10.25, currency: "MXN", responsibility: "Compartido", canAssign: true,
            isClosed: false, categoryID: category, categoryName: "Categoría de prueba")
        var b = a; b.id = UUID(); b.amount = 20.75
        var receipt = a; receipt.id = UUID(); receipt.kind = .collection; receipt.amount = 90
        var refund = receipt; refund.id = UUID(); refund.kind = .reimbursement
        var foreign = a; foreign.id = UUID(); foreign.currency = "USD"; foreign.amount = 7
        var unavailable = a; unavailable.id = UUID(); unavailable.categoryID = nil; unavailable.categoryName = nil; unavailable.amount = 3
        var uncategorized = unavailable; uncategorized.id = UUID(); uncategorized.categoryName = String(localized: "Uncategorized"); uncategorized.amount = 4
        var missing = a; missing.id = UUID(); missing.amount = nil
        let rows = [a, b, receipt, refund, foreign, unavailable, uncategorized, missing, a]
        let groups = PropertyExpenseFlow.groups(rows: rows)
        let mxn = groups.first { $0.currency == "MXN" }
        #expect(mxn?.total == 38)
        #expect(mxn?.nodes.first { $0.colorID == category && $0.stage == .categories }?.amount == 31)
        // The 31 category alone crosses the 30.4 budget, so the compact graph keeps it
        // visible and groups Uncategorized (4) plus Category unavailable (3) into a 7 Others node.
        let compact = mxn?.nodes.filter { $0.stage == .categories } ?? []
        #expect(compact.count == 2)
        #expect(compact.contains { $0.name == String(localized: "Other categories") && $0.amount == 7 })
        // The expanded presentation still lists the three real categories with exact amounts.
        let full = PropertyExpenseFlow.groups(rows: rows, expanded: true)
            .first { $0.currency == "MXN" }?.nodes.filter { $0.stage == .categories } ?? []
        #expect(full.map(\.amount) == [31, 4, 3])
        #expect(full.first { $0.colorID == category }?.name == "Categoría de prueba")
        #expect(full.contains { $0.name == String(localized: "Uncategorized") && $0.amount == 4 })
        #expect(full.contains { $0.name == String(localized: "Category unavailable") && $0.amount == 3 })
        #expect(groups.first { $0.currency == "USD" }?.total == 7)
        #expect(PropertyExpenseFlow.groups(rows: [receipt, refund, missing]).isEmpty)
    }

    @Test("Member percentages use report shares, preserve frozen shares and distinguish unknown from confirmed zero")
    func memberContributionPercentages() throws {
        let (base, house, first, _) = fixture(); let input = source(-100)
        var ledger = try PropertyAssignmentService.assigning(.shared, to: [input.id], propertyID: house.id, ledger: base, inputs: [input])
        let original = report(ledger, house, [input])
        let close = try #require(PropertySettlementCalculator.close(original))
        #expect(PropertyMonthlyMemberRow.rows(report: original, canCalculate: true, isClosed: false, historical: false).allSatisfy { $0.share == 0.5 && !$0.shareIsEstimated })
        ledger.incomes[0].amount = 0
        let zero = report(ledger, house, [input])
        #expect(PropertyMonthlyMemberRow.rows(report: zero, canCalculate: true, isClosed: false, historical: false).first { $0.memberID == first.id }?.share == 0)
        #expect(PropertyMonthlyMemberRow.rows(report: zero, canCalculate: false, isClosed: false, historical: false).first { $0.memberID == first.id }?.share == 0)
        var noIncome = ledger; noIncome.incomes[1].amount = 0
        #expect(PropertyMonthlyMemberRow.rows(report: report(noIncome, house, [input]), canCalculate: false, isClosed: false, historical: false).allSatisfy { $0.share == nil })
        let frozen = PropertySettlementCalculator.frozenReport(close, ledger: ledger, transactions: [input])
        let closedMembers = PropertyMonthlyMemberRow.rows(report: frozen, canCalculate: false, isClosed: true, historical: false)
        let closedFlow = PropertyExpenseFlow.groups(rows: [PropertyActivityRow(id: input.id, date: input.postedAt,
            concept: "Fixture expense", kind: .expense, amount: 100, currency: "MXN", responsibility: "Individual",
            canAssign: false, isClosed: true)], contributors: closedMembers.map(PropertyExpenseFlow.Contributor.init)).first
        #expect(closedFlow?.contributionsAvailable == true)
        #expect(closedFlow?.nodes.filter { $0.stage == .contributors }.allSatisfy { $0.contributionShare == 0.5 && !$0.estimated } == true)
        #expect(PropertyMonthlyMemberRow.rows(report: frozen, canCalculate: false, isClosed: true, historical: false).allSatisfy { $0.share == 0.5 && !$0.shareIsEstimated })
        ledger.incomes[1].confirmedAt = nil
        #expect(PropertyMonthlyMemberRow.rows(report: report(ledger, house, [input]), canCalculate: true, isClosed: false, historical: false).allSatisfy { $0.shareIsEstimated })
    }

    @Test("Category inputs are captured once and 1,000-row summary preparation remains in memory")
    func categoryInputAndSummaryPreparation() throws {
        let container = try container(); let context = container.mainContext
        let account = Account(institution: "Pruebas", type: .checking); context.insert(account)
        let category = Category(name: "Categoría de prueba"); context.insert(category)
        let tx = Transaction(account: account, postedAt: month, amount: -12.50, descriptionRaw: "Compra")
        tx.category = category; context.insert(tx)
        let captured = PropertyTransactionInput(capturing: tx)
        #expect(captured.categoryID == category.id && captured.categoryName == category.localizedName)
        try context.save()
        let root = Category(name: "Raíz de prueba"); context.insert(root)
        category.parent = root
        category.name = "Categoría actual"; try context.save()
        #expect(PropertyTransactionInput(capturing: tx).categoryHierarchy == .path([
            .init(id: root.id, name: root.localizedName), .init(id: category.id, name: category.localizedName)]))
        try PropertyAssignmentService.validateRentalSources(ids: [tx.id], inputs: [captured], container: container)
        _ = try PropertyAssignmentService.assignHousehold(.shared, ids: [tx.id],
            expected: [tx.id: HouseholdAssignmentSnapshot(tx)], inputs: [captured], ledger: PropertyLedger(),
            container: container, editingContext: context, registered: [tx])
        #expect(tx.category?.name == "Categoría actual")
        let rows = (0..<1000).map { _ in
            PropertyActivityRow(id: UUID(), date: month, concept: "Compra", account: "Cuenta de prueba",
                kind: .expense, amount: 12.50, currency: "MXN", responsibility: "Compartido", canAssign: true,
                isClosed: false, categoryID: category.id, categoryName: category.localizedName)
        }
        let start = ContinuousClock.now
        let summary = PropertyActivitySummary(rows: rows)
        let groups = PropertyExpenseFlow.groups(rows: rows)
        let duration = start.duration(to: .now)
        print("Property report summary, 1000 rows: \(duration)")
        #expect(summary.count == 1000 && summary.totals.first?.amount == 12500)
        #expect(groups.first?.total == 12500)
        #expect(tx.amount == -12.50)
    }

}
