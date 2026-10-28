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

    /// A real household month — shared 1,000 split half and half by equal
    /// incomes, Fer-only 300, user-only 200 — with its residents wired into the
    /// Paseo de los Parques ledger.
    @MainActor
    private func householdFixture() -> (household: HouseholdSettlementReport,
        roles: PropertyHouseholdLink, ledger: PropertyLedger, inputs: [PropertyTransactionInput]) {
        let roles = PropertyHouseholdAdapter.link
        let month = date(9)
        let account = Account(institution: "Banco sintético", type: .checking)
        let shared = Transaction(account: account, postedAt: date(9, 2), amount: -1_000,
            descriptionRaw: "Gasto compartido")
        shared.setHouseholdScope(.included)
        shared.setExpenseAssignment(.shared)
        let ferOnly = Transaction(account: account, postedAt: date(9, 3), amount: -300,
            descriptionRaw: "Gasto solo Fer")
        ferOnly.setHouseholdScope(.included)
        ferOnly.setExpenseAssignment(.partner)
        let userOnly = Transaction(account: account, postedAt: date(9, 4), amount: -200,
            descriptionRaw: "Gasto solo mío")
        userOnly.setHouseholdScope(.included)
        userOnly.setExpenseAssignment(.user)
        let household = HouseholdSettlementReportService.build(monthStart: month,
            transactions: [shared, ferOnly, userOnly],
            setup: HouseholdSettlementSetup(partnerIncomeEstimate: 1_000,
                useUserIncomeManualOverride: true, userIncomeManualOverride: 1_000))
        var ledger = PropertyLedger()
        ledger.householdLink = roles
        ledger.properties = [PropertyRecord(id: roles.propertyID, name: "Casa sintética")]
        ledger.residents = [PropertyResident(id: roles.userID, propertyID: roles.propertyID,
            name: "Tú", activeFrom: .distantPast),
            PropertyResident(id: roles.partnerID, propertyID: roles.propertyID,
                name: "Fer", activeFrom: .distantPast)]
        let inputs = [PropertyTransactionInput(capturing: shared),
                      PropertyTransactionInput(capturing: ferOnly),
                      PropertyTransactionInput(capturing: userOnly)]
        return (household, roles, ledger, inputs)
    }

    /// The same fixture closed under the classification this adapter used
    /// before individual rows existed: every obligation `.shared`. Persisted
    /// household closes carry exactly this shape.
    @MainActor
    private func householdLedgerWithLegacyClose() -> (household: HouseholdSettlementReport,
        roles: PropertyHouseholdLink, ledger: PropertyLedger, inputs: [PropertyTransactionInput],
        close: PropertySettlementClose) {
        let (household, roles, ledger, inputs) = householdFixture()
        let month = date(9)
        let rows = household.sharedRows + household.ferRows + household.userRows
        let obligations = rows.map { row in
            PropertyObligationSnapshot(id: .deterministic(row.id, month, "household-obligation"),
                title: row.transaction.descriptionRaw, kind: .operation, amount: row.amount,
                allocations: [roles.userID: row.userShare, roles.partnerID: row.partnerShare],
                transactionID: row.id, responsibility: .shared,
                sourcePostedAt: row.transaction.postedAt,
                sourceCurrencyCode: row.transaction.currency)
        }
        let members = [
            PropertyResidentSnapshot(id: roles.userID, name: "Tú", income: household.userSalaryIncome,
                share: household.userIncomeShare,
                obligation: household.userFairShare + household.userOnlyTotal, paid: 0),
            PropertyResidentSnapshot(id: roles.partnerID, name: "Fer", income: household.partnerIncomeEstimate,
                share: household.partnerIncomeShare,
                obligation: household.amountToRecoverFromPartner, paid: 0)
        ]
        let close = PropertySettlementClose(id: .deterministic(roles.propertyID, month, "household-preview"),
            propertyID: roles.propertyID, monthStart: month, closedAt: date(9, 28),
            residents: members, obligations: obligations,
            totalObligations: members.reduce(Decimal.zero) { $0 + $1.obligation }, warnings: [])
        var closedLedger = ledger
        closedLedger.closes = [close]
        return (household, roles, closedLedger, inputs, close)
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

    @Test("A later receipt never spends an advance whose original source changed")
    func changedPriorAdvanceIsNeverSpentByLaterReceipt() throws {
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
        // The rancid advance neither blocks the new collection nor funds it:
        // every application rides the new receipt alone.
        let plan = try #require(PropertyCollectionPosting.plan(propertyID: house.id, residentID: resident.id,
            report: report, ledger: ledger, inputs: inputs, receipt: newReceipt, asOf: date(9, 10)))
        #expect(!plan.applications.isEmpty)
        #expect(plan.applications.allSatisfy { $0.paymentTransactionID == newReceipt.id })
        #expect(plan.applications.allSatisfy { $0.paymentTransactionID != original.id })
        #expect(plan.updatedAdvances.isEmpty)
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

    @Test("Household adapter classifies shared, Fer-only, and user-only rows")
    @MainActor
    func householdAdapterClassifiesRealResponsibility() throws {
        let (household, roles, ledger, inputs) = householdFixture()
        let month = date(9)
        let report = PropertyHouseholdAdapter.report(household, ledger: ledger,
            transactions: inputs, asOf: date(9, 10))
        let fer = try #require(report.residents.first { $0.id == roles.partnerID })
        let user = try #require(report.residents.first { $0.id == roles.userID })
        // Real classification: only the shared pot is shared; a one-member row
        // is an individual charge of exactly that member.
        #expect(fer.sharedExpenses == 500)
        #expect(fer.individualExpenses == 300)
        #expect(user.sharedExpenses == 500)
        #expect(user.individualExpenses == 200)
        // The account closes by hand exactly as the old all-shared
        // classification did: Fer owes 500 + 300 and paid nothing; the user's
        // 500 + 200 was paid when it was recorded.
        #expect(fer.balance == 800)
        #expect(user.balance == 0)
        // Fer's member account: the shared pot keeps its full 1,000 while
        // "Gastos suyos" now carries the real 300 instead of hiding in shared.
        let ferAccount = PropertyMemberAccount.account(propertyID: roles.propertyID,
            residentID: roles.partnerID, report: report, ledger: ledger, inputs: inputs,
            asOf: date(9, 10),
            context: .init(canCalculate: household.splitAvailable, isClosed: false,
                historical: false, includeCurrent: true))
        #expect(ferAccount.houseSharedTotal == 1_000)
        #expect(ferAccount.memberSharedShare == 500)
        #expect(ferAccount.individualCharges == 300)
        // One-member obligations keep their deterministic ids (so existing
        // payment applications still pair) and allocate to one resident only.
        let sharedObligation = try #require(report.obligations.first { $0.title == "Gasto compartido" })
        #expect(sharedObligation.id == UUID.deterministic(household.sharedRows[0].id, month, "household-obligation"))
        #expect(sharedObligation.responsibility == .shared)
        #expect(sharedObligation.allocations == [roles.userID: 500, roles.partnerID: 500])
        let ferObligation = try #require(report.obligations.first { $0.title == "Gasto solo Fer" })
        #expect(ferObligation.id == UUID.deterministic(household.ferRows[0].id, month, "household-obligation"))
        #expect(ferObligation.responsibility == .individual(residentID: roles.partnerID))
        #expect(ferObligation.allocations == [roles.partnerID: 300])
        let userObligation = try #require(report.obligations.first { $0.title == "Gasto solo mío" })
        #expect(userObligation.id == UUID.deterministic(household.userRows[0].id, month, "household-obligation"))
        #expect(userObligation.responsibility == .individual(residentID: roles.userID))
        #expect(userObligation.allocations == [roles.userID: 200])
        // Obligation order still follows shared + Fer + user.
        #expect(report.obligations.map(\.title) == ["Gasto compartido", "Gasto solo Fer", "Gasto solo mío"])
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
        var failedApplicationsWrite = false
        let workspace = PropertyWorkspaceModel(month: date(9), fileURL: url,
            writeLedger: { proposed, path in
                // Marker-first: the marker write must land, so the failure hits
                // the applications write and leaves one real recoverable receipt.
                if !failedApplicationsWrite && !proposed.paymentApplications.isEmpty {
                    failedApplicationsWrite = true
                    throw SimulatedFailure.write
                }
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

    /// Marker writes must land while only the applications write fails, so the
    /// injected writer throws exactly once and only on a ledger that already
    /// carries payment applications.
    private struct PendingLinkFailureWriter {
        private var failApplicationsWrite = true
        enum WriteFailure: Error { case write }

        mutating func write(_ proposed: PropertyLedger, at path: URL?) throws {
            if failApplicationsWrite && !proposed.paymentApplications.isEmpty {
                failApplicationsWrite = false
                throw WriteFailure.write
            }
            try PropertyLedgerStore.replace(with: proposed, at: path, notify: false)
        }
    }

    /// The marker write is the first ledger write of a collection, so this
    /// writer throws exactly once and only on a ledger that already carries a
    /// pending-link marker.
    private struct MarkerFailureWriter {
        private var failMarkerWrite = true
        enum WriteFailure: Error { case write }

        mutating func write(_ proposed: PropertyLedger, at path: URL?) throws {
            if failMarkerWrite && !proposed.pendingLinks.isEmpty {
                failMarkerWrite = false
                throw WriteFailure.write
            }
            try PropertyLedgerStore.replace(with: proposed, at: path, notify: false)
        }
    }

    @Test("A revision race after income creation returns needsLink without a second income")
    @MainActor
    func revisionRaceAfterIncomeCreationNeedsLinkWithoutDuplication() async throws {
        let container = try ModelContainer(for: AppSchema.schema,
            configurations: [ModelConfiguration(schema: AppSchema.schema, isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let account = Account(institution: "Banco sintético", type: .checking, currency: "MXN")
        context.insert(account)
        try context.save()
        var (ledger, house, resident, _) = fixture(rent: 100, expense: 0)
        ledger.rents[0].effectiveMonth = date(9)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("revision-race-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try PropertyLedgerStore.replace(with: ledger, at: url, notify: false)
        // The guard passes before the income is created, then fails at the
        // applications write — the exact window where another window wrote the
        // property register after the marker and the income were already pinned.
        var guardCalls = 0
        let workspace = PropertyWorkspaceModel(month: date(9), fileURL: url,
            revisionCheckOverride: {
                guardCalls += 1
                if guardCalls == 2 {
                    throw PropertyAssignmentService.AssignmentError.invalid("The property register changed. Reload before assigning transactions.")
                }
            })
        workspace.configure(context: context, hasAccounts: true)
        await workspace.loadLedger()
        await workspace.refreshPeriod()
        workspace.destination = .property(house.id)
        let first = workspace.registerCollection(propertyID: house.id, residentID: resident.id,
            account: account, amount: 100, date: date(9, 10))
        guard case .needsLink(let incomeID) = first else {
            Issue.record("A revision race after income creation must report the receipt UUID")
            return
        }
        // Exactly one real income exists, and the marker-first write already
        // pinned it — the retry refreshes that marker by paymentTransactionID.
        #expect(try context.fetch(FetchDescriptor<Transaction>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<Transaction>()).first?.id == incomeID)
        #expect(try PropertyLedgerStore.read(fileURL: url).pendingLinks.map(\.paymentTransactionID) == [incomeID])
        let second = workspace.registerCollection(propertyID: house.id, residentID: resident.id,
            account: nil, amount: 100, date: date(9, 10), pendingTransactionID: incomeID)
        guard case .saved = second else {
            Issue.record("Retry after the race should complete the link with the same receipt")
            return
        }
        #expect(try context.fetch(FetchDescriptor<Transaction>()).count == 1)
        let stored = try PropertyLedgerStore.read(fileURL: url)
        #expect(stored.paymentApplications.count == 1)
        #expect(stored.pendingLinks.isEmpty)
        await workspace.refreshPeriod(force: true)
        #expect(workspace.reports[house.id]?.residents.first?.balance == 0)
    }

    @Test("Pending link recovery survives reopen from disk")
    @MainActor
    func pendingLinkRecoverySurvivesReopenFromDisk() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-link-reopen-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storeURL = root.appendingPathComponent("store.sqlite")
        var container: ModelContainer? = try ModelContainer(for: AppSchema.schema,
            configurations: [ModelConfiguration(schema: AppSchema.schema, url: storeURL)])
        let context = try #require(container).mainContext
        let account = Account(institution: "Banco sintético", type: .checking, currency: "MXN")
        context.insert(account)
        try context.save()
        var (ledger, house, resident, _) = fixture(rent: 100, expense: 0)
        ledger.rents[0].effectiveMonth = date(9)
        let url = root.appendingPathComponent("PropertyLedger.json")
        try PropertyLedgerStore.replace(with: ledger, at: url, notify: false)
        var writer = PendingLinkFailureWriter()
        var workspace: PropertyWorkspaceModel? = PropertyWorkspaceModel(month: date(9), fileURL: url,
            writeLedger: { proposed, path in try writer.write(proposed, at: path) })
        workspace?.configure(context: context, hasAccounts: true)
        await workspace?.loadLedger()
        await workspace?.refreshPeriod()
        workspace?.destination = .property(house.id)
        let outcome = workspace?.registerCollection(propertyID: house.id, residentID: resident.id,
            account: account, amount: 100, date: date(9, 10))
        workspace = nil
        container = nil
        guard case .needsLink(let incomeID)? = outcome else {
            Issue.record("Expected the interrupted link to report the receipt UUID")
            return
        }
        // The income and its marker are both durable; only the applications failed.
        let stored = try PropertyLedgerStore.read(fileURL: url)
        #expect(stored.paymentApplications.isEmpty)
        #expect(stored.pendingLinks.map(\.paymentTransactionID) == [incomeID])
        #expect(stored.pendingLinks[0].amount == 100)
        // Drop the workspace entirely: a fresh model, ledger, and SwiftData store
        // reloaded from disk still find exactly that one collection by UUID.
        let reopenedContainer = try ModelContainer(for: AppSchema.schema,
            configurations: [ModelConfiguration(schema: AppSchema.schema, url: storeURL)])
        let reopened = PropertyWorkspaceModel(month: date(9), fileURL: url)
        reopened.configure(context: reopenedContainer.mainContext, hasAccounts: true)
        await reopened.loadLedger()
        await reopened.refreshPeriod()
        reopened.destination = .property(house.id)
        let recovered = reopened.pendingLinks(propertyID: house.id)
        #expect(recovered.count == 1)
        #expect(recovered.first?.link.paymentTransactionID == incomeID)
        #expect(recovered.first?.link.amount == 100)
        #expect(recovered.first?.input?.id == incomeID)
        #expect(recovered.first?.input?.amount == 100)
    }

    @Test("Pending link ignores renames and other income")
    @MainActor
    func pendingLinkIgnoresRenamesAndOtherIncome() async throws {
        let container = try ModelContainer(for: AppSchema.schema,
            configurations: [ModelConfiguration(schema: AppSchema.schema, isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let account = Account(institution: "Banco sintético", type: .checking, currency: "MXN")
        context.insert(account)
        try context.save()
        var (ledger, house, resident, _) = fixture(rent: 100, expense: 0)
        ledger.rents[0].effectiveMonth = date(9)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pending-link-renames-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try PropertyLedgerStore.replace(with: ledger, at: url, notify: false)
        var writer = PendingLinkFailureWriter()
        let workspace = PropertyWorkspaceModel(month: date(9), fileURL: url,
            writeLedger: { proposed, path in try writer.write(proposed, at: path) })
        workspace.configure(context: context, hasAccounts: true)
        await workspace.loadLedger()
        await workspace.refreshPeriod()
        workspace.destination = .property(house.id)
        let outcome = workspace.registerCollection(propertyID: house.id, residentID: resident.id,
            account: account, amount: 100, date: date(9, 10))
        guard case .needsLink(let incomeID) = outcome else {
            Issue.record("Expected the interrupted link to report the receipt UUID")
            return
        }
        #expect(workspace.renameMember(id: resident.id, name: "Integrante renombrado"))
        workspace.ledger.properties[0].name = "Casa renombrada"
        #expect(workspace.save())
        let other = ModelContext(container)
        let income = try #require(other.fetch(FetchDescriptor<Transaction>(
            predicate: #Predicate<Transaction> { $0.id == incomeID })).first)
        let originalDescription = income.descriptionRaw
        income.descriptionRaw = "Otro concepto del mismo cobro"
        try other.save()
        // A look-alike income carrying the original description must never
        // hijack the marker: recovery keys on UUIDs, never on text.
        let salary = try ManualTransactionService.create(account: account, date: date(9, 11),
            description: originalDescription, signedAmount: 5_000, category: nil,
            flowKindRaw: TransactionFlowKind.income.rawValue,
            treatmentKindRaw: TransactionTreatmentKind.regular.rawValue, context: context)
        let links = workspace.pendingLinks(propertyID: house.id)
        #expect(links.count == 1)
        #expect(links.first?.link.paymentTransactionID == incomeID)
        #expect(links.first?.link.residentID == resident.id)
        #expect(links.first?.input?.id == incomeID)
        #expect(links.first?.input?.description == "Otro concepto del mismo cobro")
        #expect(links.allSatisfy { $0.input?.id != salary.id })
        // A soft-deleted income is no longer live money: the banner stops
        // showing it and the orphan marker retires instead of lingering.
        let deleting = ModelContext(container)
        let deletingID = incomeID
        let deletedIncome = try #require(deleting.fetch(FetchDescriptor<Transaction>(
            predicate: #Predicate<Transaction> { $0.id == deletingID })).first)
        deletedIncome.deletedAt = date(9, 25)
        try deleting.save()
        #expect(workspace.pendingLinks(propertyID: house.id).isEmpty)
        #expect(workspace.retirePendingLinks(propertyID: house.id))
        #expect(workspace.ledger.pendingLinks.isEmpty)
        #expect(try PropertyLedgerStore.read(fileURL: url).pendingLinks.isEmpty)
    }

    @Test("Retirement keeps every marker when the saved-payment read fails")
    @MainActor
    func retirementKeepsMarkersWhenTheReadFails() async throws {
        enum FetchFailure: Error { case read }
        let container = try ModelContainer(for: AppSchema.schema,
            configurations: [ModelConfiguration(schema: AppSchema.schema, isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let account = Account(institution: "Banco sintético", type: .checking, currency: "MXN")
        context.insert(account)
        try context.save()
        var (ledger, house, resident, _) = fixture(rent: 100, expense: 0)
        ledger.rents[0].effectiveMonth = date(9)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("retire-read-fails-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try PropertyLedgerStore.replace(with: ledger, at: url, notify: false)
        var writer = PendingLinkFailureWriter()
        var failFetch = true
        let lookupContainer = container
        let workspace = PropertyWorkspaceModel(month: date(9), fileURL: url,
            writeLedger: { proposed, path in try writer.write(proposed, at: path) },
            pendingLinkFetchOverride: { ids in
                guard failFetch else {
                    let fresh = ModelContext(lookupContainer)
                    fresh.autosaveEnabled = false
                    return try fresh.fetch(FetchDescriptor<Transaction>(
                        predicate: #Predicate<Transaction> { ids.contains($0.id) }))
                }
                throw FetchFailure.read
            })
        workspace.configure(context: context, hasAccounts: true)
        await workspace.loadLedger()
        await workspace.refreshPeriod()
        workspace.destination = .property(house.id)
        guard case .needsLink(let incomeID) = workspace.registerCollection(propertyID: house.id,
            residentID: resident.id, account: account, amount: 100, date: date(9, 10)) else {
            Issue.record("Expected the interrupted link to report the receipt UUID")
            return
        }
        #expect(try PropertyLedgerStore.read(fileURL: url).pendingLinks.map(\.paymentTransactionID) == [incomeID])
        // The saved-payment lookup fails: an unreadable store must never read as
        // "the money vanished", so nothing is retired in memory, on disk, or saved.
        #expect(!workspace.retirePendingLinks(propertyID: house.id))
        #expect(workspace.ledger.pendingLinks.map(\.paymentTransactionID) == [incomeID])
        #expect(try PropertyLedgerStore.read(fileURL: url).pendingLinks.map(\.paymentTransactionID) == [incomeID])
        #expect(workspace.error != nil)
        // Once the lookup works again, a soft-deleted income retires as before.
        let deleting = ModelContext(container)
        let deletedIncome = try #require(deleting.fetch(FetchDescriptor<Transaction>(
            predicate: #Predicate<Transaction> { $0.id == incomeID })).first)
        deletedIncome.deletedAt = date(9, 25)
        try deleting.save()
        failFetch = false
        #expect(workspace.retirePendingLinks(propertyID: house.id))
        #expect(workspace.ledger.pendingLinks.isEmpty)
        #expect(try PropertyLedgerStore.read(fileURL: url).pendingLinks.isEmpty)
    }

    @Test("Pending link clears on completed link")
    @MainActor
    func pendingLinkClearsOnCompletedLink() async throws {
        let container = try ModelContainer(for: AppSchema.schema,
            configurations: [ModelConfiguration(schema: AppSchema.schema, isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let account = Account(institution: "Banco sintético", type: .checking, currency: "MXN")
        context.insert(account)
        try context.save()
        var (ledger, house, resident, _) = fixture(rent: 100, expense: 0)
        ledger.rents[0].effectiveMonth = date(9)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pending-link-clears-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try PropertyLedgerStore.replace(with: ledger, at: url, notify: false)
        var writer = PendingLinkFailureWriter()
        let workspace = PropertyWorkspaceModel(month: date(9), fileURL: url,
            writeLedger: { proposed, path in try writer.write(proposed, at: path) })
        workspace.configure(context: context, hasAccounts: true)
        await workspace.loadLedger()
        await workspace.refreshPeriod()
        workspace.destination = .property(house.id)
        let first = workspace.registerCollection(propertyID: house.id, residentID: resident.id,
            account: account, amount: 100, date: date(9, 10))
        guard case .needsLink(let incomeID) = first else {
            Issue.record("Expected the interrupted link to report the receipt UUID")
            return
        }
        #expect(try PropertyLedgerStore.read(fileURL: url).pendingLinks.map(\.paymentTransactionID) == [incomeID])
        let second = workspace.registerCollection(propertyID: house.id, residentID: resident.id,
            account: nil, amount: 100, date: date(9, 10), pendingTransactionID: incomeID)
        guard case .saved = second else { Issue.record("Retry should complete the link"); return }
        // The same final write that persists the applications clears the marker.
        let stored = try PropertyLedgerStore.read(fileURL: url)
        #expect(stored.pendingLinks.isEmpty)
        #expect(stored.paymentApplications.count == 1)
        await workspace.refreshPeriod(force: true)
        #expect(workspace.reports[house.id]?.residents.first?.balance == 0)
    }

    @Test("A failed marker write rejects the collection before any income exists")
    @MainActor
    func markerPrecedesIncomeSoAFailedMarkerWriteCreatesNothing() async throws {
        let container = try ModelContainer(for: AppSchema.schema,
            configurations: [ModelConfiguration(schema: AppSchema.schema, isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let account = Account(institution: "Banco sintético", type: .checking, currency: "MXN")
        context.insert(account)
        try context.save()
        var (ledger, house, resident, _) = fixture(rent: 100, expense: 0)
        ledger.rents[0].effectiveMonth = date(9)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("marker-write-fails-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try PropertyLedgerStore.replace(with: ledger, at: url, notify: false)
        var writer = MarkerFailureWriter()
        let workspace = PropertyWorkspaceModel(month: date(9), fileURL: url,
            writeLedger: { proposed, path in try writer.write(proposed, at: path) })
        workspace.configure(context: context, hasAccounts: true)
        await workspace.loadLedger()
        await workspace.refreshPeriod()
        workspace.destination = .property(house.id)
        guard case .rejected = workspace.registerCollection(propertyID: house.id, residentID: resident.id,
            account: account, amount: 100, date: date(9, 10)) else {
            Issue.record("A failed marker write must reject before creating the income")
            return
        }
        // Marker-first keeps the rejection clean: no income anywhere and no
        // marker on disk — there is nothing to recover because nothing was born.
        #expect(try context.fetch(FetchDescriptor<Transaction>()).isEmpty)
        #expect(try PropertyLedgerStore.read(fileURL: url).pendingLinks.isEmpty)
    }

    @Test("A failed income save leaves no publishable remains and its marker retires")
    @MainActor
    func incomeSaveFailureLeavesNoPublishableRemains() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("income-save-failure-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storeURL = root.appendingPathComponent("store.sqlite")
        let container = try ModelContainer(for: AppSchema.schema,
            configurations: [ModelConfiguration(schema: AppSchema.schema, url: storeURL)])
        let context = container.mainContext
        let account = Account(institution: "Banco sintético", type: .checking, currency: "MXN")
        context.insert(account)
        try context.save()
        var (ledger, house, resident, _) = fixture(rent: 100, expense: 0)
        ledger.rents[0].effectiveMonth = date(9)
        let url = root.appendingPathComponent("PropertyLedger.json")
        try PropertyLedgerStore.replace(with: ledger, at: url, notify: false)
        let workspace = PropertyWorkspaceModel(month: date(9), fileURL: url)
        workspace.configure(context: context, hasAccounts: true)
        await workspace.loadLedger()
        await workspace.refreshPeriod()
        workspace.destination = .property(house.id)
        ManualTransactionService.willFailIncomeSave = true
        defer { ManualTransactionService.willFailIncomeSave = false }
        guard case .rejected = workspace.registerCollection(propertyID: house.id, residentID: resident.id,
            account: account, amount: 100, date: date(9, 10)) else {
            Issue.record("A failed income save must reject without creating money")
            return
        }
        ManualTransactionService.willFailIncomeSave = false
        // The marker is durable, but the income never became publishable money:
        // the failed save deleted its draft, so another save of the very same
        // context still stores no transaction.
        #expect(try PropertyLedgerStore.read(fileURL: url).pendingLinks.count == 1)
        try context.save()
        #expect(try context.fetch(FetchDescriptor<Transaction>()).isEmpty)
        // A relaunched session sees the same emptiness straight from disk.
        let reopenedContainer = try ModelContainer(for: AppSchema.schema,
            configurations: [ModelConfiguration(schema: AppSchema.schema, url: storeURL)])
        #expect(try reopenedContainer.mainContext.fetch(FetchDescriptor<Transaction>()).isEmpty)
        // The orphan marker retires itself: the lookup succeeds and finds no row.
        #expect(workspace.retirePendingLinks(propertyID: house.id))
        #expect(workspace.ledger.pendingLinks.isEmpty)
        #expect(try PropertyLedgerStore.read(fileURL: url).pendingLinks.isEmpty)
    }

    @Test("Pending links decode with a default, validate, and merge newest-wins")
    func pendingLinkStoreFieldDefaultsValidatesAndMerges() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-link-store-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("PropertyLedger.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let house = PropertyRecord(name: "Casa sintética")
        var ledger = PropertyLedger()
        ledger.properties = [house]
        // A schemaVersion 2 file written before the field existed carries no
        // pendingLinks key at all; it must decode with an empty marker list.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try #require(JSONSerialization.jsonObject(with: encoder.encode(ledger)) as? [String: Any])
        object.removeValue(forKey: "pendingLinks")
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        #expect(try PropertyLedgerStore.read(fileURL: url).pendingLinks.isEmpty)

        var unknownProperty = ledger
        unknownProperty.pendingLinks = [PropertyPaymentPendingLink(propertyID: UUID(), residentID: UUID(),
            paymentTransactionID: UUID(), amount: 100)]
        #expect(!PropertyLedgerStore.validate(unknownProperty).isEmpty)
        var nonPositive = ledger
        nonPositive.pendingLinks = [PropertyPaymentPendingLink(propertyID: house.id, residentID: UUID(),
            paymentTransactionID: UUID(), amount: 0)]
        #expect(!PropertyLedgerStore.validate(nonPositive).isEmpty)
        var valid = ledger
        valid.pendingLinks = [PropertyPaymentPendingLink(propertyID: house.id, residentID: UUID(),
            paymentTransactionID: UUID(), amount: 100)]
        #expect(PropertyLedgerStore.validate(valid).isEmpty)

        let paymentID = UUID()
        try PropertyLedgerStore.replace(with: valid, at: url, notify: false)
        var olderLocal = valid
        olderLocal.pendingLinks = [PropertyPaymentPendingLink(propertyID: house.id, residentID: UUID(),
            paymentTransactionID: paymentID, amount: 100, createdAt: date(9, 10))]
        try PropertyLedgerStore.replace(with: olderLocal, at: url, notify: false)
        var newerIncoming = valid
        newerIncoming.pendingLinks = [PropertyPaymentPendingLink(propertyID: house.id, residentID: UUID(),
            paymentTransactionID: paymentID, amount: 250, createdAt: date(9, 20))]
        _ = try PropertyLedgerStore.merge(newerIncoming, at: url, notify: false)
        var merged = try PropertyLedgerStore.read(fileURL: url)
        #expect(merged.pendingLinks.count == 1)
        #expect(merged.pendingLinks[0].amount == 250)
        // A live marker is preferred over a tombstone of the same receipt, even
        // when the tombstone is the newer row.
        var tombstoned = olderLocal
        tombstoned.pendingLinks[0].deletedAt = date(9, 25)
        try PropertyLedgerStore.replace(with: tombstoned, at: url, notify: false)
        var liveIncoming = valid
        liveIncoming.pendingLinks = [PropertyPaymentPendingLink(propertyID: house.id, residentID: UUID(),
            paymentTransactionID: paymentID, amount: 300, createdAt: date(9, 5))]
        _ = try PropertyLedgerStore.merge(liveIncoming, at: url, notify: false)
        merged = try PropertyLedgerStore.read(fileURL: url)
        #expect(merged.pendingLinks.count == 1)
        #expect(merged.pendingLinks[0].deletedAt == nil)
        #expect(merged.pendingLinks[0].amount == 300)
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

    @Test("A receipt edited in another context no longer blocks a new payment")
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
        guard case .saved = result else {
            Issue.record("The new payment must save; a rancid advance stops only itself")
            return
        }
        // The advance receipt and the new payment are exactly the two movements.
        #expect(try context.fetch(FetchDescriptor<Transaction>()).count == 2)
        let payment = try #require(context.fetch(FetchDescriptor<Transaction>()).first { $0.id != earlier.id })
        let stored = try PropertyLedgerStore.read(fileURL: url)
        // The new application exists and funds September's rent on its own receipt.
        let fresh = stored.paymentApplications.filter { $0.paymentTransactionID == payment.id && $0.deletedAt == nil }
        #expect(fresh.count == 1)
        #expect(fresh[0].amount == 100)
        // The rancid advance is neither spent nor deleted: it awaits review.
        let rancid = try #require(stored.paymentApplications.first { $0.id == advanceID })
        #expect(rancid.amount == 100)
        #expect(rancid.deletedAt == nil)
        // Drain the save's refresh task before the container tears down.
        await workspace.refreshPeriod(force: true)
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

    @Test("A missing or changed source forces review and never discounts invalid money")
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

        // The receipt vanished from the inputs entirely: the invalid collection
        // never discounts, so payable carries the full debt as valid data.
        let vanished = PropertySettlementCalculator.report(propertyID: house.id, month: date(9),
            ledger: ledger, transactions: inputs, asOf: date(10))
        var settlement = PropertyMemberSettlement.summarize(propertyID: house.id, residentID: resident.id,
            report: vanished, ledger: ledger, inputs: inputs, asOf: date(10),
            context: .init(canCalculate: true, isClosed: false, historical: false, includeCurrent: true))
        #expect(settlement.sourcesMissing)
        #expect(settlement.status == .review)
        #expect(settlement.due == 250)
        #expect(settlement.payable == 250)
        #expect(settlement.unbackedCollectedMissing == 150)

        // A soft-deleted receipt source behaves the same.
        var deleted = receipt
        deleted.deletedAt = date(9, 15)
        inputs.append(deleted)
        let deletedReport = PropertySettlementCalculator.report(propertyID: house.id, month: date(9),
            ledger: ledger, transactions: inputs, asOf: date(10))
        settlement = PropertyMemberSettlement.summarize(propertyID: house.id, residentID: resident.id,
            report: deletedReport, ledger: ledger, inputs: inputs, asOf: date(10),
            context: .init(canCalculate: true, isClosed: false, historical: false, includeCurrent: true))
        #expect(settlement.sourcesMissing && settlement.status == .review)
        #expect(settlement.due == 250)
        #expect(settlement.payable == 250)

        // A changed advance source is stale: review takes no credit for it, and
        // the payable counts the debt with no advance discount.
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
        #expect(settlement.advanceAvailable == 0)
        #expect(settlement.due == 100)
        #expect(settlement.payable == 100)
        #expect(settlement.advanceAvailable == PropertyCollectionPosting.memberAdvances(
            propertyID: staleHouse.id, residentID: staleResident.id,
            ledger: staleLedger, inputs: staleInputs, asOf: date(9, 10)))
        #expect(settlement.advanceStale == PropertyCollectionPosting.hasChangedAdvanceSource(
            propertyID: staleHouse.id, residentID: staleResident.id,
            ledger: staleLedger, inputs: staleInputs))
    }

    @Test("A current-month receipt with a changed source never discounts silently")
    func changedMonthReceiptNeverDiscountsSilently() throws {
        var (ledger, house, resident, inputs) = fixture(rent: 100, expense: 0)
        var report = PropertySettlementCalculator.report(propertyID: house.id, month: date(9),
            ledger: ledger, transactions: inputs, asOf: date(10))
        let septemberRentID = try #require(report.obligations.first(where: \.isRent)?.id)
        let receipt = PropertyTransactionInput(id: UUID(), amount: 100, postedAt: date(9, 10),
            description: "Cobro del mes", isCashAccount: true)
        inputs.append(receipt)
        ledger.paymentApplications = [PropertyPaymentApplication(propertyID: house.id,
            paymentTransactionID: receipt.id, obligationID: septemberRentID, residentID: resident.id,
            amount: 100, snapshots: PropertySourceSnapshots(capturing: receipt))]
        // Only the description changed after the collection was applied.
        var edited = receipt
        edited.description = "Cobro del mes (corregido)"
        let changedInputs = inputs.filter { $0.id != receipt.id } + [edited]
        report = PropertySettlementCalculator.report(propertyID: house.id, month: date(9),
            ledger: ledger, transactions: changedInputs, asOf: date(10))
        let context = PropertyMemberSettlement.Context(canCalculate: true, isClosed: false,
            historical: false, includeCurrent: true)
        let settlement = PropertyMemberSettlement.summarize(propertyID: house.id,
            residentID: resident.id, report: report, ledger: ledger, inputs: changedInputs,
            asOf: date(10), context: context)
        #expect(settlement.status == .review)
        // The month slice obeys the shared validity rule: the changed receipt
        // never discounts, so the note that says so is true.
        #expect(settlement.monthPaid == 0)
        #expect(settlement.monthBalance == 100)
        #expect(settlement.due == 100)
        #expect(settlement.unbackedCollectedChanged == 100)
        #expect(settlement.payable == 100)
        let account = PropertyMemberAccount.account(propertyID: house.id, residentID: resident.id,
            report: report, ledger: ledger, inputs: changedInputs, asOf: date(10), context: context)
        #expect(account.appliedPayments == 0)
        #expect(account.balanceDue == account.priorDebt
            + max(0, (account.rent ?? 0) + (account.memberSharedShare ?? 0)
                + (account.individualCharges ?? 0) + (account.adjustments ?? 0) - account.appliedPayments))
        #expect(account.balanceDue == 100)
    }

    @Test("A raised receipt amount never overstates the payable")
    func raisedReceiptAmountNeverOverstatesPayable() throws {
        var (ledger, house, resident, inputs) = fixture(rent: 100, expense: 0)
        var report = PropertySettlementCalculator.report(propertyID: house.id, month: date(9),
            ledger: ledger, transactions: inputs, asOf: date(10))
        let septemberRentID = try #require(report.obligations.first(where: \.isRent)?.id)
        let receipt = PropertyTransactionInput(id: UUID(), amount: 100, postedAt: date(9, 10),
            description: "Cobro del mes", isCashAccount: true)
        inputs.append(receipt)
        ledger.paymentApplications = [PropertyPaymentApplication(propertyID: house.id,
            paymentTransactionID: receipt.id, obligationID: septemberRentID, residentID: resident.id,
            amount: 100, snapshots: PropertySourceSnapshots(capturing: receipt))]
        // The receipt was raised to 200 after 100 had been applied: the extra
        // 100 is not collected money, and the payable cannot drop because of it.
        var edited = receipt
        edited.amount = 200
        let changedInputs = inputs.filter { $0.id != receipt.id } + [edited]
        report = PropertySettlementCalculator.report(propertyID: house.id, month: date(9),
            ledger: ledger, transactions: changedInputs, asOf: date(10))
        let context = PropertyMemberSettlement.Context(canCalculate: true, isClosed: false,
            historical: false, includeCurrent: true)
        let settlement = PropertyMemberSettlement.summarize(propertyID: house.id,
            residentID: resident.id, report: report, ledger: ledger, inputs: changedInputs,
            asOf: date(10), context: context)
        #expect(settlement.status == .review)
        #expect(settlement.monthPaid == 0)
        #expect(settlement.due == 100)
        #expect(settlement.payable == 100)
        #expect(settlement.unbackedCollectedChanged == 100)
    }

    @Test("Overpaid month keeps the column honest")
    func overpaidMonthKeepsTheColumnHonest() throws {
        var (ledger, house, resident, inputs) = fixture(rent: 100, expense: 50)
        // The shared charge belongs to September, so the month's components are 150.
        inputs[0].postedAt = date(9, 4)
        let august = PropertySettlementCalculator.report(propertyID: house.id, month: date(8),
            ledger: ledger, transactions: inputs, asOf: date(10))
        ledger.closes = [try #require(PropertySettlementCalculator.close(august, at: date(8, 31)))]
        var report = PropertySettlementCalculator.report(propertyID: house.id, month: date(9),
            ledger: ledger, transactions: inputs, asOf: date(10))
        let septemberRentID = try #require(report.obligations.first(where: \.isRent)?.id)
        let sharedID = try #require(report.obligations.first(where: { !$0.isRent })?.id)
        // Three healthy 100 receipts manually applied for 300 against the
        // month's 150 of charges: no single receipt is overallocated, but the
        // month is — manual over-application, not money.
        let receipts = (0..<3).map { index in
            PropertyTransactionInput(id: UUID(), amount: 100, postedAt: date(9, 12 + index),
                description: "Cobro manual \(index + 1)", isCashAccount: true)
        }
        inputs += receipts
        let obligationIDs = [septemberRentID, septemberRentID, sharedID]
        ledger.paymentApplications = zip(receipts, obligationIDs).map { receipt, obligationID in
            PropertyPaymentApplication(propertyID: house.id, paymentTransactionID: receipt.id,
                obligationID: obligationID, residentID: resident.id, amount: 100,
                snapshots: PropertySourceSnapshots(capturing: receipt))
        }
        report = PropertySettlementCalculator.report(propertyID: house.id, month: date(9),
            ledger: ledger, transactions: inputs, asOf: date(10))
        let context = PropertyMemberSettlement.Context(canCalculate: true, isClosed: false,
            historical: false, includeCurrent: true)
        let account = PropertyMemberAccount.account(propertyID: house.id, residentID: resident.id,
            report: report, ledger: ledger, inputs: inputs, asOf: date(10), context: context)
        #expect(account.priorDebt == 100)
        #expect(account.appliedPayments == 300)
        // The visible row is bounded by the month's charges and names the excess.
        #expect(account.monthCharges == 150)
        #expect(account.boundedAppliedPayments == 150)
        #expect(account.monthCollectionExcess == 150)
        #expect(account.balanceDue == account.priorDebt
            + max(0, (account.rent ?? 0) + (account.memberSharedShare ?? 0)
                + (account.individualCharges ?? 0) + (account.adjustments ?? 0) - account.boundedAppliedPayments))
        #expect(account.balanceDue == account.priorDebt)
        #expect(account.balanceDue == 100)
    }

    @Test("Negative prior debt stays visible")
    func negativePriorDebtStaysVisible() throws {
        var (ledger, house, resident, inputs) = fixture(rent: 100, expense: 0)
        let august = PropertySettlementCalculator.report(propertyID: house.id, month: date(8),
            ledger: ledger, transactions: inputs, asOf: date(10))
        let augustRentID = try #require(august.obligations.first(where: \.isRent)?.id)
        ledger.closes = [try #require(PropertySettlementCalculator.close(august, at: date(8, 31)))]
        // A 150 collection against the closed 100 debt: prior months were
        // overpaid by 50 — a data error the rows must let you see, never hide.
        let receipt = PropertyTransactionInput(id: UUID(), amount: 150, postedAt: date(9, 2),
            description: "Cobro sobre cierre", isCashAccount: true)
        inputs.append(receipt)
        ledger.paymentApplications = [PropertyPaymentApplication(propertyID: house.id,
            paymentTransactionID: receipt.id, obligationID: augustRentID, residentID: resident.id,
            amount: 150, snapshots: PropertySourceSnapshots(capturing: receipt))]
        let report = PropertySettlementCalculator.report(propertyID: house.id, month: date(9),
            ledger: ledger, transactions: inputs, asOf: date(10))
        let context = PropertyMemberSettlement.Context(canCalculate: true, isClosed: false,
            historical: false, includeCurrent: true)
        let settlement = PropertyMemberSettlement.summarize(propertyID: house.id,
            residentID: resident.id, report: report, ledger: ledger, inputs: inputs,
            asOf: date(10), context: context)
        #expect(settlement.priorDebt == -50)
        #expect(settlement.priorPaid == 150)
        #expect(settlement.monthObligation == 100)
        #expect(settlement.monthPaid == 0)
        #expect(settlement.due == 50)
        let account = PropertyMemberAccount.account(propertyID: house.id, residentID: resident.id,
            report: report, ledger: ledger, inputs: inputs, asOf: date(10), context: context)
        #expect(account.priorDebt == -50)
        #expect(account.balanceDue == 50)
        // The visible column sums through the negative row up to the balance.
        let visibleSum = account.priorDebt + max(0, (account.rent ?? 0) + (account.memberSharedShare ?? 0)
            + (account.individualCharges ?? 0) + (account.adjustments ?? 0) - account.appliedPayments)
        #expect(account.balanceDue == visibleSum)
    }

    @Test("An overallocated month receipt forces review and suggests valid data only")
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
        // The overallocated money is not a discount: payable = max(0, due - advanceAvailable).
        #expect(settlement.payable == max(0, (settlement.due ?? 0) - settlement.advanceAvailable))
        #expect(settlement.payable == 100)
        #expect(PropertyCollectionPosting.suggestedAmount(propertyID: house.id, residentID: resident.id,
            report: report, ledger: ledger, inputs: inputs, asOf: date(10)) == settlement.payable)
    }

    @Test("An unbacked application does not consume obligation capacity")
    func unbackedApplicationDoesNotConsumeCapacity() throws {
        var (ledger, house, resident, inputs) = fixture(rent: 1_000, expense: 0)
        var report = PropertySettlementCalculator.report(propertyID: house.id, month: date(9),
            ledger: ledger, transactions: inputs, asOf: date(9, 25))
        let septemberRentID = try #require(report.obligations.first(where: \.isRent)?.id)
        // An old 400 collection was applied against the rent, then its
        // transaction vanished from the inputs: unbacked money, never capacity.
        let ghost = PropertyTransactionInput(id: UUID(), amount: 400, postedAt: date(9, 6),
            description: "Cobro fantasma", isCashAccount: true)
        ledger.paymentApplications = [PropertyPaymentApplication(propertyID: house.id,
            paymentTransactionID: ghost.id, obligationID: septemberRentID, residentID: resident.id,
            amount: 400, snapshots: PropertySourceSnapshots(capturing: ghost))]
        report = PropertySettlementCalculator.report(propertyID: house.id, month: date(9),
            ledger: ledger, transactions: inputs, asOf: date(9, 25))
        let payment = PropertyTransactionInput(id: UUID(), amount: 1_000, postedAt: date(9, 20),
            description: "Cobro nuevo", isCashAccount: true)
        inputs.append(payment)
        let plan = try #require(PropertyCollectionPosting.plan(propertyID: house.id, residentID: resident.id,
            report: report, ledger: ledger, inputs: inputs, receipt: payment, asOf: date(9, 25)))
        // The new payment settles the obligation in full and leaves nothing
        // behind as a spurious advance of the new receipt.
        #expect(plan.applications.map(\.amount) == [1_000])
        #expect(plan.applications.allSatisfy {
            $0.obligationID == septemberRentID && $0.paymentTransactionID == payment.id })
        #expect(plan.updatedAdvances.isEmpty)
        ledger.paymentApplications += plan.applications
        let settled = PropertySettlementCalculator.report(propertyID: house.id, month: date(9),
            ledger: ledger, transactions: inputs, asOf: date(9, 25))
        #expect(settled.residents.first?.balance == 0)
        let settlement = PropertyMemberSettlement.summarize(propertyID: house.id, residentID: resident.id,
            report: settled, ledger: ledger, inputs: inputs, asOf: date(9, 25),
            context: .init(canCalculate: true, isClosed: false, historical: false, includeCurrent: true))
        // The ghost still demands review — a review never claims paid — and its
        // missing money is quantified instead of discounting the balance.
        #expect(settlement.status == .review)
        #expect(settlement.payable == 0)
        #expect(settlement.unbackedCollectedMissing == 400)
    }

    /// The shared validity rule both sides of the ledger obey: whatever the
    /// settlement still publishes as payable, a fresh receipt of exactly that
    /// amount must be able to fund, with nothing stranded as an advance — the
    /// walk's effective capacity and the balance are the same figure.
    private func assertCapacityMatchesPayable(house: PropertyRecord, resident: PropertyResident,
                                               ledger: PropertyLedger, inputs: [PropertyTransactionInput],
                                               badReceipt: PropertyTransactionInput,
                                               expectedPayable: Decimal) throws {
        let context = PropertyMemberSettlement.Context(canCalculate: true, isClosed: false,
            historical: false, includeCurrent: true)
        let report = PropertySettlementCalculator.report(propertyID: house.id, month: date(9),
            ledger: ledger, transactions: inputs, asOf: date(10))
        let settlement = PropertyMemberSettlement.summarize(propertyID: house.id, residentID: resident.id,
            report: report, ledger: ledger, inputs: inputs, asOf: date(10), context: context)
        #expect(settlement.monthPaid == 0)
        #expect(settlement.priorPaid == 0)
        #expect(!settlement.paymentTransactionIDs.contains(badReceipt.id))
        #expect(settlement.payable == expectedPayable)
        let receipt = PropertyTransactionInput(id: UUID(), amount: expectedPayable, postedAt: date(9, 15),
            description: "Cobro de reemplazo", isCashAccount: true)
        let plan = try #require(PropertyCollectionPosting.plan(propertyID: house.id, residentID: resident.id,
            report: report, ledger: ledger, inputs: inputs + [receipt], receipt: receipt, asOf: date(10)))
        #expect(plan.applications.allSatisfy { $0.paymentTransactionID == receipt.id })
        #expect(plan.applications.reduce(Decimal.zero) { $0 + $1.amount } == settlement.payable)
        #expect(plan.updatedAdvances.isEmpty)
    }

    @Test("Future, overapplied, and double-used sources are excluded from balance and capacity alike")
    func invalidSourcesAreExcludedFromBalanceAndCapacityAlike() throws {
        // (a) A source dated in the future is not collected money yet.
        var (futureLedger, futureHouse, futureResident, futureInputs) = fixture(rent: 100, expense: 0)
        let future = PropertyTransactionInput(id: UUID(), amount: 60, postedAt: date(12, 5),
            description: "Cobro futuro", isCashAccount: true)
        futureInputs.append(future)
        var futureReport = PropertySettlementCalculator.report(propertyID: futureHouse.id, month: date(9),
            ledger: futureLedger, transactions: futureInputs, asOf: date(10))
        let futureRentID = try #require(futureReport.obligations.first(where: \.isRent)?.id)
        futureLedger.paymentApplications = [PropertyPaymentApplication(propertyID: futureHouse.id,
            paymentTransactionID: future.id, obligationID: futureRentID, residentID: futureResident.id,
            amount: 60, snapshots: PropertySourceSnapshots(capturing: future))]
        try assertCapacityMatchesPayable(house: futureHouse, resident: futureResident,
            ledger: futureLedger, inputs: futureInputs, badReceipt: future, expectedPayable: 100)

        // (b) An overallocated prior receipt: neither prior debt nor the closed
        // month's capacity counts its excess.
        var (overLedger, overHouse, overResident, overInputs) = fixture(rent: 100, expense: 0)
        let overAugust = PropertySettlementCalculator.report(propertyID: overHouse.id, month: date(8),
            ledger: overLedger, transactions: overInputs, asOf: date(10))
        overLedger.closes = [try #require(PropertySettlementCalculator.close(overAugust, at: date(8, 31)))]
        let overAugustRentID = try #require(overAugust.obligations.first(where: \.isRent)?.id)
        let tight = PropertyTransactionInput(id: UUID(), amount: 40, postedAt: date(9, 4),
            description: "Cobro sobreasignado", isCashAccount: true)
        overInputs.append(tight)
        overLedger.paymentApplications = [
            PropertyPaymentApplication(propertyID: overHouse.id, paymentTransactionID: tight.id,
                obligationID: overAugustRentID, residentID: overResident.id, amount: 30,
                snapshots: PropertySourceSnapshots(capturing: tight)),
            PropertyPaymentApplication(propertyID: overHouse.id, paymentTransactionID: tight.id,
                obligationID: overAugustRentID, residentID: overResident.id, amount: 30,
                snapshots: PropertySourceSnapshots(capturing: tight))]
        try assertCapacityMatchesPayable(house: overHouse, resident: overResident,
            ledger: overLedger, inputs: overInputs, badReceipt: tight, expectedPayable: 200)

        // (c) A receipt used as reimbursement and collection at once.
        var (doubleLedger, doubleHouse, doubleResident, doubleInputs) = fixture(rent: 100, expense: 0)
        let doubleUsed = PropertyTransactionInput(id: UUID(), amount: 40, postedAt: date(9, 7),
            description: "Reembolso y cobro", isCashAccount: true)
        doubleInputs.append(doubleUsed)
        doubleLedger.attributions.append(PropertyTransactionAttribution(propertyID: doubleHouse.id,
            transactionID: doubleUsed.id, kind: .reimbursement, responsibility: .owner))
        var doubleReport = PropertySettlementCalculator.report(propertyID: doubleHouse.id, month: date(9),
            ledger: doubleLedger, transactions: doubleInputs, asOf: date(10))
        let doubleRentID = try #require(doubleReport.obligations.first(where: \.isRent)?.id)
        doubleLedger.paymentApplications = [PropertyPaymentApplication(propertyID: doubleHouse.id,
            paymentTransactionID: doubleUsed.id, obligationID: doubleRentID, residentID: doubleResident.id,
            amount: 40, snapshots: PropertySourceSnapshots(capturing: doubleUsed))]
        try assertCapacityMatchesPayable(house: doubleHouse, resident: doubleResident,
            ledger: doubleLedger, inputs: doubleInputs, badReceipt: doubleUsed, expectedPayable: 100)
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

    @Test("Household adapter keeps closed totals frozen")
    @MainActor
    func householdAdapterKeepsClosedTotalsFrozen() throws {
        let (household, roles, ledger, inputs, close) = householdLedgerWithLegacyClose()
        let report = PropertyHouseholdAdapter.report(household, ledger: ledger,
            transactions: inputs, asOf: date(9, 28))
        // The closed snapshot is reused as-is: its obligations keep exactly the
        // all-shared classification the close froze, never reclassified.
        #expect(report.obligations == close.obligations)
        #expect(report.obligations.allSatisfy { $0.responsibility == .shared })
        // Totals and balances are the snapshot's: Fer 800 (500 fair share +
        // 300 Fer-only counted as shared), user 700, all 1,500 still
        // transaction-backed.
        let fer = try #require(report.residents.first { $0.id == roles.partnerID })
        let user = try #require(report.residents.first { $0.id == roles.userID })
        let ferSnapshot = try #require(close.residents.first { $0.id == roles.partnerID })
        let userSnapshot = try #require(close.residents.first { $0.id == roles.userID })
        #expect(fer.sharedExpenses == 800)
        #expect(fer.individualExpenses == 0)
        #expect(fer.balance == ferSnapshot.obligation)
        #expect(user.balance == userSnapshot.obligation)
        #expect(report.expenses == 1_500)
        #expect(report.warnings.isEmpty)
    }

    @Test("A closed household month stays self-consistent")
    @MainActor
    func closedHouseholdAccountStaysSelfConsistent() throws {
        let (household, roles, ledger, inputs, close) = householdLedgerWithLegacyClose()
        let report = PropertyHouseholdAdapter.report(household, ledger: ledger,
            transactions: inputs, asOf: date(9, 28))
        let account = PropertyMemberAccount.account(propertyID: roles.propertyID,
            residentID: roles.partnerID, report: report, ledger: ledger, inputs: inputs,
            asOf: date(9, 28),
            context: .init(canCalculate: true, isClosed: true, historical: false, includeCurrent: true))
        // Consistent with the frozen classification, not contradicting it: the
        // close counted every row as shared, so the closed account shows no
        // individual charges and the whole transaction-backed total as the pot.
        #expect(account.individualCharges == 0)
        #expect(account.houseSharedTotal == close.obligations
            .filter { $0.transactionID != nil }
            .reduce(Decimal.zero) { $0 + $1.amount })
        #expect(account.houseSharedTotal == 1_500)
        #expect(account.memberSharedShare == 800)
        #expect(account.balanceDue == 800)
    }

    // MARK: - PropertyMemberAccount

    @Test("The account breakdown reproduces the settlement due exactly")
    func accountBreakdownReconcilesWithSettlementDue() throws {
        var (ledger, house, resident, inputs) = fixture()
        let individualID = UUID()
        let sharedSeptemberID = UUID()
        ledger.attributions += [
            PropertyTransactionAttribution(propertyID: house.id, transactionID: individualID,
                kind: .operation, responsibility: .individual(residentID: resident.id)),
            PropertyTransactionAttribution(propertyID: house.id, transactionID: sharedSeptemberID,
                kind: .operation, responsibility: .shared)]
        inputs += [
            PropertyTransactionInput(id: individualID, amount: -30, postedAt: date(9, 3),
                description: "Cargo individual", isCashAccount: true),
            PropertyTransactionInput(id: sharedSeptemberID, amount: -80, postedAt: date(9, 6),
                description: "Servicio de septiembre", isCashAccount: true)]
        ledger.adjustments = [PropertyAdjustment(propertyID: house.id, monthStart: date(9),
            residentID: resident.id, amount: 10, reason: "Ajuste sintético")]
        let august = PropertySettlementCalculator.report(propertyID: house.id, month: date(8),
            ledger: ledger, transactions: inputs, asOf: date(10))
        let augustRentID = try #require(august.obligations.first(where: \.isRent)?.id)
        ledger.closes = [try #require(PropertySettlementCalculator.close(august, at: date(8, 31)))]
        var report = PropertySettlementCalculator.report(propertyID: house.id, month: date(9),
            ledger: ledger, transactions: inputs, asOf: date(10))
        let septemberRentID = try #require(report.obligations.first(where: \.isRent)?.id)
        // One receipt partially covers the closed August rent (70) and this
        // month's rent (30).
        let receipt = PropertyTransactionInput(id: UUID(), amount: 100, postedAt: date(9, 12),
            description: "Cobro parcial", isCashAccount: true)
        inputs.append(receipt)
        ledger.paymentApplications = [
            PropertyPaymentApplication(propertyID: house.id, paymentTransactionID: receipt.id,
                obligationID: augustRentID, residentID: resident.id, amount: 70,
                snapshots: PropertySourceSnapshots(capturing: receipt)),
            PropertyPaymentApplication(propertyID: house.id, paymentTransactionID: receipt.id,
                obligationID: septemberRentID, residentID: resident.id, amount: 30,
                snapshots: PropertySourceSnapshots(capturing: receipt))]
        report = PropertySettlementCalculator.report(propertyID: house.id, month: date(9),
            ledger: ledger, transactions: inputs, asOf: date(10))
        let context = PropertyMemberSettlement.Context(canCalculate: true, isClosed: false,
            historical: false, includeCurrent: true)
        let account = PropertyMemberAccount.account(propertyID: house.id, residentID: resident.id,
            report: report, ledger: ledger, inputs: inputs, asOf: date(10), context: context)
        let settlement = PropertyMemberSettlement.summarize(propertyID: house.id,
            residentID: resident.id, report: report, ledger: ledger, inputs: inputs,
            asOf: date(10), context: context)
        // Month components: rent 100 + shared 80 + individual 30 + adjustment 10.
        // The closed August debt is 150 with 70 already collected.
        #expect(account.rent == 100)
        #expect(account.houseSharedTotal == 80)
        #expect(account.memberSharedShare == 80)
        #expect(account.individualCharges == 30)
        #expect(account.adjustments == 10)
        // Applied payments are the month slice only (30); the 70 that covered
        // the closed August rent travels as priorPaid, already net in priorDebt.
        #expect(account.appliedPayments == settlement.monthPaid)
        #expect(account.appliedPayments == 30)
        #expect(account.priorPaid == settlement.priorPaid)
        #expect(account.priorPaid == 70)
        #expect(account.priorDebt == 80)
        #expect(account.status == .partial)
        // Conservation invariant: the visible rows sum to the balance by hand.
        #expect(account.balanceDue == account.priorDebt
            + max(0, (account.rent ?? 0) + (account.memberSharedShare ?? 0)
                + (account.individualCharges ?? 0) + (account.adjustments ?? 0) - account.appliedPayments))
        #expect(account.balanceDue == settlement.due)
        #expect(account.balanceDue == 270)
    }

    @Test("The shared pot excludes individual charges and reimbursements")
    func houseSharedTotalExcludesIndividualChargesAndReimbursements() throws {
        var (ledger, house, resident, inputs) = fixture(rent: 100, expense: 60)
        // The fixture's shared charge is posted in August; move it into the
        // month under review so it belongs to September's pot.
        inputs[0].postedAt = date(9, 4)
        let individualID = UUID()
        let reimbursementID = UUID()
        ledger.attributions += [
            PropertyTransactionAttribution(propertyID: house.id, transactionID: individualID,
                kind: .operation, responsibility: .individual(residentID: resident.id)),
            PropertyTransactionAttribution(propertyID: house.id, transactionID: reimbursementID,
                kind: .reimbursement, responsibility: .owner)]
        inputs += [
            PropertyTransactionInput(id: individualID, amount: -25, postedAt: date(9, 3),
                description: "Cargo individual", isCashAccount: true),
            PropertyTransactionInput(id: reimbursementID, amount: 40, postedAt: date(9, 7),
                description: "Reembolso", isCashAccount: true)]
        let report = PropertySettlementCalculator.report(propertyID: house.id, month: date(9),
            ledger: ledger, transactions: inputs, asOf: date(9, 28))
        let account = PropertyMemberAccount.account(propertyID: house.id, residentID: resident.id,
            report: report, ledger: ledger, inputs: inputs, asOf: date(9, 28),
            context: .init(canCalculate: true, isClosed: false, historical: false, includeCurrent: true))
        // Only the shared charge forms the pot; the individual charge belongs
        // to the member row and the reimbursement never enters the split.
        #expect(account.houseSharedTotal == 60)
        #expect(account.memberSharedShare == 60)
        #expect(account.individualCharges == 25)
        #expect(account.rent == 100)
        #expect(account.balanceDue == 185)
    }

    @Test("A member share carries the exact custom split amounts, not the monthly percentage")
    @MainActor
    func memberShareIncludesCustomSplits() throws {
        let roles = PropertyHouseholdAdapter.link
        let month = date(9)
        let account = Account(institution: "Banco sintético", type: .checking)
        let custom = Transaction(account: account, postedAt: date(9, 3), amount: -1_000,
            descriptionRaw: "Monto fijo para Fer")
        custom.setHouseholdScope(.included)
        try custom.setHouseholdAllocation(.custom(ferAmount: 400))
        let splitRow = Transaction(account: account, postedAt: date(9, 5), amount: -600,
            descriptionRaw: "Gasto 50/50")
        splitRow.setHouseholdScope(.included)
        splitRow.setExpenseAssignment(.shared)
        splitRow.setSplitMethodOverride(.fiftyFifty)
        // The monthly default would assign Fer 75% (incomes 1_000 vs 3_000);
        // the rows carry exact amounts instead: 400 + 300 of a 1_600 pot.
        let household = HouseholdSettlementReportService.build(monthStart: month,
            transactions: [custom, splitRow],
            setup: HouseholdSettlementSetup(partnerIncomeEstimate: 3_000,
                useUserIncomeManualOverride: true, userIncomeManualOverride: 1_000))
        var ledger = PropertyLedger()
        ledger.householdLink = roles
        ledger.properties = [PropertyRecord(id: roles.propertyID, name: "Casa sintética")]
        ledger.residents = [PropertyResident(id: roles.userID, propertyID: roles.propertyID,
            name: "Tú", activeFrom: .distantPast),
            PropertyResident(id: roles.partnerID, propertyID: roles.propertyID,
                name: "Fer", activeFrom: .distantPast)]
        let inputs = [PropertyTransactionInput(capturing: custom),
                      PropertyTransactionInput(capturing: splitRow)]
        let report = PropertyHouseholdAdapter.report(household, ledger: ledger,
            transactions: inputs, asOf: date(9, 10))
        let fer = PropertyMemberAccount.account(propertyID: roles.propertyID,
            residentID: roles.partnerID, report: report, ledger: ledger, inputs: inputs,
            asOf: date(9, 10),
            context: .init(canCalculate: household.splitAvailable, isClosed: false,
                historical: false, includeCurrent: true))
        #expect(fer.houseSharedTotal == 1_600)
        #expect(fer.memberSharedShare == 700)
        #expect(fer.balanceDue == 700)
    }

    @Test("A month after the asOf month is a projection without month components")
    func accountMarksFutureMonthAsProjection() throws {
        var (ledger, house, resident, inputs) = fixture(rent: 100, expense: 0)
        let context = PropertyMemberSettlement.Context(canCalculate: true, isClosed: false,
            historical: false, includeCurrent: true)
        let october = PropertySettlementCalculator.report(propertyID: house.id, month: date(10),
            ledger: ledger, transactions: inputs, asOf: date(9, 15))
        let projection = PropertyMemberAccount.account(propertyID: house.id, residentID: resident.id,
            report: october, ledger: ledger, inputs: inputs, asOf: date(9, 15), context: context)
        #expect(projection.isProjection)
        #expect(projection.houseSharedTotal == nil)
        #expect(projection.memberSharedShare == nil)
        #expect(projection.individualCharges == nil)
        #expect(projection.rent == nil)
        #expect(projection.adjustments == nil)
        #expect(projection.priorDebt == 0)
        // The projection's settlement still computes a due, but the future is
        // never presented as debt — nor as a payable suggestion.
        let octoberSettlement = PropertyMemberSettlement.summarize(propertyID: house.id,
            residentID: resident.id, report: october, ledger: ledger, inputs: inputs,
            asOf: date(9, 15), context: context)
        #expect(octoberSettlement.due != nil)
        #expect(projection.balanceDue == nil)
        #expect(projection.suggestedPayment == nil)
        // The asOf calendar month is the boundary: it is already a fact.
        let september = PropertySettlementCalculator.report(propertyID: house.id, month: date(9),
            ledger: ledger, transactions: inputs, asOf: date(9, 15))
        let current = PropertyMemberAccount.account(propertyID: house.id, residentID: resident.id,
            report: september, ledger: ledger, inputs: inputs, asOf: date(9, 15), context: context)
        #expect(!current.isProjection)
        #expect(current.rent == 100)
        #expect(current.balanceDue != nil)
        #expect(current.balanceDue == 100)
    }

    @Test("A valid advance counts while a broken advance only flags repair")
    func validAdvancesAreSeparateFromRepairReferences() throws {
        var (ledger, house, resident, inputs) = fixture(rent: 100, expense: 0)
        let original = PropertyTransactionInput(id: UUID(), amount: 60, postedAt: date(9, 3),
            description: "Anticipo cambiado", isCashAccount: true)
        let staleID = PropertyPaymentAdvance.obligationID(propertyID: house.id, paymentTransactionID: original.id)
        ledger.paymentApplications = [
            PropertyPaymentApplication(id: staleID, propertyID: house.id,
                paymentTransactionID: original.id, obligationID: staleID, residentID: resident.id,
                amount: 60, snapshots: PropertySourceSnapshots(capturing: original))]
        var changed = original
        changed.amount = 25
        inputs.append(changed)
        let report = PropertySettlementCalculator.report(propertyID: house.id, month: date(9),
            ledger: ledger, transactions: inputs, asOf: date(9, 20))
        let context = PropertyMemberSettlement.Context(canCalculate: true, isClosed: false,
            historical: false, includeCurrent: true)
        let account = PropertyMemberAccount.account(propertyID: house.id, residentID: resident.id,
            report: report, ledger: ledger, inputs: inputs, asOf: date(9, 20), context: context)
        let settlement = PropertyMemberSettlement.summarize(propertyID: house.id,
            residentID: resident.id, report: report, ledger: ledger, inputs: inputs,
            asOf: date(9, 20), context: context)
        // The 60 advance whose source changed is repair work, never spendable
        // money — but it no longer hides the debt: review keeps a numeric
        // balance and quantifies the unbacked advance separately.
        #expect(account.advancesNeedRepair)
        #expect(account.status == .review)
        #expect(account.balanceDue == settlement.due)
        #expect(account.balanceDue == 100)
        #expect(settlement.unbackedAdvances == 60)
        #expect(account.advanceAvailable == 0)
    }

    @Test("An uncalculable split keeps nil month figures and never zeroes the prior debt")
    func uncalculableAccountKeepsNilInsteadOfZero() throws {
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
        let account = PropertyMemberAccount.account(propertyID: house.id, residentID: resident.id,
            report: september, ledger: ledger, inputs: inputs, asOf: date(10),
            context: .init(canCalculate: canCalculate, isClosed: false, historical: false, includeCurrent: true))
        #expect(account.status == .toCalculate)
        #expect(account.houseSharedTotal == nil)
        #expect(account.memberSharedShare == nil)
        #expect(account.individualCharges == nil)
        #expect(account.rent == nil)
        #expect(account.adjustments == nil)
        #expect(account.balanceDue == nil)
        #expect(account.priorDebt == 150)
    }

    @Test("Account rows sum by hand when prior debt is net")
    func accountRowsSumByHandWhenPriorDebtIsNet() throws {
        var (ledger, house, resident, inputs) = fixture()
        let august = PropertySettlementCalculator.report(propertyID: house.id, month: date(8),
            ledger: ledger, transactions: inputs, asOf: date(10))
        let augustRentID = try #require(august.obligations.first(where: \.isRent)?.id)
        ledger.closes = [try #require(PropertySettlementCalculator.close(august, at: date(8, 31)))]
        // A 20 collection against the closed August debt (150): priorDebt nets
        // to 130 and the 20 surfaces on its own row.
        let prior = PropertyTransactionInput(id: UUID(), amount: 20, postedAt: date(9, 2),
            description: "Cobro previo", isCashAccount: true)
        // The month slice: 30 collected against September's rent.
        let month = PropertyTransactionInput(id: UUID(), amount: 30, postedAt: date(9, 10),
            description: "Cobro del mes", isCashAccount: true)
        inputs += [prior, month]
        var report = PropertySettlementCalculator.report(propertyID: house.id, month: date(9),
            ledger: ledger, transactions: inputs, asOf: date(10))
        let septemberRentID = try #require(report.obligations.first(where: \.isRent)?.id)
        ledger.paymentApplications = [
            PropertyPaymentApplication(propertyID: house.id, paymentTransactionID: prior.id,
                obligationID: augustRentID, residentID: resident.id, amount: 20,
                snapshots: PropertySourceSnapshots(capturing: prior)),
            PropertyPaymentApplication(propertyID: house.id, paymentTransactionID: month.id,
                obligationID: septemberRentID, residentID: resident.id, amount: 30,
                snapshots: PropertySourceSnapshots(capturing: month))]
        report = PropertySettlementCalculator.report(propertyID: house.id, month: date(9),
            ledger: ledger, transactions: inputs, asOf: date(10))
        let account = PropertyMemberAccount.account(propertyID: house.id, residentID: resident.id,
            report: report, ledger: ledger, inputs: inputs, asOf: date(10),
            context: .init(canCalculate: true, isClosed: false, historical: false, includeCurrent: true))
        #expect(account.priorPaid == 20)
        #expect(account.appliedPayments == 30)
        #expect(account.priorDebt == 130)
        // The visible rows sum by hand: 130 + max(0, 100 - 30) = 200.
        let visibleSum = account.priorDebt + max(0, (account.rent ?? 0) + (account.memberSharedShare ?? 0)
            + (account.individualCharges ?? 0) + (account.adjustments ?? 0) - account.appliedPayments)
        #expect(account.balanceDue == visibleSum)
        #expect(account.balanceDue == 200)
    }

    @Test("Review account shows numeric balance without discounting unbacked")
    func reviewAccountShowsNumericBalanceWithoutDiscountingUnbacked() throws {
        var (ledger, house, resident, inputs) = fixture()
        let august = PropertySettlementCalculator.report(propertyID: house.id, month: date(8),
            ledger: ledger, transactions: inputs, asOf: date(10))
        let augustRentID = try #require(august.obligations.first(where: \.isRent)?.id)
        ledger.closes = [try #require(PropertySettlementCalculator.close(august, at: date(8, 31)))]
        // The 150 collection was applied against the closed debt, then its
        // transaction vanished from the inputs.
        let receipt = PropertyTransactionInput(id: UUID(), amount: 150, postedAt: date(9, 5),
            description: "Cobro sobre cierre", isCashAccount: true)
        ledger.paymentApplications = [PropertyPaymentApplication(propertyID: house.id,
            paymentTransactionID: receipt.id, obligationID: augustRentID, residentID: resident.id,
            amount: 150, snapshots: PropertySourceSnapshots(capturing: receipt))]
        let report = PropertySettlementCalculator.report(propertyID: house.id, month: date(9),
            ledger: ledger, transactions: inputs, asOf: date(10))
        let context = PropertyMemberSettlement.Context(canCalculate: true, isClosed: false,
            historical: false, includeCurrent: true)
        let account = PropertyMemberAccount.account(propertyID: house.id, residentID: resident.id,
            report: report, ledger: ledger, inputs: inputs, asOf: date(10), context: context)
        let settlement = PropertyMemberSettlement.summarize(propertyID: house.id,
            residentID: resident.id, report: report, ledger: ledger, inputs: inputs,
            asOf: date(10), context: context)
        #expect(account.status == .review)
        #expect(account.balanceDue != nil)
        // The vanished 150 is not discounted: the balance carries the full
        // closed debt (150) plus the month rent (100), and the unbacked money
        // is quantified separately with its reason.
        #expect(account.balanceDue == 250)
        #expect(settlement.unbackedCollectedMissing == 150)
        #expect(settlement.unbackedCollectedChanged == 0)
        #expect(account.advanceAvailable == 0)
        #expect(account.suggestedPayment == max(0, (account.balanceDue ?? 0) - account.advanceAvailable))
        #expect(account.suggestedPayment == 250)
    }

    @Test("Review account flags unbacked advance separately")
    func reviewAccountFlagsUnbackedAdvanceSeparately() throws {
        var (ledger, house, resident, inputs) = fixture(rent: 100, expense: 0)
        // The real-world shape: a 515.73 advance whose movement cannot be found.
        let movement = PropertyTransactionInput(id: UUID(), amount: Decimal(string: "515.73")!,
            postedAt: date(8, 5), description: "Anticipo sin fuente", isCashAccount: true)
        let advanceID = PropertyPaymentAdvance.obligationID(propertyID: house.id, paymentTransactionID: movement.id)
        ledger.paymentApplications = [PropertyPaymentApplication(id: advanceID, propertyID: house.id,
            paymentTransactionID: movement.id, obligationID: advanceID, residentID: resident.id,
            amount: Decimal(string: "515.73")!, snapshots: PropertySourceSnapshots(capturing: movement))]
        // The movement never joins the inputs: the advance lost its backing.
        let report = PropertySettlementCalculator.report(propertyID: house.id, month: date(9),
            ledger: ledger, transactions: inputs, asOf: date(9, 10))
        let context = PropertyMemberSettlement.Context(canCalculate: true, isClosed: false,
            historical: false, includeCurrent: true)
        let account = PropertyMemberAccount.account(propertyID: house.id, residentID: resident.id,
            report: report, ledger: ledger, inputs: inputs, asOf: date(9, 10), context: context)
        let settlement = PropertyMemberSettlement.summarize(propertyID: house.id,
            residentID: resident.id, report: report, ledger: ledger, inputs: inputs,
            asOf: date(9, 10), context: context)
        #expect(settlement.unbackedAdvances == Decimal(string: "515.73"))
        #expect(account.advanceAvailable == 0)
        #expect(settlement.unbackedCollectedMissing == 0)
        #expect(settlement.unbackedCollectedChanged == 0)
        #expect(account.status == .review)
        #expect(account.balanceDue != nil)
        #expect(account.balanceDue == 100)
    }

    @Test("Suggested payment is never negative with a larger advance")
    func suggestedPaymentIsNeverNegativeWithLargerAdvance() throws {
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
        let account = PropertyMemberAccount.account(propertyID: house.id, residentID: resident.id,
            report: report, ledger: ledger, inputs: inputs, asOf: date(9, 10),
            context: .init(canCalculate: true, isClosed: false, historical: false, includeCurrent: true))
        #expect(account.balanceDue == 100)
        #expect(account.advanceAvailable == 200)
        // The advance exceeds the balance: the suggestion floors at 0 and the
        // remainder stays available — it is not lost and not an error.
        #expect(account.suggestedPayment == 0)
        #expect(account.advanceAvailable == 200)
    }

    @Test("Whole-second comparison floors both sides, including pre-1970 dates")
    func isSameWholeSecondFloorsBothSides() {
        #expect(PropertySettlementCalculator.isSameWholeSecond(
            Date(timeIntervalSince1970: 1_700_000_000.75),
            Date(timeIntervalSince1970: 1_700_000_000.1)))
        #expect(!PropertySettlementCalculator.isSameWholeSecond(
            Date(timeIntervalSince1970: 1_700_000_000.75),
            Date(timeIntervalSince1970: 1_700_000_001.0)))
        // Pre-1970 instants floor toward minus infinity: -0.9 and -0.1 share the
        // -1 second, while 0.1 already belongs to the next second.
        #expect(PropertySettlementCalculator.isSameWholeSecond(
            Date(timeIntervalSince1970: -0.9),
            Date(timeIntervalSince1970: -0.1)))
        #expect(!PropertySettlementCalculator.isSameWholeSecond(
            Date(timeIntervalSince1970: -0.9),
            Date(timeIntervalSince1970: 0.1)))
    }

    @Test("A sub-second attribution snapshot survives the disk round trip without review")
    func attributionSubSecondRoundTripDoesNotFlagReview() throws {
        var (ledger, house, _, inputs) = fixture(rent: 100, expense: 50)
        let subSecond = date(8, 4).addingTimeInterval(0.75)
        inputs[0].postedAt = subSecond
        ledger.attributions[0].sourceSnapshots = PropertySourceSnapshots(capturing: inputs[0])
        // The sidecar encodes ISO8601 without fractional seconds: the snapshot
        // comes back from disk truncated to the whole second.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("subsecond-attribution-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try PropertyLedgerStore.replace(with: ledger, at: url, notify: false)
        let stored = try PropertyLedgerStore.read(fileURL: url)
        let storedSnapshot = try #require(stored.attributions.first?.sourcePostedAtSnapshot)
        #expect(storedSnapshot != subSecond)
        // The live input keeps full precision: whole-second comparison sees the
        // same instant and the attribution still counts as an obligation.
        let report = PropertySettlementCalculator.report(propertyID: house.id, month: date(8),
            ledger: stored, transactions: inputs, asOf: date(10))
        #expect(!report.warnings.contains { $0.contains("desde que se atribuyó") })
        #expect(report.obligations.contains { $0.transactionID == inputs[0].id && $0.amount == 50 })
    }

    @Test("A posted date moved to another second still flags review")
    func postedAtMovedToAnotherSecondStillFlagsReview() throws {
        var (ledger, house, _, inputs) = fixture(rent: 100, expense: 50)
        let subSecond = date(8, 4).addingTimeInterval(0.75)
        inputs[0].postedAt = subSecond
        ledger.attributions[0].sourceSnapshots = PropertySourceSnapshots(capturing: inputs[0])
        // A real edit crosses the second boundary: the snapshot no longer matches.
        inputs[0].postedAt = subSecond.addingTimeInterval(1)
        let report = PropertySettlementCalculator.report(propertyID: house.id, month: date(8),
            ledger: ledger, transactions: inputs, asOf: date(10))
        #expect(report.warnings.contains { $0.contains("cambió (fecha) desde que se atribuyó") })
    }

    @Test("A frozen close keeps a sub-second source date without a discrepancy")
    func frozenCloseRoundTripDoesNotFlagDiscrepancy() throws {
        var (ledger, house, _, inputs) = fixture(rent: 100, expense: 50)
        let subSecond = date(8, 4).addingTimeInterval(0.75)
        inputs[0].postedAt = subSecond
        let august = PropertySettlementCalculator.report(propertyID: house.id, month: date(8),
            ledger: ledger, transactions: inputs, asOf: date(10))
        ledger.closes = [try #require(PropertySettlementCalculator.close(august, at: date(8, 31)))]
        // The persisted close loses the fraction on disk while the live input
        // keeps full precision.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("subsecond-close-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try PropertyLedgerStore.replace(with: ledger, at: url, notify: false)
        let stored = try PropertyLedgerStore.read(fileURL: url)
        let storedClose = try #require(stored.closes.first)
        let obligation = try #require(storedClose.obligations.first { $0.transactionID == inputs[0].id })
        #expect(obligation.sourcePostedAt != nil && obligation.sourcePostedAt! != subSecond)
        let frozen = PropertySettlementCalculator.frozenReport(storedClose, ledger: stored,
            transactions: inputs, asOf: date(10))
        #expect(!frozen.warnings.contains { $0.contains("después del cierre") })
    }

    @Test("A registered collection discounts once after the disk round trip")
    @MainActor
    func paymentDiscountsOnceAfterDiskRoundTripWithoutFalseReview() async throws {
        let container = try ModelContainer(for: AppSchema.schema,
            configurations: [ModelConfiguration(schema: AppSchema.schema, isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let account = Account(institution: "Banco sintético", type: .checking, currency: "MXN")
        context.insert(account)
        try context.save()
        var (ledger, house, resident, _) = fixture(rent: 100, expense: 0)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("subsecond-collection-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try PropertyLedgerStore.replace(with: ledger, at: url, notify: false)
        let workspace = PropertyWorkspaceModel(month: date(9), fileURL: url)
        workspace.configure(context: context, hasAccounts: true)
        await workspace.loadLedger()
        await workspace.refreshPeriod()
        workspace.destination = .property(house.id)
        // The payment lands with a sub-second instant: SwiftData keeps the
        // fraction, the sidecar keeps only the second.
        let paymentDate = date(9, 10).addingTimeInterval(0.75)
        guard case .saved = workspace.registerCollection(propertyID: house.id, residentID: resident.id,
            account: account, amount: 100, date: paymentDate) else {
            Issue.record("The collection should save with a sub-second payment date")
            return
        }
        let storedApplication = try #require(try PropertyLedgerStore.read(fileURL: url).paymentApplications.first)
        #expect(storedApplication.sourcePostedAtSnapshot != paymentDate)
        // A fresh context and workspace re-read everything from disk, exactly
        // like a relaunched session.
        let reopenedContext = ModelContext(container)
        let reopened = PropertyWorkspaceModel(month: date(9), fileURL: url)
        reopened.configure(context: reopenedContext, hasAccounts: true)
        await reopened.loadLedger()
        await reopened.refreshPeriod()
        reopened.destination = .property(house.id)
        let report = try #require(reopened.reports[house.id])
        let row = try #require(report.residents.first { $0.id == resident.id })
        // The payment discounts exactly once and no changed-source warning
        // blames the date.
        #expect(row.paid == 100)
        #expect(row.balance == 0)
        #expect(!report.warnings.contains { $0.contains("cambió") })
        let settlement = try #require(reopened.memberSettlements(propertyID: house.id, report: report)
            .first { $0.residentID == resident.id })
        #expect(settlement.status == .paid)
        #expect(settlement.monthPaid == 100)
    }

    @Test("Review warnings name each changed field")
    func reviewWarningNamesEachChangedField() throws {
        var (ledger, house, _, inputs) = fixture(rent: 100, expense: 50)
        let original = date(8, 4).addingTimeInterval(0.75)
        inputs[0].postedAt = original
        ledger.attributions[0].sourceSnapshots = PropertySourceSnapshots(capturing: inputs[0])
        // Only the date moved to another second: the warning names the date
        // and nothing else.
        inputs[0].postedAt = original.addingTimeInterval(1)
        var report = PropertySettlementCalculator.report(propertyID: house.id, month: date(8),
            ledger: ledger, transactions: inputs, asOf: date(10))
        let dateOnly = try #require(report.warnings.first { $0.contains("cambió (fecha) desde que se atribuyó") })
        #expect(dateOnly.contains("(fecha)"))
        #expect(!dateOnly.contains("importe"))
        // Amount and currency changed together: both named, in declared order.
        inputs[0].postedAt = original
        inputs[0].amount = -60
        inputs[0].currencyCode = "USD"
        report = PropertySettlementCalculator.report(propertyID: house.id, month: date(8),
            ledger: ledger, transactions: inputs, asOf: date(10))
        #expect(report.warnings.contains { $0.contains("cambió (importe, moneda) desde que se atribuyó") })
    }

    @Test("A changed receipt exposes its movement and the fields that changed")
    func changedReceiptExposesItsMovementAndFields() throws {
        var (ledger, house, resident, inputs) = fixture(rent: 100, expense: 0)
        var report = PropertySettlementCalculator.report(propertyID: house.id, month: date(9),
            ledger: ledger, transactions: inputs, asOf: date(10))
        let septemberRentID = try #require(report.obligations.first(where: \.isRent)?.id)
        let receipt = PropertyTransactionInput(id: UUID(), amount: 100, postedAt: date(9, 10),
            description: "Cobro del mes", isCashAccount: true)
        inputs.append(receipt)
        ledger.paymentApplications = [PropertyPaymentApplication(propertyID: house.id,
            paymentTransactionID: receipt.id, obligationID: septemberRentID, residentID: resident.id,
            amount: 100, snapshots: PropertySourceSnapshots(capturing: receipt))]
        // The receipt's date moved to another second after the collection was
        // applied: the exposure names the movement and the field that changed.
        var edited = receipt
        edited.postedAt = receipt.postedAt.addingTimeInterval(1)
        let changedInputs = inputs.filter { $0.id != receipt.id } + [edited]
        report = PropertySettlementCalculator.report(propertyID: house.id, month: date(9),
            ledger: ledger, transactions: changedInputs, asOf: date(10))
        let context = PropertyMemberSettlement.Context(canCalculate: true, isClosed: false,
            historical: false, includeCurrent: true)
        let expected = [PropertyMemberSettlement.UnbackedReceipt(id: receipt.id, amount: 100,
            fields: [.postedAt])]
        let settlement = PropertyMemberSettlement.summarize(propertyID: house.id,
            residentID: resident.id, report: report, ledger: ledger, inputs: changedInputs,
            asOf: date(10), context: context)
        #expect(settlement.unbackedChangedReceipts == expected)
        #expect(settlement.unbackedCollectedChanged == 100)
        let account = PropertyMemberAccount.account(propertyID: house.id, residentID: resident.id,
            report: report, ledger: ledger, inputs: changedInputs, asOf: date(10), context: context)
        #expect(account.unbackedChangedReceipts == expected)
    }

}
