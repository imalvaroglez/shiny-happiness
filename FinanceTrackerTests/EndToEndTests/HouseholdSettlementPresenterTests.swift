import Foundation
import Testing
@testable import FinanceTracker

@Suite("Household Settlement Presenter")
@MainActor
struct HouseholdSettlementPresenterTests {
    private let presenter = HouseholdSettlementPresenter(formatters: .stableForTests)

    private func state(
        setup: HouseholdSettlementSetup = HouseholdSettlementFixture.setup,
        report: HouseholdSettlementReport? = nil,
        customSplitIsValid: Bool = true,
        canSave: Bool = true
    ) -> HouseholdSettlementScreenState {
        let report = report ?? HouseholdSettlementFixture.report(setup: setup)
        return presenter.state(
            selectedMonth: HouseholdSettlementFixture.month,
            setup: setup,
            report: report,
            validation: HouseholdSettlementValidationState.make(
                setup: setup,
                report: report,
                customSplitIsValid: customSplitIsValid,
                canSave: canSave
            ),
            saveStatus: "Saved"
        )
    }

    @Test("Fixture state preserves Household cleanup copy")
    func fixturePresentationCopy() {
        let result = state()

        #expect(result.navigationTitle == "Household Settlement")
        #expect(result.reportMonthTitle == "June 2026")
        #expect(result.subtitle == "Review Household expenses you explicitly included — Mine, Shared, and Fer.")
        #expect(!result.monthlySetup.rowLabels.contains("Report Month"))
        #expect(result.monthlySetup.partnerIncomeHelper == "Manual monthly estimate. Used only for this report.")
        #expect(result.summary.resultLabel == "To recover from Fer")
        #expect(result.summary.recoverAmount == "$3,249.95")
        #expect(summaryLine(.split, in: result).value == "You 86.84% / Fer 13.16%")
        // Household-scoped breakdown labels and count-aware description.
        #expect(summaryLine(.totalPaidByUser, in: result).label == "Total household expenses paid by you")
        #expect(summaryLine(.sharedExpenses, in: result).label == "Shared household expenses")
        #expect(summaryLine(.userFinalCost, in: result).label == "Your final household cost")
        #expect(result.transactionSection(.userOnly).title == "Your household expenses")
        #expect(result.summary.resultDescription.contains("included in Household Settlement"))
    }

    @Test("Fixture recover amount comes from calculator")
    func fixtureRecoverAmountMatchesCalculator() {
        let report = HouseholdSettlementFixture.report()

        #expect(roundedCents(report.amountToRecoverFromPartner) == HouseholdSettlementFixture.expectedRecoverAmount)
        #expect(state(report: report).summary.recoverAmount == "$3,249.95")
    }

    @Test("Income warnings are exposed as presentation state")
    func incomeWarnings() {
        let expense = category("Rent", kind: .expense)

        let missingUserReport = report(
            [transaction(amount: -200, category: expense, assignment: .shared)],
            setup: HouseholdSettlementSetup(partnerIncomeEstimate: 1_000)
        )
        let missingUser = state(setup: HouseholdSettlementSetup(partnerIncomeEstimate: 1_000), report: missingUserReport)
        #expect(missingUser.warning?.messages.contains { $0.contains("Your salary income is missing") } == true)

        let salary = category("Salary", kind: .income)
        let missingPartnerReport = report(
            [
                transaction(amount: 1_000, category: salary),
                transaction(amount: -200, category: expense, assignment: .shared),
            ],
            setup: HouseholdSettlementSetup(partnerIncomeEstimate: 0)
        )
        let missingPartner = state(setup: HouseholdSettlementSetup(partnerIncomeEstimate: 0), report: missingPartnerReport)
        #expect(missingPartner.warning?.messages.contains { $0.contains("Fer income estimate is missing") } == true)

        let zeroReport = report(
            [transaction(amount: -200, category: expense, assignment: .shared)],
            setup: HouseholdSettlementSetup(partnerIncomeEstimate: 0)
        )
        let zeroIncome = state(setup: HouseholdSettlementSetup(partnerIncomeEstimate: 0), report: zeroReport)
        #expect(zeroIncome.warning?.messages.contains { $0.contains("Income assumptions are incomplete") } == true)
    }

    @Test("Split labels use injected percent formatter")
    func splitLabels() {
        let fifty = HouseholdSettlementSetup(partnerIncomeEstimate: 0, splitMethod: .fiftyFifty)
        #expect(summaryLine(.split, in: state(setup: fifty)).value == "You 50.00% / Fer 50.00%")

        let custom = HouseholdSettlementSetup(
            partnerIncomeEstimate: 0,
            splitMethod: .customPercent,
            customUserPercent: 70,
            customPartnerPercent: 30
        )
        #expect(summaryLine(.split, in: state(setup: custom)).value == "You 70.00% / Fer 30.00%")
    }

    @Test("Invalid custom split has setup validation copy")
    func invalidCustomSplit() {
        let setup = HouseholdSettlementSetup(
            partnerIncomeEstimate: 0,
            splitMethod: .customPercent,
            customUserPercent: 70,
            customPartnerPercent: 20
        )
        let result = state(setup: setup, customSplitIsValid: false, canSave: false)

        #expect(result.monthlySetup.customSplitError == "Custom split must add to 100%.")
        #expect(result.monthlySetup.setupStatusText == "Fix setup to save")
    }

    @Test("Sections are ordered, summarized, and initially collapsed")
    func orderedCollapsedSections() {
        let result = state()

        #expect(result.transactionSections.map(\.id) == [.partnerOnly, .shared, .userOnly])
        #expect(result.transactionSections.allSatisfy { !$0.initiallyExpanded })
        #expect(result.transactionSection(.partnerOnly).countText == "1 transaction")
        #expect(result.transactionSection(.shared).countText == "4 transactions")
        #expect(result.transactionSection(.userOnly).countText == "1 transaction")
        #expect(result.transactionSection(.partnerOnly).subtotal == "$500.00")
        #expect(result.transactionSection(.userOnly).subtotal == "$900.00")
        #expect(result.transactionSection(.shared).rows.contains {
            $0.metadata.contains("Shared · Proportional by income")
        })
    }

    @Test("Custom rows stay in Shared with derived exact metadata")
    func customRowPresentation() throws {
        let expense = category("Mixed purchase", kind: .expense)
        let custom = transaction(amount: -2_200, category: expense, assignment: .user)
        try custom.setCustomFerAmount(Decimal(string: "1466.67")!)
        let setup = HouseholdSettlementSetup(
            partnerIncomeEstimate: 500,
            useUserIncomeManualOverride: true,
            userIncomeManualOverride: 500
        )
        let report = report([custom], setup: setup)
        let row = state(setup: setup, report: report).transactionSection(.shared).rows.first

        #expect(row?.metadata.contains("Shared · Custom split") == true)
        #expect(row?.metadata.contains("You 33.33% / Fer 66.67%") == true)
        #expect(row?.amount == "$2,200.00")
    }

    @Test("Empty reports retain three compact zero-value headers")
    func emptySectionHeaders() {
        let setup = HouseholdSettlementSetup(partnerIncomeEstimate: 0, splitMethod: .fiftyFifty)
        let report = report([], setup: setup)
        let result = state(setup: setup, report: report)

        #expect(result.transactionSections.count == 3)
        #expect(result.transactionSections.allSatisfy { $0.countText == "0 transactions" })
        #expect(result.transactionSections.allSatisfy { $0.subtotal == "$0.00" })
    }

    private func summaryLine(
        _ id: HouseholdSettlementSummaryState.Line.ID,
        in state: HouseholdSettlementScreenState
    ) -> HouseholdSettlementSummaryState.Line {
        state.summary.breakdownLines.first { $0.id == id }!
    }

    private func roundedCents(_ amount: Decimal) -> Decimal {
        var input = amount
        var output = Decimal()
        NSDecimalRound(&output, &input, 2, .plain)
        return output
    }

    private func account() -> Account {
        Account(institution: "Bank", type: .checking, currency: "MXN", nickname: "Checking")
    }

    private func category(_ name: String, kind: CategoryKind) -> FinanceTracker.Category {
        FinanceTracker.Category(name: name, kind: kind)
    }

    private func transaction(
        amount: Decimal,
        category: FinanceTracker.Category,
        assignment: ExpenseAssignment = .user
    ) -> Transaction {
        let tx = Transaction(
            account: account(),
            postedAt: HouseholdSettlementFixture.month.startDate,
            amount: amount,
            descriptionRaw: category.name,
            category: category
        )
        tx.setHouseholdScope(.included)
        tx.setExpenseAssignment(assignment)
        return tx
    }

    private func report(
        _ transactions: [Transaction],
        setup: HouseholdSettlementSetup
    ) -> HouseholdSettlementReport {
        HouseholdSettlementReportService.build(
            monthStart: HouseholdSettlementFixture.month.startDate,
            transactions: transactions,
            setup: setup
        )
    }

    @Test("Due-date breakdown line and deferred badge surface in presentation")
    func dueDatePresentation() throws {
        let food = category("Dinner", kind: .expense)
        let tx = transaction(amount: -1_000, category: food, assignment: .partner)
        let nextMonth = HouseholdSettlementFixture.month.addingMonths(1)
        let due = nextMonth.startDate.addingTimeInterval(10 * 86_400)
        let report = HouseholdSettlementReportService.build(
            monthStart: HouseholdSettlementFixture.month.startDate,
            transactions: [tx],
            dueDates: [tx.id: due],
            setup: HouseholdSettlementFixture.setup
        )
        let result = state(report: report)

        // The pending line and the renamed Fer-only line are present.
        #expect(summaryLine(.pendingForUpcomingMonths, in: result).label == "Pending for upcoming months")
        #expect(summaryLine(.partnerOnlyPaidByUser, in: result).label == "Fer-only due this month")

        // The deferred Fer row carries the "Pasa a" badge and the picker flag.
        let ferSection = result.transactionSection(.partnerOnly)
        let deferredRow = try #require(ferSection.rows.first { $0.deferredToMonth != nil })
        #expect(deferredRow.status == "Pasa a \(presenter.formatters.monthTitle(nextMonth.startDate))")
        #expect(deferredRow.showsDueDatePicker)
        // Count includes the deferred row; subtotal is due-only (zero here).
        #expect(ferSection.countText == "1 transaction")
        #expect(ferSection.subtotal == "$0.00")
    }
}
