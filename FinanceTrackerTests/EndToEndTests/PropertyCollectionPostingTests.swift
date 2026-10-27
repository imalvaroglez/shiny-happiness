import Foundation
import SwiftData
import Testing
@testable import FinanceTracker

@Suite("Property collection posting")
struct PropertyCollectionPostingTests {
    private func date(_ month: Int, _ day: Int = 1) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!
    }

    private func fixture(rent: Decimal = 100, expense: Decimal = 50) -> (PropertyLedger, PropertyRecord, PropertyResident, [PropertyTransactionInput]) {
        let house = PropertyRecord(name: "Casa sintética")
        let resident = PropertyResident(propertyID: house.id, name: "Integrante", activeFrom: date(8), referenceMonthlyIncome: 1_000)
        let chargeID = UUID()
        var ledger = PropertyLedger()
        ledger.properties = [house]
        ledger.residents = [resident]
        ledger.incomes = [8, 9].map { month in
            PropertyIncome(propertyID: house.id, residentID: resident.id, monthStart: date(month),
                amount: 1_000, confirmedAt: date(month))
        }
        ledger.rents = [PropertyRentAgreement(propertyID: house.id, monthlyAmount: rent, effectiveMonth: date(8))]
        ledger.attributions = [PropertyTransactionAttribution(propertyID: house.id, transactionID: chargeID,
            kind: .operation, responsibility: .shared)]
        let inputs = [PropertyTransactionInput(id: chargeID, amount: -expense, postedAt: date(8, 4),
            description: "Servicio", isCashAccount: true)]
        return (ledger, house, resident, inputs)
    }

    @Test("Oldest month, rent then expenses, then current rent; exact partial amount")
    func oldDebtPriority() throws {
        var (ledger, house, resident, inputs) = fixture()
        let august = PropertySettlementCalculator.report(propertyID: house.id, month: date(8), ledger: ledger,
            transactions: inputs, asOf: date(10))
        ledger.closes = [try #require(PropertySettlementCalculator.close(august, at: date(8, 31)))]
        let september = PropertySettlementCalculator.report(propertyID: house.id, month: date(9), ledger: ledger,
            transactions: inputs, asOf: date(10))
        let receipt = PropertyTransactionInput(id: UUID(), amount: 175, postedAt: date(9, 10),
            description: "Cobro", isCashAccount: true)
        inputs.append(receipt)
        let plan = try #require(PropertyCollectionPosting.plan(propertyID: house.id, residentID: resident.id,
            report: september, ledger: ledger, inputs: inputs, receipt: receipt, asOf: date(10)))
        #expect(plan.applications.map(\.amount) == [100, 50, 25])
        #expect(plan.applications.map(\.obligationID) == [ledger.closes[0].obligations.first(where: \.isRent)!.id,
            ledger.closes[0].obligations.first(where: { !$0.isRent })!.id,
            september.obligations.first(where: \.isRent)!.id])
        #expect(plan.applications.reduce(Decimal.zero) { $0 + $1.amount } == receipt.amount)
        ledger.paymentApplications += plan.applications
        #expect(PropertyCollectionPosting.plan(propertyID: house.id, residentID: resident.id,
            report: september, ledger: ledger, inputs: inputs, receipt: receipt, asOf: date(10))?.applications.isEmpty == true)
    }

    @Test("Excess is member-specific and an early receipt remains an advance until its obligation month")
    func earlyAdvanceAndLaterApplication() throws {
        var (ledger, house, resident, inputs) = fixture(rent: 100, expense: 0)
        let receipt = PropertyTransactionInput(id: UUID(), amount: 130, postedAt: date(8, 5),
            description: "Cobro adelantado", isCashAccount: true)
        inputs.append(receipt)
        let august = PropertySettlementCalculator.report(propertyID: house.id, month: date(8), ledger: ledger,
            transactions: inputs, asOf: date(8, 10))
        let first = try #require(PropertyCollectionPosting.plan(propertyID: house.id, residentID: resident.id,
            report: august, ledger: ledger, inputs: inputs, receipt: receipt, asOf: date(8, 10)))
        #expect(first.applications.map(\.amount) == [100, 30])
        #expect(PropertyPaymentAdvance.isAdvance(first.applications[1]))
        #expect(first.applications[1].residentID == resident.id)
        ledger.paymentApplications += first.applications
        ledger.closes = [try #require(PropertySettlementCalculator.close(august, at: date(8, 31)))]
        let september = PropertySettlementCalculator.report(propertyID: house.id, month: date(9), ledger: ledger,
            transactions: inputs, asOf: date(9, 10))
        let later = try #require(PropertyCollectionPosting.plan(propertyID: house.id, residentID: resident.id,
            report: september, ledger: ledger, inputs: inputs, receipt: receipt, asOf: date(9, 10)))
        #expect(later.applications.map(\.amount) == [30])
        #expect(later.updatedAdvances.count == 1)
        #expect(later.updatedAdvances[0].deletedAt != nil)
        ledger.paymentApplications[ledger.paymentApplications.firstIndex(where: { $0.id == later.updatedAdvances[0].id })!] = later.updatedAdvances[0]
        ledger.paymentApplications += later.applications
        #expect(ledger.paymentApplications.filter { $0.paymentTransactionID == receipt.id && $0.deletedAt == nil }
            .reduce(Decimal.zero) { $0 + $1.amount } == receipt.amount)
        #expect(PropertyCollectionPosting.memberAdvances(propertyID: house.id, residentID: resident.id,
            ledger: ledger, inputs: inputs, asOf: date(9, 10)) == 0)
    }

    @Test("A legacy unassigned advance can be reconciled to one member and keeps its source")
    func legacyAdvanceReconciliation() throws {
        var (ledger, house, resident, inputs) = fixture(rent: 100, expense: 0)
        let receipt = PropertyTransactionInput(id: UUID(), amount: 150, postedAt: date(8, 5),
            description: "Anticipo antiguo", isCashAccount: true)
        inputs.append(receipt)
        let advanceID = PropertyPaymentAdvance.obligationID(propertyID: house.id, paymentTransactionID: receipt.id)
        ledger.paymentApplications = [PropertyPaymentApplication(id: advanceID, propertyID: house.id,
            paymentTransactionID: receipt.id, obligationID: advanceID,
            residentID: PropertyPaymentAdvance.placeholderResidentID(propertyID: house.id),
            amount: 150, snapshots: PropertySourceSnapshots(capturing: receipt))]
        #expect(PropertyLedgerStore.validate(ledger).isEmpty)
        let september = PropertySettlementCalculator.report(propertyID: house.id, month: date(9),
            ledger: ledger, transactions: inputs, asOf: date(9, 10))
        let proposal = try #require(PropertyCollectionPosting.plan(propertyID: house.id, residentID: resident.id,
            report: september, ledger: ledger, inputs: inputs, receipt: receipt, asOf: date(9, 10)))
        #expect(proposal.applications.map(\.amount) == [100])
        #expect(proposal.updatedAdvances.first?.residentID == resident.id)
        #expect(proposal.updatedAdvances.first?.amount == 50)
        ledger.paymentApplications[0] = try #require(proposal.updatedAdvances.first)
        ledger.paymentApplications += proposal.applications
        #expect(PropertyLedgerStore.validate(ledger).isEmpty)
        #expect(PropertyCollectionPosting.legacyAdvances(propertyID: house.id, ledger: ledger,
            inputs: inputs, asOf: date(9, 10)) == 0)
        #expect(PropertyCollectionPosting.memberAdvances(propertyID: house.id, residentID: resident.id,
            ledger: ledger, inputs: inputs, asOf: date(9, 10)) == 50)
    }

    @Test("An unavailable legacy advance remains identifiable for review")
    func unavailableLegacyAdvanceRemainsReviewable() {
        var (ledger, house, _, _) = fixture(rent: 100, expense: 0)
        let receipt = PropertyTransactionInput(id: UUID(), amount: 80, postedAt: date(8, 5),
            description: "Anticipo sintético", isCashAccount: true)
        let placeholder = PropertyPaymentAdvance.placeholderResidentID(propertyID: house.id)
        let advanceID = PropertyPaymentAdvance.obligationID(propertyID: house.id, paymentTransactionID: receipt.id)
        let application = PropertyPaymentApplication(id: advanceID, propertyID: house.id,
            paymentTransactionID: receipt.id, obligationID: advanceID, residentID: placeholder,
            amount: 80, snapshots: PropertySourceSnapshots(capturing: receipt))
        ledger.paymentApplications = [application]
        #expect(PropertyCollectionPosting.legacyAdvances(propertyID: house.id, ledger: ledger, inputs: [], asOf: date(9)) == 0)
        #expect(PropertyCollectionPosting.hasChangedAdvanceSource(propertyID: house.id, residentID: placeholder,
            ledger: ledger, inputs: []))
        #expect(PropertyCollectionHistory.includes(application, source: nil, obligationIDs: [], asOf: date(9)))
    }

    @Test("A changed linked source cannot allocate additional money silently")
    func changedReceiptIsRejected() throws {
        var (ledger, house, resident, inputs) = fixture()
        let original = PropertyTransactionInput(id: UUID(), amount: 100, postedAt: date(8, 5),
            description: "Cobro original", isCashAccount: true)
        let advanceID = PropertyPaymentAdvance.obligationID(propertyID: house.id, paymentTransactionID: original.id)
        ledger.paymentApplications = [PropertyPaymentApplication(id: advanceID, propertyID: house.id,
            paymentTransactionID: original.id, obligationID: advanceID, residentID: resident.id,
            amount: 100, snapshots: PropertySourceSnapshots(capturing: original))]
        let changed = PropertyTransactionInput(id: original.id, amount: 120, postedAt: original.postedAt,
            description: original.description, isCashAccount: true)
        inputs.append(changed)
        let report = PropertySettlementCalculator.report(propertyID: house.id, month: date(9),
            ledger: ledger, transactions: inputs, asOf: date(9, 10))
        #expect(PropertyCollectionPosting.plan(propertyID: house.id, residentID: resident.id,
            report: report, ledger: ledger, inputs: inputs, receipt: changed, asOf: date(9, 10))?.applications == nil)
    }

    @Test("A later receipt cannot spend an advance whose original source changed")
    func changedPriorAdvanceIsRejected() {
        var (ledger, house, resident, inputs) = fixture(rent: 100, expense: 0)
        let original = PropertyTransactionInput(id: UUID(), amount: 100, postedAt: date(8, 5),
            description: "Anticipo", isCashAccount: true)
        let advanceID = PropertyPaymentAdvance.obligationID(propertyID: house.id, paymentTransactionID: original.id)
        ledger.paymentApplications = [PropertyPaymentApplication(id: advanceID, propertyID: house.id,
            paymentTransactionID: original.id, obligationID: advanceID, residentID: resident.id,
            amount: 100, snapshots: PropertySourceSnapshots(capturing: original))]
        let changed = PropertyTransactionInput(id: original.id, amount: 50, postedAt: original.postedAt,
            description: original.description, isCashAccount: true)
        let newReceipt = PropertyTransactionInput(id: UUID(), amount: 100, postedAt: date(9, 10),
            description: "Otro cobro", isCashAccount: true)
        inputs += [changed, newReceipt]
        let report = PropertySettlementCalculator.report(propertyID: house.id, month: date(9),
            ledger: ledger, transactions: inputs, asOf: date(9, 10))
        #expect(PropertyCollectionPosting.hasChangedAdvanceSource(propertyID: house.id,
            residentID: resident.id, ledger: ledger, inputs: inputs))
        #expect(PropertyCollectionPosting.memberAdvances(propertyID: house.id, residentID: resident.id,
            ledger: ledger, inputs: inputs, asOf: date(9, 10)) == 0)
        #expect(PropertyCollectionPosting.plan(propertyID: house.id, residentID: resident.id,
            report: report, ledger: ledger, inputs: inputs, receipt: newReceipt, asOf: date(9, 10)) == nil)
    }

    @Test("An available advance covers the oldest due months using its existing movement")
    func availableAdvanceCoversOldestDueMonthsUsingExistingMovement() throws {
        var (ledger, house, resident, inputs) = fixture()
        let august = PropertySettlementCalculator.report(propertyID: house.id, month: date(8), ledger: ledger,
            transactions: inputs, asOf: date(10))
        ledger.closes = [try #require(PropertySettlementCalculator.close(august, at: date(8, 31)))]
        let september = PropertySettlementCalculator.report(propertyID: house.id, month: date(9), ledger: ledger,
            transactions: inputs, asOf: date(10))
        // One existing movement backs a 260 advance; the member owes the closed
        // August debt (150) plus the open September rent (100).
        let movement = PropertyTransactionInput(id: UUID(), amount: 260, postedAt: date(8, 20),
            description: "Cobro adelantado", isCashAccount: true)
        inputs.append(movement)
        let advanceID = PropertyPaymentAdvance.obligationID(propertyID: house.id, paymentTransactionID: movement.id)
        ledger.paymentApplications = [PropertyPaymentApplication(id: advanceID, propertyID: house.id,
            paymentTransactionID: movement.id, obligationID: advanceID, residentID: resident.id,
            amount: 260, snapshots: PropertySourceSnapshots(capturing: movement))]
        let plan = try #require(PropertyCollectionPosting.applyAdvances(propertyID: house.id,
            residentID: resident.id, report: september, ledger: ledger, inputs: inputs, asOf: date(10)))
        #expect(plan.applications.map(\.amount) == [100, 50, 100])
        #expect(plan.applications.map(\.obligationID) == [ledger.closes[0].obligations.first(where: \.isRent)!.id,
            ledger.closes[0].obligations.first(where: { !$0.isRent })!.id,
            september.obligations.first(where: \.isRent)!.id])
        // Every application reuses the advance's existing movement: one financial
        // UUID, its captured snapshots, and no new transaction anywhere.
        #expect(plan.applications.allSatisfy { $0.paymentTransactionID == movement.id })
        #expect(plan.applications.allSatisfy { $0.sourceSnapshots == PropertySourceSnapshots(capturing: movement) })
        #expect(plan.updatedAdvances.map(\.id) == [advanceID])
        #expect(plan.updatedAdvances[0].amount == 10)
        #expect(plan.updatedAdvances[0].deletedAt == nil)
        ledger.paymentApplications[0] = plan.updatedAdvances[0]
        ledger.paymentApplications += plan.applications
        let knownSources = Set(inputs.map(\.id))
        #expect(ledger.paymentApplications.allSatisfy { knownSources.contains($0.paymentTransactionID) })
        #expect(PropertyLedgerStore.validate(ledger).isEmpty)
        #expect(PropertyCollectionPosting.memberAdvances(propertyID: house.id, residentID: resident.id,
            ledger: ledger, inputs: inputs, asOf: date(10)) == 10)
        let settled = PropertySettlementCalculator.report(propertyID: house.id, month: date(9),
            ledger: ledger, transactions: inputs, asOf: date(10))
        #expect(settled.residents.first?.balance == 0)
        #expect(settled.residents.first?.priorDebt == 0)
    }

    @Test("An advance never pays an obligation whose month has not arrived")
    func advanceNeverPaysFutureMonths() throws {
        var (ledger, house, resident, inputs) = fixture()
        let august = PropertySettlementCalculator.report(propertyID: house.id, month: date(8), ledger: ledger,
            transactions: inputs, asOf: date(10))
        ledger.closes = [try #require(PropertySettlementCalculator.close(august, at: date(8, 31)))]
        let movement = PropertyTransactionInput(id: UUID(), amount: 250, postedAt: date(8, 20),
            description: "Anticipo", isCashAccount: true)
        inputs.append(movement)
        let advanceID = PropertyPaymentAdvance.obligationID(propertyID: house.id, paymentTransactionID: movement.id)
        ledger.paymentApplications = [PropertyPaymentApplication(id: advanceID, propertyID: house.id,
            paymentTransactionID: movement.id, obligationID: advanceID, residentID: resident.id,
            amount: 250, snapshots: PropertySourceSnapshots(capturing: movement))]
        // Browsing October while the calendar is still in September: the advance
        // covers the closed August debt but not October's rent.
        let october = PropertySettlementCalculator.report(propertyID: house.id, month: date(10),
            ledger: ledger, transactions: inputs, asOf: date(9, 15))
        #expect(october.obligations.first(where: \.isRent)?.allocations[resident.id] == 100)
        let future = try #require(PropertyCollectionPosting.applyAdvances(propertyID: house.id,
            residentID: resident.id, report: october, ledger: ledger, inputs: inputs, asOf: date(9, 15)))
        #expect(future.applications.map(\.amount) == [100, 50])
        #expect(!future.applications.contains { $0.obligationID == october.obligations.first(where: \.isRent)!.id })
        #expect(future.updatedAdvances[0].amount == 100)
        // The boundary is inclusive: a month equal to the asOf month is due today.
        let september = PropertySettlementCalculator.report(propertyID: house.id, month: date(9),
            ledger: ledger, transactions: inputs, asOf: date(9, 15))
        let current = try #require(PropertyCollectionPosting.applyAdvances(propertyID: house.id,
            residentID: resident.id, report: september, ledger: ledger, inputs: inputs, asOf: date(9, 15)))
        #expect(current.applications.map(\.amount) == [100, 50, 100])
    }

    @Test("A stale advance source blocks the explicit apply")
    func staleAdvanceSourceBlocksApply() {
        var (ledger, house, resident, inputs) = fixture(rent: 100, expense: 0)
        let original = PropertyTransactionInput(id: UUID(), amount: 100, postedAt: date(8, 5),
            description: "Anticipo", isCashAccount: true)
        let advanceID = PropertyPaymentAdvance.obligationID(propertyID: house.id, paymentTransactionID: original.id)
        ledger.paymentApplications = [PropertyPaymentApplication(id: advanceID, propertyID: house.id,
            paymentTransactionID: original.id, obligationID: advanceID, residentID: resident.id,
            amount: 100, snapshots: PropertySourceSnapshots(capturing: original))]
        let changed = PropertyTransactionInput(id: original.id, amount: 50, postedAt: original.postedAt,
            description: original.description, isCashAccount: true)
        inputs.append(changed)
        let report = PropertySettlementCalculator.report(propertyID: house.id, month: date(9),
            ledger: ledger, transactions: inputs, asOf: date(9, 10))
        #expect(PropertyCollectionPosting.hasChangedAdvanceSource(propertyID: house.id,
            residentID: resident.id, ledger: ledger, inputs: inputs))
        #expect(PropertyCollectionPosting.applyAdvances(propertyID: house.id, residentID: resident.id,
            report: report, ledger: ledger, inputs: inputs, asOf: date(9, 10)) == nil)
    }

    @Test("Applying an advance against a closed month only adds collection applications")
    func applyAdvanceOnClosedMonthOnlyUpdatesCollection() throws {
        var (ledger, house, resident, inputs) = fixture()
        let august = PropertySettlementCalculator.report(propertyID: house.id, month: date(8), ledger: ledger,
            transactions: inputs, asOf: date(10))
        ledger.closes = [try #require(PropertySettlementCalculator.close(august, at: date(8, 31)))]
        let closesBefore = ledger.closes
        let movement = PropertyTransactionInput(id: UUID(), amount: 150, postedAt: date(9, 2),
            description: "Anticipo sobre cierre", isCashAccount: true)
        inputs.append(movement)
        let advanceID = PropertyPaymentAdvance.obligationID(propertyID: house.id, paymentTransactionID: movement.id)
        ledger.paymentApplications = [PropertyPaymentApplication(id: advanceID, propertyID: house.id,
            paymentTransactionID: movement.id, obligationID: advanceID, residentID: resident.id,
            amount: 150, snapshots: PropertySourceSnapshots(capturing: movement))]
        let september = PropertySettlementCalculator.report(propertyID: house.id, month: date(9),
            ledger: ledger, transactions: inputs, asOf: date(10))
        let plan = try #require(PropertyCollectionPosting.applyAdvances(propertyID: house.id,
            residentID: resident.id, report: september, ledger: ledger, inputs: inputs,
            asOf: date(10), includeCurrent: false))
        let closeIDs = Set(closesBefore[0].obligations.map(\.id))
        #expect(plan.applications.map(\.amount) == [100, 50])
        #expect(plan.applications.allSatisfy { closeIDs.contains($0.obligationID) })
        #expect(plan.applications.allSatisfy { $0.paymentTransactionID == movement.id })
        // The fully spent advance is soft-deleted with its original amount restored.
        #expect(plan.updatedAdvances[0].id == advanceID)
        #expect(plan.updatedAdvances[0].deletedAt != nil)
        #expect(plan.updatedAdvances[0].amount == 150)
        ledger.paymentApplications[0] = plan.updatedAdvances[0]
        ledger.paymentApplications += plan.applications
        // Only collection rows changed: the close and its snapshots are untouched.
        #expect(ledger.closes == closesBefore)
        #expect(ledger.closes[0].residents == closesBefore[0].residents)
        #expect(ledger.closes[0].obligations == closesBefore[0].obligations)
        #expect(PropertyLedgerStore.validate(ledger).isEmpty)
        #expect(PropertyCollectionPosting.applyAdvances(propertyID: house.id, residentID: resident.id,
            report: september, ledger: ledger, inputs: inputs, asOf: date(10),
            includeCurrent: false)?.applications.isEmpty == true)
    }

    @Test("An advance exhausted mid-walk is never respent against a later month")
    func exhaustedAdvanceIsNeverRespentLaterInTheWalk() throws {
        var (ledger, house, resident, inputs) = fixture()
        let august = PropertySettlementCalculator.report(propertyID: house.id, month: date(8), ledger: ledger,
            transactions: inputs, asOf: date(10))
        ledger.closes = [try #require(PropertySettlementCalculator.close(august, at: date(8, 31)))]
        let september = PropertySettlementCalculator.report(propertyID: house.id, month: date(9),
            ledger: ledger, transactions: inputs, asOf: date(10))
        let movement = PropertyTransactionInput(id: UUID(), amount: 130, postedAt: date(8, 20),
            description: "Cobro adelantado", isCashAccount: true)
        inputs.append(movement)
        let advanceID = PropertyPaymentAdvance.obligationID(propertyID: house.id, paymentTransactionID: movement.id)
        ledger.paymentApplications = [PropertyPaymentApplication(id: advanceID, propertyID: house.id,
            paymentTransactionID: movement.id, obligationID: advanceID, residentID: resident.id,
            amount: 130, snapshots: PropertySourceSnapshots(capturing: movement))]
        // A 130 advance covers August's rent (100) and part of its fee (30); it
        // can never also pay September's rent, which would spend 230 from one
        // 130 movement.
        let explicit = try #require(PropertyCollectionPosting.applyAdvances(propertyID: house.id,
            residentID: resident.id, report: september, ledger: ledger, inputs: inputs, asOf: date(10)))
        #expect(explicit.applications.map(\.amount) == [100, 30])
        #expect(!explicit.applications.contains {
            $0.obligationID == september.obligations.first(where: \.isRent)!.id })
        #expect(explicit.applications.filter { $0.paymentTransactionID == movement.id }
            .reduce(Decimal.zero) { $0 + $1.amount } == 130)
        #expect(explicit.updatedAdvances.map(\.id) == [advanceID])
        #expect(explicit.updatedAdvances[0].deletedAt != nil)
        #expect(explicit.updatedAdvances[0].amount == 130)
        ledger.paymentApplications[0] = explicit.updatedAdvances[0]
        ledger.paymentApplications += explicit.applications
        #expect(PropertyLedgerStore.validate(ledger).isEmpty)
        // September's rent stays fully due on top of August's 20 residual, and
        // a second pass finds nothing left to spend.
        let settled = PropertySettlementCalculator.report(propertyID: house.id, month: date(9),
            ledger: ledger, transactions: inputs, asOf: date(10))
        #expect(settled.residents.first?.balance == 100)
        #expect(settled.residents.first?.priorDebt == 20)
        #expect(PropertyCollectionPosting.applyAdvances(propertyID: house.id, residentID: resident.id,
            report: september, ledger: ledger, inputs: inputs, asOf: date(10))?.applications.isEmpty == true)
        // The same walk behind a receipt: the member still holds a live 130
        // advance against closed August and now brings a 120 receipt. Each
        // source spends at most itself, and September's rent is receipt money.
        var (freshLedger, freshHouse, freshResident, freshInputs) = fixture()
        let freshAugust = PropertySettlementCalculator.report(propertyID: freshHouse.id, month: date(8),
            ledger: freshLedger, transactions: freshInputs, asOf: date(10))
        freshLedger.closes = [try #require(PropertySettlementCalculator.close(freshAugust, at: date(8, 31)))]
        let freshSeptember = PropertySettlementCalculator.report(propertyID: freshHouse.id, month: date(9),
            ledger: freshLedger, transactions: freshInputs, asOf: date(10))
        let receipt = PropertyTransactionInput(id: UUID(), amount: 120, postedAt: date(9, 15),
            description: "Cobro adicional", isCashAccount: true)
        freshInputs += [movement, receipt]
        let freshAdvanceID = PropertyPaymentAdvance.obligationID(propertyID: freshHouse.id,
            paymentTransactionID: movement.id)
        freshLedger.paymentApplications = [PropertyPaymentApplication(id: freshAdvanceID,
            propertyID: freshHouse.id, paymentTransactionID: movement.id, obligationID: freshAdvanceID,
            residentID: freshResident.id, amount: 130, snapshots: PropertySourceSnapshots(capturing: movement))]
        let reconciliation = try #require(PropertyCollectionPosting.plan(propertyID: freshHouse.id,
            residentID: freshResident.id, report: freshSeptember, ledger: freshLedger,
            inputs: freshInputs, receipt: receipt, asOf: date(10)))
        #expect(reconciliation.applications.map(\.amount) == [100, 30, 20, 100])
        #expect(reconciliation.applications.filter { $0.paymentTransactionID == movement.id }
            .reduce(Decimal.zero) { $0 + $1.amount } == 130)
        #expect(reconciliation.applications.filter { $0.paymentTransactionID == receipt.id }
            .reduce(Decimal.zero) { $0 + $1.amount } == 120)
        #expect(reconciliation.applications.filter {
            $0.obligationID == freshSeptember.obligations.first(where: \.isRent)!.id }
            .allSatisfy { $0.paymentTransactionID == receipt.id })
    }

    @Test("Multiple advances spend oldest-first by posted date")
    func multipleAdvancesSpendOldestFirstByPostedDate() throws {
        var (ledger, house, resident, inputs) = fixture(rent: 100, expense: 0)
        let august = PropertySettlementCalculator.report(propertyID: house.id, month: date(8), ledger: ledger,
            transactions: inputs, asOf: date(10))
        ledger.closes = [try #require(PropertySettlementCalculator.close(august, at: date(8, 31)))]
        let september = PropertySettlementCalculator.report(propertyID: house.id, month: date(9),
            ledger: ledger, transactions: inputs, asOf: date(10))
        let february = PropertyTransactionInput(id: UUID(), amount: 80, postedAt: date(2, 10),
            description: "Anticipo de febrero", isCashAccount: true)
        let april = PropertyTransactionInput(id: UUID(), amount: 70, postedAt: date(4, 10),
            description: "Anticipo de abril", isCashAccount: true)
        inputs += [february, april]
        let februaryID = PropertyPaymentAdvance.obligationID(propertyID: house.id, paymentTransactionID: february.id)
        let aprilID = PropertyPaymentAdvance.obligationID(propertyID: house.id, paymentTransactionID: april.id)
        func advanceRows() -> [PropertyPaymentApplication] {
            [PropertyPaymentApplication(id: februaryID, propertyID: house.id,
                 paymentTransactionID: february.id, obligationID: februaryID, residentID: resident.id,
                 amount: 80, snapshots: PropertySourceSnapshots(capturing: february)),
             PropertyPaymentApplication(id: aprilID, propertyID: house.id,
                 paymentTransactionID: april.id, obligationID: aprilID, residentID: resident.id,
                 amount: 70, snapshots: PropertySourceSnapshots(capturing: april))]
        }
        ledger.paymentApplications = advanceRows()
        // Against the closed month's 100 debt, the older February advance drains
        // first (80) and April covers only the remaining 20 of its 70.
        let explicit = try #require(PropertyCollectionPosting.applyAdvances(propertyID: house.id,
            residentID: resident.id, report: september, ledger: ledger, inputs: inputs,
            asOf: date(10), includeCurrent: false))
        #expect(explicit.applications.map(\.paymentTransactionID) == [february.id, april.id])
        #expect(explicit.applications.map(\.amount) == [80, 20])
        #expect(explicit.updatedAdvances.map(\.id) == [februaryID, aprilID])
        #expect(explicit.updatedAdvances[0].deletedAt != nil)
        #expect(explicit.updatedAdvances[0].amount == 80)
        #expect(explicit.updatedAdvances[1].deletedAt == nil)
        #expect(explicit.updatedAdvances[1].amount == 50)
        // The same oldest-first order inside a receipt reconciliation: after the
        // closed month is covered, April's remainder and the receipt share
        // September's rent.
        ledger.paymentApplications = advanceRows()
        let receipt = PropertyTransactionInput(id: UUID(), amount: 30, postedAt: date(9, 15),
            description: "Cobro adicional", isCashAccount: true)
        inputs.append(receipt)
        let reconciliation = try #require(PropertyCollectionPosting.plan(propertyID: house.id,
            residentID: resident.id, report: september, ledger: ledger, inputs: inputs,
            receipt: receipt, asOf: date(10)))
        #expect(reconciliation.applications.map(\.paymentTransactionID)
            == [february.id, april.id, april.id, receipt.id])
        #expect(reconciliation.applications.map(\.amount) == [80, 20, 50, 30])
        #expect(reconciliation.applications.filter { $0.paymentTransactionID == february.id }
            .reduce(Decimal.zero) { $0 + $1.amount } == 80)
        #expect(reconciliation.applications.filter { $0.paymentTransactionID == april.id }
            .reduce(Decimal.zero) { $0 + $1.amount } == 70)
    }

    @Test("Suggested prior debt excludes a future-dated receipt until it is posted")
    func suggestedAmountAsOf() throws {
        var (ledger, house, resident, inputs) = fixture(rent: 100, expense: 0)
        let august = PropertySettlementCalculator.report(propertyID: house.id, month: date(8),
            ledger: ledger, transactions: inputs, asOf: date(8, 10))
        let close = try #require(PropertySettlementCalculator.close(august, at: date(8, 31)))
        ledger.closes = [close]
        let future = PropertyTransactionInput(id: UUID(), amount: 100, postedAt: date(10, 5),
            description: "Cobro futuro", isCashAccount: true)
        inputs.append(future)
        ledger.paymentApplications = [PropertyPaymentApplication(propertyID: house.id,
            paymentTransactionID: future.id, obligationID: close.obligations.first(where: \.isRent)!.id,
            residentID: resident.id, amount: 100, snapshots: PropertySourceSnapshots(capturing: future))]
        let before = PropertySettlementCalculator.report(propertyID: house.id, month: date(9),
            ledger: ledger, transactions: inputs, asOf: date(9, 10))
        let after = PropertySettlementCalculator.report(propertyID: house.id, month: date(9),
            ledger: ledger, transactions: inputs, asOf: date(10, 10))
        #expect(PropertyCollectionPosting.suggestedAmount(propertyID: house.id, residentID: resident.id,
            report: before, ledger: ledger, inputs: inputs, asOf: date(9, 10), includeCurrent: false) == 100)
        #expect(PropertyCollectionPosting.suggestedAmount(propertyID: house.id, residentID: resident.id,
            report: after, ledger: ledger, inputs: inputs, asOf: date(10, 10), includeCurrent: false) == 0)
        // A future-dated receipt is not a review case: it is simply not yet
        // collected, and the advance parity holds on both surfaces.
        let futureSettlement = PropertyMemberSettlement.summarize(propertyID: house.id,
            residentID: resident.id, report: before, ledger: ledger, inputs: inputs, asOf: date(9, 10),
            context: .init(canCalculate: true, isClosed: false, historical: false, includeCurrent: false))
        #expect(futureSettlement.payable == 100)
        #expect(futureSettlement.advanceAvailable == PropertyCollectionPosting.memberAdvances(
            propertyID: house.id, residentID: resident.id, ledger: ledger, inputs: inputs, asOf: date(9, 10)))
        #expect(futureSettlement.advanceStale == PropertyCollectionPosting.hasChangedAdvanceSource(
            propertyID: house.id, residentID: resident.id, ledger: ledger, inputs: inputs))
    }

    @Test("Paseo de los Parques suggests Fer's exact balance and links one real receipt")
    @MainActor
    func householdFerCollection() throws {
        let roles = PropertyHouseholdAdapter.link
        let month = date(9)
        let account = Account(institution: "Banco sintético", type: .checking)
        let expense = Transaction(account: account, postedAt: date(9, 3), amount: -1_000,
            descriptionRaw: "Gasto para integrante")
        expense.setHouseholdScope(.included)
        expense.setExpenseAssignment(.partner)
        let setup = HouseholdSettlementSetup(partnerIncomeEstimate: 1_000,
            useUserIncomeManualOverride: true, userIncomeManualOverride: 1_000)
        let household = HouseholdSettlementReportService.build(monthStart: month,
            transactions: [expense], setup: setup)
        var ledger = PropertyLedger()
        ledger.householdLink = roles
        ledger.properties = [PropertyRecord(id: roles.propertyID, name: "Casa sintética")]
        ledger.residents = [PropertyResident(id: roles.userID, propertyID: roles.propertyID,
            name: "Tú", activeFrom: .distantPast),
            PropertyResident(id: roles.partnerID, propertyID: roles.propertyID,
                name: "Fer", activeFrom: .distantPast)]
        let expenseInput = PropertyTransactionInput(capturing: expense)
        let report = PropertyHouseholdAdapter.report(household, ledger: ledger,
            transactions: [expenseInput], asOf: date(9, 10))
        #expect(report.residents.first { $0.id == roles.partnerID }?.balance == 1_000)
        #expect(PropertyCollectionPosting.suggestedAmount(propertyID: roles.propertyID,
            residentID: roles.partnerID, report: report, ledger: ledger, inputs: [expenseInput],
            asOf: date(9, 10)) == 1_000)
        let receipt = PropertyTransactionInput(id: UUID(), amount: 1_000, postedAt: date(9, 10),
            description: "Cobro Fer", isCashAccount: true)
        let plan = try #require(PropertyCollectionPosting.plan(propertyID: roles.propertyID,
            residentID: roles.partnerID, report: report, ledger: ledger,
            inputs: [expenseInput, receipt], receipt: receipt, asOf: date(9, 10)))
        #expect(plan.applications.map(\.amount) == [1_000])
        #expect(plan.applications.first?.residentID == roles.partnerID)
    }

    @Test("Every active MXN account type can receive a collection; archived and foreign accounts cannot")
    @MainActor
    func accountEligibility() {
        let cash = Account(institution: "Banco", type: .checking, currency: "MXN")
        let card = Account(institution: "Banco", type: .creditCard, currency: "MXN")
        let investment = Account(institution: "Banco", type: .investment, currency: "MXN")
        let loan = Account(institution: "Banco", type: .loan, currency: "MXN")
        let retirement = Account(institution: "Banco", type: .retirement, currency: "MXN")
        let foreign = Account(institution: "Banco", type: .checking, currency: "USD")
        let archived = Account(institution: "Banco", type: .checking, currency: "MXN", archivedAt: .now)
        #expect(PropertyWorkspaceModel.eligibleCollectionAccount(cash, on: .now))
        #expect(PropertyWorkspaceModel.eligibleCollectionAccount(card, on: .now))
        #expect(PropertyWorkspaceModel.eligibleCollectionAccount(investment, on: .now))
        #expect(PropertyWorkspaceModel.eligibleCollectionAccount(loan, on: .now))
        #expect(PropertyWorkspaceModel.eligibleCollectionAccount(retirement, on: .now))
        #expect(!PropertyWorkspaceModel.eligibleCollectionAccount(foreign, on: .now))
        #expect(!PropertyWorkspaceModel.eligibleCollectionAccount(archived, on: .now))
        #expect(PropertyWorkspaceModel.isMXNCollectionAmount(100))
        #expect(PropertyWorkspaceModel.isMXNCollectionAmount(100.25))
        #expect(!PropertyWorkspaceModel.isMXNCollectionAmount(100.251))
        #expect(PropertyCollectionPosting.suggestedEntryText(Decimal(string: "641.47379666522176365")!) == "641.47")
        #expect(PropertyCollectionPosting.suggestedEntryText(1000) == "1000.00")
        #expect(PropertyCollectionPosting.suggestedEntryText(1.235) == "1.24")
        #expect(PropertyCollectionPosting.parseEntryAmount("641.47") == Decimal(string: "641.47"))
        #expect(PropertyCollectionPosting.parseEntryAmount("1,234.50") == Decimal(string: "1234.50"))
        #expect(PropertyCollectionPosting.parseEntryAmount("100.00abc") == nil)
        #expect(PropertyCollectionPosting.parseEntryAmount("1,00.50") == nil)
        #expect(PropertyCollectionPosting.parseEntryAmount("100.001") == nil)
        let cardReceipt = PropertyTransactionInput(id: UUID(), amount: 100, postedAt: date(9, 10),
            description: "Cobro en tarjeta", isCashAccount: false, hasAccount: true)
        #expect(PropertySettlementCalculator.isValidCollectionPayment(cardReceipt, asOf: date(9, 11)))
        var withoutAccount = cardReceipt
        withoutAccount.hasAccount = false
        #expect(!PropertySettlementCalculator.isValidCollectionPayment(withoutAccount, asOf: date(9, 11)))
    }

    @Test("Rent received on a non-cash account can fund the same capped maintenance recovery")
    func cardReceiptMaintenanceRecovery() {
        let house = PropertyRecord(name: "Casa sintética")
        let member = PropertyResident(propertyID: house.id, name: "Integrante", activeFrom: date(9))
        let program = PropertyMaintenanceProgram(propertyID: house.id,
            startsAt: date(9), endsAt: date(12))
        let expenseID = UUID()
        let receiptID = UUID()
        var ledger = PropertyLedger()
        ledger.properties = [house]
        ledger.residents = [member]
        ledger.maintenancePrograms = [program]
        ledger.attributions = [PropertyTransactionAttribution(propertyID: house.id,
            transactionID: expenseID, kind: .maintenance, responsibility: .owner,
            maintenanceProgramID: program.id)]
        ledger.paymentApplications = [PropertyPaymentApplication(propertyID: house.id,
            paymentTransactionID: receiptID,
            obligationID: PropertyMaintenanceCalculator.stableRentID(house.id, date(9)),
            residentID: member.id, amount: 500)]
        let inputs = [PropertyTransactionInput(id: expenseID, amount: -500,
            postedAt: date(9, 2), description: "Mantenimiento"),
            PropertyTransactionInput(id: receiptID, amount: 500,
                postedAt: date(9, 10), description: "Cobro en tarjeta",
                isCashAccount: false, hasAccount: true)]
        let result = PropertyMaintenanceCalculator.summary(program: program,
            ledger: ledger, transactions: inputs)
        #expect(result.invested == 500)
        #expect(result.recovered == 500)
        #expect(result.capitalPending == 0)
    }

    @Test("A failed property write keeps exactly one real receipt; retry links it without duplication")
    @MainActor
    func failedLinkAndRetry() async throws {
        enum SimulatedFailure: Error { case write }
        let container = try ModelContainer(for: AppSchema.schema,
            configurations: [ModelConfiguration(schema: AppSchema.schema, isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let account = Account(institution: "Banco sintético", type: .checking, currency: "MXN")
        context.insert(account)
        try context.save()
        var (ledger, house, resident, _) = fixture(rent: 100, expense: 0)
        ledger.rents[0].effectiveMonth = date(9)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("collection-retry-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try PropertyLedgerStore.replace(with: ledger, at: url, notify: false)
        var failOnce = true
        let workspace = PropertyWorkspaceModel(month: date(9), fileURL: url,
            writeLedger: { proposed, path in
                if failOnce { failOnce = false; throw SimulatedFailure.write }
                try PropertyLedgerStore.replace(with: proposed, at: path, notify: false)
            })
        workspace.configure(context: context, hasAccounts: true)
        await workspace.loadLedger()
        await workspace.refreshPeriod()
        workspace.destination = .property(house.id)
        let first = workspace.registerCollection(propertyID: house.id, residentID: resident.id,
            account: account, amount: 100, date: date(9, 10))
        guard case .needsLink(let transactionID) = first else {
            Issue.record("Expected recovery state after property write failure")
            return
        }
        #expect(try context.fetch(FetchDescriptor<Transaction>()).count == 1)
        let savedIncome = try #require(context.fetch(FetchDescriptor<Transaction>()).first)
        #expect(savedIncome.amount == 100)
        #expect(savedIncome.flowKind == .income)
        #expect(savedIncome.account?.id == account.id)
        #expect(savedIncome.descriptionRaw.contains(resident.name))
        #expect(savedIncome.descriptionRaw.contains(house.name))
        #expect(try PropertyLedgerStore.read(fileURL: url).paymentApplications.isEmpty)
        let reopenedContext = ModelContext(container)
        let reopened = PropertyWorkspaceModel(month: date(9), fileURL: url)
        reopened.configure(context: reopenedContext, hasAccounts: true)
        await reopened.loadLedger()
        await reopened.refreshPeriod()
        reopened.destination = .property(house.id)
        #expect(reopened.recoveryReceipts(propertyID: house.id).contains { $0.id == transactionID })
        let second = reopened.registerCollection(propertyID: house.id, residentID: resident.id,
            account: nil, amount: 100, date: date(9, 10), pendingTransactionID: transactionID)
        guard case .saved = second else { Issue.record("Retry should link the existing receipt"); return }
        let third = reopened.registerCollection(propertyID: house.id, residentID: resident.id,
            account: nil, amount: 100, date: date(9, 10), pendingTransactionID: transactionID)
        guard case .saved = third else { Issue.record("Repeated retry should be idempotent"); return }
        #expect(try context.fetch(FetchDescriptor<Transaction>()).count == 1)
        #expect(try PropertyLedgerStore.read(fileURL: url).paymentApplications.count == 1)
        await reopened.refreshPeriod(force: true)
        #expect(reopened.reports[house.id]?.residents.first?.balance == 0)
    }

    @Test("A real receipt on a credit-card account is linked and retains its account type")
    @MainActor
    func collectionOnCardAccount() async throws {
        let container = try ModelContainer(for: AppSchema.schema,
            configurations: [ModelConfiguration(schema: AppSchema.schema, isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let card = Account(institution: "Tarjeta sintética", type: .creditCard, currency: "MXN")
        context.insert(card)
        try context.save()
        var (ledger, house, resident, _) = fixture(rent: 100, expense: 0)
        ledger.rents[0].effectiveMonth = date(9)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("collection-card-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try PropertyLedgerStore.replace(with: ledger, at: url, notify: false)
        let workspace = PropertyWorkspaceModel(month: date(9), fileURL: url)
        workspace.configure(context: context, hasAccounts: true)
        await workspace.loadLedger()
        await workspace.refreshPeriod()
        workspace.destination = .property(house.id)
        let result = workspace.registerCollection(propertyID: house.id, residentID: resident.id,
            account: card, amount: 100, date: date(9, 10))
        guard case .saved = result else { Issue.record("A card account should accept a real receipt"); return }
        let transaction = try #require(context.fetch(FetchDescriptor<Transaction>()).first)
        #expect(transaction.account?.id == card.id)
        #expect(transaction.amount == 100)
        #expect(transaction.treatmentKind == .regular)
        #expect(!PropertyTransactionInput(capturing: transaction).isCashAccount)
        #expect(PropertyTransactionInput(capturing: transaction).hasAccount)
        #expect(try PropertyLedgerStore.read(fileURL: url).paymentApplications.count == 1)
        await workspace.refreshPeriod(force: true)
        #expect(workspace.reports[house.id]?.residents.first?.balance == 0)
    }

    @Test("A receipt edited in another context blocks a new collection before posting")
    @MainActor
    func changedAdvanceInAnotherContext() async throws {
        let container = try ModelContainer(for: AppSchema.schema,
            configurations: [ModelConfiguration(schema: AppSchema.schema, isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let account = Account(institution: "Banco sintético", type: .checking, currency: "MXN")
        context.insert(account)
        try context.save()
        let earlier = try ManualTransactionService.create(account: account, date: date(8, 5),
            description: "Anticipo sintético", signedAmount: 100, category: nil,
            flowKindRaw: TransactionFlowKind.income.rawValue, context: context)
        var (ledger, house, resident, _) = fixture(rent: 100, expense: 0)
        ledger.rents[0].effectiveMonth = date(9)
        let original = PropertyTransactionInput(capturing: earlier)
        let advanceID = PropertyPaymentAdvance.obligationID(propertyID: house.id, paymentTransactionID: earlier.id)
        ledger.paymentApplications = [PropertyPaymentApplication(id: advanceID, propertyID: house.id,
            paymentTransactionID: earlier.id, obligationID: advanceID, residentID: resident.id,
            amount: 100, snapshots: PropertySourceSnapshots(capturing: original))]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("collection-stale-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try PropertyLedgerStore.replace(with: ledger, at: url, notify: false)
        let workspace = PropertyWorkspaceModel(month: date(9), fileURL: url)
        workspace.configure(context: context, hasAccounts: true)
        await workspace.loadLedger()
        await workspace.refreshPeriod()
        workspace.destination = .property(house.id)
        #expect(workspace.transactionInputs.first { $0.id == earlier.id }?.amount == 100)
        let otherContext = ModelContext(container)
        let earlierID = earlier.id
        let live = try #require(otherContext.fetch(FetchDescriptor<Transaction>(
            predicate: #Predicate<Transaction> { $0.id == earlierID })).first)
        live.amount = 50
        try otherContext.save()
        let result = workspace.registerCollection(propertyID: house.id, residentID: resident.id,
            account: account, amount: 100, date: date(9, 10))
        guard case .rejected = result else { Issue.record("The changed advance must block posting"); return }
        #expect(try context.fetch(FetchDescriptor<Transaction>()).count == 1)
        #expect(try PropertyLedgerStore.read(fileURL: url).paymentApplications.count == 1)
    }

    @Test("Applying a member advance from the workspace saves without a new transaction")
    @MainActor
    func workspaceAppliesAdvanceWithoutNewTransaction() async throws {
        let container = try ModelContainer(for: AppSchema.schema,
            configurations: [ModelConfiguration(schema: AppSchema.schema, isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let account = Account(institution: "Banco sintético", type: .checking, currency: "MXN")
        context.insert(account)
        try context.save()
        let earlier = try ManualTransactionService.create(account: account, date: date(8, 5),
            description: "Anticipo sintético", signedAmount: 100, category: nil,
            flowKindRaw: TransactionFlowKind.income.rawValue, context: context)
        var (ledger, house, resident, _) = fixture(rent: 100, expense: 0)
        let original = PropertyTransactionInput(capturing: earlier)
        let advanceID = PropertyPaymentAdvance.obligationID(propertyID: house.id, paymentTransactionID: earlier.id)
        ledger.paymentApplications = [PropertyPaymentApplication(id: advanceID, propertyID: house.id,
            paymentTransactionID: earlier.id, obligationID: advanceID, residentID: resident.id,
            amount: 100, snapshots: PropertySourceSnapshots(capturing: original))]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("apply-advance-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try PropertyLedgerStore.replace(with: ledger, at: url, notify: false)
        let workspace = PropertyWorkspaceModel(month: date(9), fileURL: url)
        workspace.configure(context: context, hasAccounts: true)
        await workspace.loadLedger()
        await workspace.refreshPeriod()
        workspace.destination = .property(house.id)
        let outcome = workspace.applyMemberAdvance(propertyID: house.id, residentID: resident.id)
        guard case .saved = outcome else { Issue.record("Applying the advance should save"); return }
        // The existing receipt keeps being the only financial movement.
        #expect(try context.fetch(FetchDescriptor<Transaction>()).count == 1)
        let stored = try PropertyLedgerStore.read(fileURL: url)
        #expect(stored.paymentApplications.count == 2)
        #expect(stored.paymentApplications.filter { $0.deletedAt == nil }
            .allSatisfy { $0.paymentTransactionID == earlier.id && $0.amount == 100 })
        #expect(stored.paymentApplications.filter { $0.deletedAt != nil }.count == 1)
        await workspace.refreshPeriod(force: true)
        #expect(workspace.reports[house.id]?.residents.first?.balance == 0)
        #expect(PropertyCollectionPosting.memberAdvances(propertyID: house.id, residentID: resident.id,
            ledger: stored, inputs: [original], asOf: .now) == 0)
        // Nothing left to cover: a repeat apply is a clear rejection, not a silent save.
        guard case .rejected = workspace.applyMemberAdvance(propertyID: house.id, residentID: resident.id) else {
            Issue.record("A repeat apply with nothing to cover should be rejected")
            return
        }
    }

    // MARK: - PropertyMemberSettlement

    private func settlementParity(_ includeCurrent: Bool, house: PropertyRecord, resident: PropertyResident,
                                   report: PropertyMonthlyReport, ledger: PropertyLedger,
                                   inputs: [PropertyTransactionInput]) throws -> PropertyMemberSettlement {
        let context = PropertyMemberSettlement.Context(canCalculate: true, isClosed: false,
            historical: false, includeCurrent: includeCurrent)
        let settlement = PropertyMemberSettlement.summarize(propertyID: house.id, residentID: resident.id,
            report: report, ledger: ledger, inputs: inputs, asOf: date(10), context: context)
        #expect(PropertyCollectionPosting.suggestedAmount(propertyID: house.id, residentID: resident.id,
            report: report, ledger: ledger, inputs: inputs, asOf: date(10),
            includeCurrent: includeCurrent) == settlement.payable)
        // Parity guard: the duplicated advance math must keep tracking the
        // live PropertyCollectionPosting entry points member for member.
        #expect(settlement.advanceAvailable == PropertyCollectionPosting.memberAdvances(
            propertyID: house.id, residentID: resident.id, ledger: ledger, inputs: inputs, asOf: date(10)))
        #expect(settlement.advanceStale == PropertyCollectionPosting.hasChangedAdvanceSource(
            propertyID: house.id, residentID: resident.id, ledger: ledger, inputs: inputs))
        return settlement
    }

    @Test("The capture suggestion and the member settlement payable never diverge")
    @MainActor
    func suggestedAmountMatchesMemberSettlementPayable() throws {
        var (ledger, house, resident, inputs) = fixture()
        let august = PropertySettlementCalculator.report(propertyID: house.id, month: date(8),
            ledger: ledger, transactions: inputs, asOf: date(10))
        ledger.closes = [try #require(PropertySettlementCalculator.close(august, at: date(8, 31)))]
        var report = PropertySettlementCalculator.report(propertyID: house.id, month: date(9),
            ledger: ledger, transactions: inputs, asOf: date(10))

        // Closed August debt (150) plus the open September rent (100).
        var settlement = try settlementParity(true, house: house, resident: resident,
            report: report, ledger: ledger, inputs: inputs)
        #expect(settlement.payable == 250)
        // Excluding the open month leaves only the closed debt.
        settlement = try settlementParity(false, house: house, resident: resident,
            report: report, ledger: ledger, inputs: inputs)
        #expect(settlement.payable == 150)

        // A month collection clears the open balance; both agree on the remainder.
        let monthReceipt = PropertyTransactionInput(id: UUID(), amount: 100, postedAt: date(9, 8),
            description: "Cobro del mes", isCashAccount: true)
        inputs.append(monthReceipt)
        ledger.paymentApplications = [PropertyPaymentApplication(propertyID: house.id,
            paymentTransactionID: monthReceipt.id,
            obligationID: try #require(report.obligations.first(where: \.isRent)?.id),
            residentID: resident.id, amount: 100, snapshots: PropertySourceSnapshots(capturing: monthReceipt))]
        report = PropertySettlementCalculator.report(propertyID: house.id, month: date(9),
            ledger: ledger, transactions: inputs, asOf: date(10))
        settlement = try settlementParity(true, house: house, resident: resident,
            report: report, ledger: ledger, inputs: inputs)
        #expect(settlement.payable == 150)

        // An unapplied advance lowers both by the same amount.
        let advanceReceipt = PropertyTransactionInput(id: UUID(), amount: 30, postedAt: date(9, 12),
            description: "Anticipo", isCashAccount: true)
        inputs.append(advanceReceipt)
        let advanceID = PropertyPaymentAdvance.obligationID(propertyID: house.id, paymentTransactionID: advanceReceipt.id)
        ledger.paymentApplications += [PropertyPaymentApplication(id: advanceID, propertyID: house.id,
            paymentTransactionID: advanceReceipt.id, obligationID: advanceID, residentID: resident.id,
            amount: 30, snapshots: PropertySourceSnapshots(capturing: advanceReceipt))]
        report = PropertySettlementCalculator.report(propertyID: house.id, month: date(9),
            ledger: ledger, transactions: inputs, asOf: date(10))
        settlement = try settlementParity(true, house: house, resident: resident,
            report: report, ledger: ledger, inputs: inputs)
        #expect(settlement.payable == 120)
        #expect(settlement.advanceAvailable == 30)

        // Fer's household balance suggests the same amount both ways.
        let roles = PropertyHouseholdAdapter.link
        let account = Account(institution: "Banco sintético", type: .checking)
        let expense = Transaction(account: account, postedAt: date(9, 3), amount: -1_000,
            descriptionRaw: "Gasto para integrante")
        expense.setHouseholdScope(.included)
        expense.setExpenseAssignment(.partner)
        let household = HouseholdSettlementReportService.build(monthStart: date(9),
            transactions: [expense], setup: HouseholdSettlementSetup(partnerIncomeEstimate: 1_000,
                useUserIncomeManualOverride: true, userIncomeManualOverride: 1_000))
        var householdLedger = PropertyLedger()
        householdLedger.householdLink = roles
        householdLedger.properties = [PropertyRecord(id: roles.propertyID, name: "Casa sintética")]
        householdLedger.residents = [PropertyResident(id: roles.userID, propertyID: roles.propertyID,
            name: "Tú", activeFrom: .distantPast),
            PropertyResident(id: roles.partnerID, propertyID: roles.propertyID, name: "Fer", activeFrom: .distantPast)]
        let expenseInput = PropertyTransactionInput(capturing: expense)
        let householdReport = PropertyHouseholdAdapter.report(household, ledger: householdLedger,
            transactions: [expenseInput], asOf: date(9, 10))
        let fer = PropertyMemberSettlement.summarize(propertyID: roles.propertyID,
            residentID: roles.partnerID, report: householdReport, ledger: householdLedger,
            inputs: [expenseInput], asOf: date(9, 10),
            context: .init(canCalculate: true, isClosed: false, historical: false, includeCurrent: true))
        #expect(fer.payable == 1_000)
        #expect(PropertyCollectionPosting.suggestedAmount(propertyID: roles.propertyID,
            residentID: roles.partnerID, report: householdReport, ledger: householdLedger,
            inputs: [expenseInput], asOf: date(9, 10)) == fer.payable)
    }

    @Test("Member settlement walks pending, partial, and paid across closes and the current month")
    func memberSettlementPendingPartialAndPaidAcrossClosesAndCurrentMonth() throws {
        var (ledger, house, resident, inputs) = fixture()
        let august = PropertySettlementCalculator.report(propertyID: house.id, month: date(8),
            ledger: ledger, transactions: inputs, asOf: date(10))
        let augustRentID = try #require(august.obligations.first(where: \.isRent)?.id)
        ledger.closes = [try #require(PropertySettlementCalculator.close(august, at: date(8, 31)))]
        var report = PropertySettlementCalculator.report(propertyID: house.id, month: date(9),
            ledger: ledger, transactions: inputs, asOf: date(10))
        let septemberRentID = try #require(report.obligations.first(where: \.isRent)?.id)
        let context = PropertyMemberSettlement.Context(canCalculate: true, isClosed: false,
            historical: false, includeCurrent: true)

        // Pending: closed August debt (150) plus September rent (100), nothing collected.
        var settlement = PropertyMemberSettlement.summarize(propertyID: house.id, residentID: resident.id,
            report: report, ledger: ledger, inputs: inputs, asOf: date(10), context: context)
        #expect(settlement.status == .pending)
        #expect(settlement.due == 250)
        #expect(settlement.payable == 250)
        #expect(settlement.monthObligation == 100)
        #expect(settlement.monthBalance == 100)
        #expect(settlement.monthPaid == 0 && settlement.priorPaid == 0 && settlement.priorDebt == 150)
        #expect(settlement.paymentTransactionIDs.isEmpty)

        // Partial: one valid receipt covers 100 of the prior debt.
        let first = PropertyTransactionInput(id: UUID(), amount: 100, postedAt: date(9, 5),
            description: "Cobro 1", isCashAccount: true)
        inputs.append(first)
        ledger.paymentApplications = [PropertyPaymentApplication(propertyID: house.id,
            paymentTransactionID: first.id, obligationID: augustRentID, residentID: resident.id,
            amount: 100, snapshots: PropertySourceSnapshots(capturing: first))]
        report = PropertySettlementCalculator.report(propertyID: house.id, month: date(9),
            ledger: ledger, transactions: inputs, asOf: date(10))
        settlement = PropertyMemberSettlement.summarize(propertyID: house.id, residentID: resident.id,
            report: report, ledger: ledger, inputs: inputs, asOf: date(10), context: context)
        #expect(settlement.status == .partial)
        #expect(settlement.priorDebt == 50 && settlement.priorPaid == 100)
        #expect(settlement.due == 150 && settlement.payable == 150)
        #expect(settlement.paymentTransactionIDs == [first.id])

        // Paid: the remaining prior debt plus the whole month rent are collected.
        let second = PropertyTransactionInput(id: UUID(), amount: 150, postedAt: date(9, 20),
            description: "Cobro 2", isCashAccount: true)
        inputs.append(second)
        ledger.paymentApplications += [
            PropertyPaymentApplication(propertyID: house.id, paymentTransactionID: second.id,
                obligationID: augustRentID, residentID: resident.id, amount: 50,
                snapshots: PropertySourceSnapshots(capturing: second)),
            PropertyPaymentApplication(propertyID: house.id, paymentTransactionID: second.id,
                obligationID: septemberRentID, residentID: resident.id, amount: 100,
                snapshots: PropertySourceSnapshots(capturing: second))]
        report = PropertySettlementCalculator.report(propertyID: house.id, month: date(9),
            ledger: ledger, transactions: inputs, asOf: date(10))
        settlement = PropertyMemberSettlement.summarize(propertyID: house.id, residentID: resident.id,
            report: report, ledger: ledger, inputs: inputs, asOf: date(10), context: context)
        #expect(settlement.status == .paid)
        #expect(settlement.due == 0 && settlement.payable == 0)
        #expect(settlement.priorDebt == 0 && settlement.priorPaid == 150 && settlement.monthPaid == 100)
        #expect(settlement.paymentTransactionIDs == [second.id, first.id])

        // summarizeAll is one pass that matches member-by-member summarize.
        let all = PropertyMemberSettlement.summarizeAll(propertyID: house.id, report: report,
            ledger: ledger, inputs: inputs, asOf: date(10), context: context)
        #expect(all.map(\.residentID) == report.residents.map(\.id))
        #expect(all == report.residents.map {
            PropertyMemberSettlement.summarize(propertyID: house.id, residentID: $0.id, report: report,
                ledger: ledger, inputs: inputs, asOf: date(10), context: context)
        })
        #expect(PropertyMemberSettlement.summarizeAll(propertyID: house.id, report: report,
            ledger: ledger, inputs: inputs, asOf: date(10), context: context, visibleIDs: []).isEmpty)
    }

    @Test("A former member with prior debt remains in the collection summaries")
    func formerMemberWithPriorDebtRemainsVisible() throws {
        var (ledger, house, resident, inputs) = fixture()
        let august = PropertySettlementCalculator.report(propertyID: house.id, month: date(8),
            ledger: ledger, transactions: inputs, asOf: date(10))
        ledger.closes = [try #require(PropertySettlementCalculator.close(august, at: date(8, 31)))]
        ledger.residents[0].activeThrough = Calendar.current.propertyMonthStart(for: date(8))
        let september = PropertySettlementCalculator.report(propertyID: house.id, month: date(9),
            ledger: ledger, transactions: inputs, asOf: date(10))
        let values = PropertyMemberSettlement.summarizeAll(propertyID: house.id, report: september,
            ledger: ledger, inputs: inputs, asOf: date(10),
            context: .init(canCalculate: false, isClosed: false, historical: false, includeCurrent: true),
            additionalResidentIDs: [resident.id])
        let former = try #require(values.first { $0.residentID == resident.id })
        #expect(former.participationEnded)
        #expect(former.priorDebt > 0)
        #expect(former.status == .pending)
        #expect(former.payable == former.priorDebt)

        let receipt = PropertyTransactionInput(id: UUID(), amount: former.priorDebt, postedAt: date(9, 10),
            description: "Cobro sintético", isCashAccount: true)
        ledger.paymentApplications = august.obligations.compactMap { obligation in
            guard let amount = obligation.allocations[resident.id], amount > 0 else { return nil }
            return PropertyPaymentApplication(propertyID: house.id, paymentTransactionID: receipt.id,
                obligationID: obligation.id, residentID: resident.id, amount: amount,
                snapshots: PropertySourceSnapshots(capturing: receipt))
        }
        let paidInputs = inputs + [receipt]
        let paidReport = PropertySettlementCalculator.report(propertyID: house.id, month: date(9),
            ledger: ledger, transactions: paidInputs, asOf: date(10))
        let paid = PropertyMemberSettlement.summarizeAll(propertyID: house.id, report: paidReport,
            ledger: ledger, inputs: paidInputs, asOf: date(10),
            context: .init(canCalculate: false, isClosed: false, historical: false, includeCurrent: true),
            additionalResidentIDs: [resident.id])
        #expect(paid.first { $0.residentID == resident.id }?.status == .paid)
        #expect(paid.first { $0.residentID == resident.id }?.paymentTransactionIDs == [receipt.id])
    }

    @Test("A receipt moved to a future date remains visible for reconciliation")
    func changedReceiptRemainsVisible() {
        let id = UUID()
        let original = PropertyTransactionInput(id: id, amount: 100, postedAt: date(8, 5),
            description: "Cobro sintético", isCashAccount: true)
        let application = PropertyPaymentApplication(propertyID: UUID(), paymentTransactionID: id,
            obligationID: UUID(), residentID: UUID(), amount: 100,
            snapshots: PropertySourceSnapshots(capturing: original))
        var changed = original
        changed.postedAt = date(12, 5)
        #expect(PropertyCollectionHistory.isVisible(application, source: changed, asOf: date(9)))
        #expect(PropertyCollectionHistory.includes(application, source: changed, obligationIDs: [], asOf: date(9)))
        var genuinelyFuture = application
        genuinelyFuture.sourcePostedAtSnapshot = changed.postedAt
        #expect(!PropertyCollectionHistory.isVisible(genuinelyFuture, source: changed, asOf: date(9)))
        #expect(!PropertyCollectionHistory.includes(genuinelyFuture, source: changed, obligationIDs: [], asOf: date(9)))
        #expect(PropertyCollectionHistory.includes(application, source: nil, obligationIDs: [], asOf: date(9)))
    }

    @Test("A missing or changed source forces review and never claims paid or zero")
    func missingOrChangedSourceNeverClaimsPaidOrZero() throws {
        var (ledger, house, resident, inputs) = fixture()
        let august = PropertySettlementCalculator.report(propertyID: house.id, month: date(8),
            ledger: ledger, transactions: inputs, asOf: date(10))
        let augustRentID = try #require(august.obligations.first(where: \.isRent)?.id)
        ledger.closes = [try #require(PropertySettlementCalculator.close(august, at: date(8, 31)))]
        let receipt = PropertyTransactionInput(id: UUID(), amount: 150, postedAt: date(9, 5),
            description: "Cobro sobre cierre", isCashAccount: true)
        ledger.paymentApplications = [PropertyPaymentApplication(propertyID: house.id,
            paymentTransactionID: receipt.id, obligationID: augustRentID, residentID: resident.id,
            amount: 150, snapshots: PropertySourceSnapshots(capturing: receipt))]

        // The receipt vanished from the inputs entirely.
        let vanished = PropertySettlementCalculator.report(propertyID: house.id, month: date(9),
            ledger: ledger, transactions: inputs, asOf: date(10))
        var settlement = PropertyMemberSettlement.summarize(propertyID: house.id, residentID: resident.id,
            report: vanished, ledger: ledger, inputs: inputs, asOf: date(10),
            context: .init(canCalculate: true, isClosed: false, historical: false, includeCurrent: true))
        #expect(settlement.sourcesMissing)
        #expect(settlement.status == .review)
        #expect(settlement.payable == nil)
        #expect(settlement.due == 250)

        // A soft-deleted receipt source behaves the same.
        var deleted = receipt
        deleted.deletedAt = date(9, 15)
        inputs.append(deleted)
        let deletedReport = PropertySettlementCalculator.report(propertyID: house.id, month: date(9),
            ledger: ledger, transactions: inputs, asOf: date(10))
        settlement = PropertyMemberSettlement.summarize(propertyID: house.id, residentID: resident.id,
            report: deletedReport, ledger: ledger, inputs: inputs, asOf: date(10),
            context: .init(canCalculate: true, isClosed: false, historical: false, includeCurrent: true))
        #expect(settlement.sourcesMissing && settlement.status == .review && settlement.payable == nil)
        #expect(settlement.due == 250)

        // A changed advance source is stale: review, no payable, and no credit taken.
        var (staleLedger, staleHouse, staleResident, staleInputs) = fixture(rent: 100, expense: 0)
        let original = PropertyTransactionInput(id: UUID(), amount: 100, postedAt: date(8, 5),
            description: "Anticipo", isCashAccount: true)
        let advanceID = PropertyPaymentAdvance.obligationID(propertyID: staleHouse.id, paymentTransactionID: original.id)
        staleLedger.paymentApplications = [PropertyPaymentApplication(id: advanceID,
            propertyID: staleHouse.id, paymentTransactionID: original.id, obligationID: advanceID,
            residentID: staleResident.id, amount: 100, snapshots: PropertySourceSnapshots(capturing: original))]
        let changed = PropertyTransactionInput(id: original.id, amount: 50, postedAt: original.postedAt,
            description: original.description, isCashAccount: true)
        staleInputs.append(changed)
        let staleReport = PropertySettlementCalculator.report(propertyID: staleHouse.id, month: date(9),
            ledger: staleLedger, transactions: staleInputs, asOf: date(9, 10))
        settlement = PropertyMemberSettlement.summarize(propertyID: staleHouse.id,
            residentID: staleResident.id, report: staleReport, ledger: staleLedger,
            inputs: staleInputs, asOf: date(9, 10),
            context: .init(canCalculate: true, isClosed: false, historical: false, includeCurrent: true))
        #expect(settlement.advanceStale)
        #expect(settlement.status == .review)
        #expect(settlement.payable == nil)
        #expect(settlement.advanceAvailable == 0)
        #expect(settlement.due == 100)
        #expect(settlement.advanceAvailable == PropertyCollectionPosting.memberAdvances(
            propertyID: staleHouse.id, residentID: staleResident.id,
            ledger: staleLedger, inputs: staleInputs, asOf: date(9, 10)))
        #expect(settlement.advanceStale == PropertyCollectionPosting.hasChangedAdvanceSource(
            propertyID: staleHouse.id, residentID: staleResident.id,
            ledger: staleLedger, inputs: staleInputs))
    }

    @Test("An overallocated month receipt forces review and never suggests a payable")
    func overallocatedMonthReceiptNeedsReview() throws {
        var (ledger, house, resident, inputs) = fixture()
        var report = PropertySettlementCalculator.report(propertyID: house.id, month: date(9),
            ledger: ledger, transactions: inputs, asOf: date(10))
        let septemberRentID = try #require(report.obligations.first(where: \.isRent)?.id)
        // One 100 receipt applied twice against the month rent: 120 collected
        // on a 100 receipt is over-allocation, not money.
        let receipt = PropertyTransactionInput(id: UUID(), amount: 100, postedAt: date(9, 5),
            description: "Cobro sobreasignado", isCashAccount: true)
        inputs.append(receipt)
        ledger.paymentApplications = [
            PropertyPaymentApplication(propertyID: house.id, paymentTransactionID: receipt.id,
                obligationID: septemberRentID, residentID: resident.id, amount: 60,
                snapshots: PropertySourceSnapshots(capturing: receipt)),
            PropertyPaymentApplication(propertyID: house.id, paymentTransactionID: receipt.id,
                obligationID: septemberRentID, residentID: resident.id, amount: 60,
                snapshots: PropertySourceSnapshots(capturing: receipt))]
        report = PropertySettlementCalculator.report(propertyID: house.id, month: date(9),
            ledger: ledger, transactions: inputs, asOf: date(10))
        let settlement = PropertyMemberSettlement.summarize(propertyID: house.id, residentID: resident.id,
            report: report, ledger: ledger, inputs: inputs, asOf: date(10),
            context: .init(canCalculate: true, isClosed: false, historical: false, includeCurrent: true))
        #expect(settlement.receiptsNeedReview)
        #expect(!settlement.sourcesMissing)
        #expect(settlement.status == .review)
        #expect(settlement.payable == nil)
        #expect(PropertyCollectionPosting.suggestedAmount(propertyID: house.id, residentID: resident.id,
            report: report, ledger: ledger, inputs: inputs, asOf: date(10)) == 0)
    }

    @Test("A member without obligations has nothing due, not paid")
    func zeroDueWithoutObligationsIsNothingDue() {
        let house = PropertyRecord(name: "Casa sintética")
        let resident = PropertyResident(propertyID: house.id, name: "Integrante", activeFrom: date(8),
            referenceMonthlyIncome: 1_000)
        var ledger = PropertyLedger()
        ledger.properties = [house]
        ledger.residents = [resident]
        ledger.incomes = [PropertyIncome(propertyID: house.id, residentID: resident.id,
            monthStart: date(9), amount: 1_000, confirmedAt: date(9))]
        let report = PropertySettlementCalculator.report(propertyID: house.id, month: date(9),
            ledger: ledger, transactions: [], asOf: date(10))
        let settlement = PropertyMemberSettlement.summarize(propertyID: house.id, residentID: resident.id,
            report: report, ledger: ledger, inputs: [], asOf: date(10),
            context: .init(canCalculate: true, isClosed: false, historical: false, includeCurrent: true))
        #expect(settlement.status == .nothingDue)
        #expect(settlement.monthObligation == 0)
        #expect(settlement.monthBalance == 0)
        #expect(settlement.due == 0)
        #expect(settlement.payable == 0)
    }

    @Test("An unapplied advance never marks the month as paid")
    func unappliedAdvanceDoesNotMarkPaid() {
        var (ledger, house, resident, inputs) = fixture(rent: 100, expense: 0)
        let receipt = PropertyTransactionInput(id: UUID(), amount: 200, postedAt: date(9, 5),
            description: "Anticipo grande", isCashAccount: true)
        inputs.append(receipt)
        let advanceID = PropertyPaymentAdvance.obligationID(propertyID: house.id, paymentTransactionID: receipt.id)
        ledger.paymentApplications = [PropertyPaymentApplication(id: advanceID, propertyID: house.id,
            paymentTransactionID: receipt.id, obligationID: advanceID, residentID: resident.id,
            amount: 200, snapshots: PropertySourceSnapshots(capturing: receipt))]
        let report = PropertySettlementCalculator.report(propertyID: house.id, month: date(9),
            ledger: ledger, transactions: inputs, asOf: date(9, 10))
        let settlement = PropertyMemberSettlement.summarize(propertyID: house.id, residentID: resident.id,
            report: report, ledger: ledger, inputs: inputs, asOf: date(9, 10),
            context: .init(canCalculate: true, isClosed: false, historical: false, includeCurrent: true))
        #expect(settlement.status == .pending)
        #expect(settlement.monthPaid == 0 && settlement.priorPaid == 0)
        #expect(settlement.advanceAvailable == 200)
        #expect(settlement.due == 100)
        #expect(settlement.payable == 0)
        #expect(PropertyCollectionPosting.suggestedAmount(propertyID: house.id, residentID: resident.id,
            report: report, ledger: ledger, inputs: inputs, asOf: date(9, 10)) == 0)
    }

    @Test("An uncalculable split hides month figures but keeps prior debt visible")
    func uncalculableSplitKeepsPriorDebtVisibleButPayableNil() throws {
        var (ledger, house, resident, inputs) = fixture()
        resident.referenceMonthlyIncome = 0
        ledger.residents = [resident]
        ledger.incomes = [PropertyIncome(propertyID: house.id, residentID: resident.id,
            monthStart: date(8), amount: 1_000, confirmedAt: date(8))]
        let august = PropertySettlementCalculator.report(propertyID: house.id, month: date(8),
            ledger: ledger, transactions: inputs, asOf: date(10))
        ledger.closes = [try #require(PropertySettlementCalculator.close(august, at: date(8, 31)))]
        let september = PropertySettlementCalculator.report(propertyID: house.id, month: date(9),
            ledger: ledger, transactions: inputs, asOf: date(10))
        // The same canCalculate check PropertiesView.monthlyDetail performs.
        let canCalculate = september.residents.reduce(Decimal.zero) { $0 + $1.income } > 0
            && september.obligations.allSatisfy {
                if case .owner = $0.responsibility { return true }
                return $0.allocations.values.reduce(Decimal.zero, +) == $0.amount
            }
        #expect(!canCalculate)
        let settlement = PropertyMemberSettlement.summarize(propertyID: house.id, residentID: resident.id,
            report: september, ledger: ledger, inputs: inputs, asOf: date(10),
            context: .init(canCalculate: canCalculate, isClosed: false, historical: false, includeCurrent: true))
        #expect(settlement.status == .toCalculate)
        #expect(settlement.monthObligation == nil)
        #expect(settlement.monthBalance == nil)
        #expect(settlement.due == nil)
        #expect(settlement.payable == nil)
        #expect(settlement.priorDebt == 150)
    }

    @Test("A historical household month is pending reconciliation, never debt")
    @MainActor
    func historicalHouseholdMonthIsToReconcile() throws {
        let roles = PropertyHouseholdAdapter.link
        let month = date(8)
        let account = Account(institution: "Banco sintético", type: .checking)
        let expense = Transaction(account: account, postedAt: date(8, 3), amount: -1_000,
            descriptionRaw: "Gasto histórico")
        expense.setHouseholdScope(.included)
        expense.setExpenseAssignment(.partner)
        let household = HouseholdSettlementReportService.build(monthStart: month,
            transactions: [expense], setup: HouseholdSettlementSetup(partnerIncomeEstimate: 1_000,
                useUserIncomeManualOverride: true, userIncomeManualOverride: 1_000))
        var ledger = PropertyLedger()
        ledger.householdLink = roles
        ledger.properties = [PropertyRecord(id: roles.propertyID, name: "Casa sintética")]
        ledger.residents = [PropertyResident(id: roles.userID, propertyID: roles.propertyID,
            name: "Tú", activeFrom: .distantPast),
            PropertyResident(id: roles.partnerID, propertyID: roles.propertyID, name: "Fer", activeFrom: .distantPast)]
        let expenseInput = PropertyTransactionInput(capturing: expense)
        let report = PropertyHouseholdAdapter.report(household, ledger: ledger,
            transactions: [expenseInput], asOf: date(8, 10))
        // The same historical determination PropertiesView performs: no household
        // configuration and no close exist for the month.
        let historical = (ledger.householdMonths ?? []).first { $0.monthStart == month && $0.deletedAt == nil } == nil
            && !ledger.closes.contains { $0.propertyID == roles.propertyID && $0.monthStart == month }
        #expect(historical)
        let settlement = PropertyMemberSettlement.summarize(propertyID: roles.propertyID,
            residentID: roles.partnerID, report: report, ledger: ledger, inputs: [expenseInput],
            asOf: date(8, 10),
            context: .init(canCalculate: true, isClosed: false, historical: true, includeCurrent: false))
        #expect(settlement.status == .toReconcile)
        #expect(settlement.monthObligation == 1_000)
        #expect(settlement.monthBalance == 1_000)
        #expect(settlement.due == nil)
        #expect(settlement.payable == nil)
        #expect(settlement.priorDebt == 0)
        #expect(!settlement.participationEnded)
        #expect(PropertyCollectionPosting.suggestedAmount(propertyID: roles.propertyID,
            residentID: roles.partnerID, report: report, ledger: ledger, inputs: [expenseInput],
            asOf: date(8, 10), includeCurrent: false) == 0)
    }

}
