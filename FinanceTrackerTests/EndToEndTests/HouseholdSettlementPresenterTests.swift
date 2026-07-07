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
        #expect(result.subtitle == "Review shared and Fer-only expenses paid from your accounts.")
        #expect(!result.monthlySetup.rowLabels.contains("Report Month"))
        #expect(result.monthlySetup.partnerIncomeHelper == "Manual monthly estimate. Used only for this report.")
        #expect(result.summary.resultLabel == "To recover from Fer")
        #expect(result.summary.recoverAmount == "$1,783.28")
        #expect(summaryLine(.split, in: result).value == "You 86.84% / Fer 13.16%")
    }

    @Test("Fixture recover amount comes from calculator")
    func fixtureRecoverAmountMatchesCalculator() {
        let report = HouseholdSettlementFixture.report()

        #expect(roundedCents(report.amountToRecoverFromPartner) == HouseholdSettlementFixture.expectedRecoverAmount)
        #expect(state(report: report).summary.recoverAmount == "$1,783.28")
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
}
