import Foundation
import SwiftData
import Testing
@testable import FinanceTracker

@Suite("Household Settlement Report")
@MainActor
struct HouseholdSettlementReportTests {
    private let monthStart = HouseholdPartnerIncomeService.monthStart(for: Date(timeIntervalSince1970: 1_780_000_000))

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(schema: AppSchema.schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: AppSchema.schema, configurations: [config])
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
        assignment: ExpenseAssignment = .user,
        split: HouseholdSplitMethod = .monthlyDefault,
        userPercent: Decimal? = nil,
        partnerPercent: Decimal? = nil
    ) -> Transaction {
        let tx = Transaction(
            account: account(),
            postedAt: monthStart,
            amount: amount,
            descriptionRaw: category.name,
            category: category
        )
        tx.setExpenseAssignment(assignment)
        tx.setSplitMethodOverride(split)
        tx.customUserPercent = userPercent
        tx.customPartnerPercent = partnerPercent
        return tx
    }

    private func report(_ transactions: [Transaction], partnerIncome: Decimal = 0) -> HouseholdSettlementReport {
        HouseholdSettlementReportService.build(
            monthStart: monthStart,
            transactions: transactions,
            partnerIncomeEstimate: partnerIncome
        )
    }

    private func report(_ transactions: [Transaction], setup: HouseholdSettlementSetup) -> HouseholdSettlementReport {
        HouseholdSettlementReportService.build(
            monthStart: monthStart,
            transactions: transactions,
            setup: setup
        )
    }

    @Test("YearMonth navigation changes calendar months without days")
    func yearMonthNavigation() {
        let july = YearMonth(year: 2026, month: 7)

        #expect(july.addingMonths(-1) == YearMonth(year: 2026, month: 6))
        #expect(july.addingMonths(1) == YearMonth(year: 2026, month: 8))
        #expect(YearMonth(year: 2026, month: 12).addingMonths(1) == YearMonth(year: 2027, month: 1))
    }

    @Test("User assignment is excluded from settlement")
    func userAssignmentExcluded() {
        let food = category("Groceries", kind: .expense)
        let result = report([
            transaction(amount: -100, category: food, assignment: .user)
        ], partnerIncome: 1_000)

        #expect(result.totalSharedExpenses == 0)
        #expect(result.amountToRecoverFromPartner == 0)
        #expect(result.excludedPersonalRows.count == 1)
    }

    @Test("Shared and partner assignments feed the right groups")
    func sharedAndPartnerAssignments() {
        let food = category("Groceries", kind: .expense)
        let result = report([
            transaction(amount: -300, category: food, assignment: .shared),
            transaction(amount: -120, category: food, assignment: .partner)
        ], partnerIncome: 1_000)

        #expect(result.totalSharedExpenses == 300)
        #expect(result.partnerOnlyTotal == 120)
        #expect(result.sharedRows.count == 1)
        #expect(result.partnerRows.count == 1)
    }

    @Test("Only salary and compensation count as household user income")
    func salaryBaseOnlyIncludesSalaryAndCompensation() {
        let salary = category("Salary", kind: .income)
        let compensation = category("Compensation", kind: .income)
        let interest = category("Interest", kind: .income)
        let refund = category("Refund", kind: .income)
        let cashback = category("Cashback", kind: .income)
        let transfer = category("Transfer", kind: .transfer)
        let result = report([
            transaction(amount: 1_000, category: salary),
            transaction(amount: 500, category: compensation),
            transaction(amount: 100, category: interest),
            transaction(amount: 50, category: refund),
            transaction(amount: 25, category: cashback),
            transaction(amount: 10_000, category: transfer)
        ])

        #expect(result.userSalaryIncome == 1_500)
    }

    @Test("Partner estimate is not a transaction")
    func partnerEstimateDoesNotCreateTransaction() throws {
        let container = try makeContainer()
        let context = container.mainContext

        try HouseholdPartnerIncomeService.upsert(month: monthStart, amount: 20_000, notes: nil, context: context)

        #expect(try context.fetchCount(FetchDescriptor<Transaction>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<HouseholdPartnerIncomeEstimate>()) == 1)
    }

    @Test("Partner estimate does not affect net worth")
    func partnerEstimateDoesNotAffectNetWorth() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = account()
        context.insert(account)
        context.insert(AccountBalanceSnapshot(account: account, date: monthStart, amount: 1_000, kind: .manualOpening))
        try context.save()

        let before = DashboardViewModel()
        before.dateRange = DateRange(start: .distantPast, end: .distantFuture)
        before.configure(context: context)
        guard case .consolidated(let beforeSnapshot) = before.snapshot else {
            Issue.record("Expected consolidated snapshot")
            return
        }

        try HouseholdPartnerIncomeService.upsert(month: monthStart, amount: 20_000, notes: nil, context: context)

        let after = DashboardViewModel()
        after.dateRange = DateRange(start: .distantPast, end: .distantFuture)
        after.configure(context: context)
        guard case .consolidated(let afterSnapshot) = after.snapshot else {
            Issue.record("Expected consolidated snapshot")
            return
        }

        #expect(afterSnapshot.netWorth == beforeSnapshot.netWorth)
        #expect(afterSnapshot.totalIncome == beforeSnapshot.totalIncome)
    }

    @Test("Proportional split uses salary and partner income")
    func proportionalSplit() {
        let salary = category("Salary", kind: .income)
        let food = category("Groceries", kind: .expense)
        let result = report([
            transaction(amount: 600, category: salary),
            transaction(amount: -1_000, category: food, assignment: .shared)
        ], partnerIncome: 400)

        #expect(result.userIncomeShare == Decimal(string: "0.6")!)
        #expect(result.partnerIncomeShare == Decimal(string: "0.4")!)
        #expect(result.userFairShare == 600)
        #expect(result.partnerFairShare == 400)
    }

    @Test("Manual salary override replaces detected salary for settlement only")
    func manualSalaryOverride() {
        let salary = category("Salary", kind: .income)
        let food = category("Groceries", kind: .expense)
        let result = report([
            transaction(amount: 1_000, category: salary),
            transaction(amount: -1_000, category: food, assignment: .shared)
        ], setup: HouseholdSettlementSetup(
            partnerIncomeEstimate: 500,
            useUserIncomeManualOverride: true,
            userIncomeManualOverride: 500
        ))

        #expect(result.detectedUserSalaryIncome == 1_000)
        #expect(result.userSalaryIncome == 500)
        #expect(result.userFairShare == 500)
        #expect(result.partnerFairShare == 500)
    }

    @Test("Monthly 50/50 and custom split settings")
    func monthlySplitSettings() {
        let food = category("Groceries", kind: .expense)

        let fifty = report([
            transaction(amount: -1_000, category: food, assignment: .shared)
        ], setup: HouseholdSettlementSetup(partnerIncomeEstimate: 0, splitMethod: .fiftyFifty))
        #expect(fifty.userFairShare == 500)
        #expect(fifty.partnerFairShare == 500)

        let custom = report([
            transaction(amount: -1_000, category: food, assignment: .shared)
        ], setup: HouseholdSettlementSetup(
            partnerIncomeEstimate: 0,
            splitMethod: .customPercent,
            customUserPercent: 70,
            customPartnerPercent: 30
        ))
        #expect(custom.userFairShare == 700)
        #expect(custom.partnerFairShare == 300)
    }

    @Test("Transaction split overrides beat monthly default")
    func splitOverrides() {
        let salary = category("Salary", kind: .income)
        let food = category("Groceries", kind: .expense)
        let result = report([
            transaction(amount: 900, category: salary),
            transaction(amount: -1_000, category: food, assignment: .shared, split: .fiftyFifty),
            transaction(amount: -1_000, category: food, assignment: .shared, split: .customPercent, userPercent: 70, partnerPercent: 30)
        ], partnerIncome: 100)

        #expect(result.userFairShare == 1_200)
        #expect(result.partnerFairShare == 800)
    }

    @Test("Zero income edge cases")
    func zeroIncomeCases() {
        let salary = category("Salary", kind: .income)
        let food = category("Groceries", kind: .expense)

        let zeroPartner = report([
            transaction(amount: 1_000, category: salary),
            transaction(amount: -200, category: food, assignment: .shared)
        ], partnerIncome: 0)
        #expect(zeroPartner.partnerFairShare == 0)

        let zeroUser = report([
            transaction(amount: -200, category: food, assignment: .shared)
        ], partnerIncome: 1_000)
        #expect(zeroUser.blockedReason != nil)
        #expect(zeroUser.partnerFairShare == 0)
        #expect(zeroUser.warnings.contains { $0.contains("Your salary income is missing") })

        let zeroTotal = report([
            transaction(amount: -200, category: food, assignment: .shared)
        ], partnerIncome: 0)
        #expect(zeroTotal.blockedReason != nil)
        #expect(zeroTotal.userFairShare == 0)
        #expect(zeroTotal.partnerFairShare == 0)

        #expect(zeroPartner.blockedReason == nil)
        #expect(zeroPartner.warnings.contains { $0.contains("Fer income estimate is missing") })
    }

    @Test("Amount to recover assumes user paid selected expenses")
    func amountToRecoverWhenUserPaidEverything() {
        let salary = category("Salary", kind: .income)
        let food = category("Groceries", kind: .expense)
        let result = report([
            transaction(amount: 500, category: salary),
            transaction(amount: -100, category: food, assignment: .shared),
            transaction(amount: -80, category: food, assignment: .partner)
        ], partnerIncome: 500)

        #expect(result.totalPaidByUser == 180)
        #expect(result.amountToRecoverFromPartner == 130)
    }

    @Test("Unassigned transactions appear in review group")
    func unassignedTransactionsGroup() {
        let food = category("Groceries", kind: .expense)
        let result = report([
            transaction(amount: -100, category: food, assignment: .unassigned),
            transaction(amount: -200, category: food, assignment: .shared)
        ], setup: HouseholdSettlementSetup(partnerIncomeEstimate: 0, splitMethod: .fiftyFifty))

        #expect(result.unassignedRows.count == 1)
        #expect(result.sharedRows.count == 1)
        #expect(result.totalSharedExpenses == 200)
    }

    @Test("Monthly setup persists split and manual override fields")
    func partnerEstimatePersistsMonthlySetup() throws {
        let container = try makeContainer()
        let context = container.mainContext

        try HouseholdPartnerIncomeService.upsert(
            month: monthStart,
            amount: 20_000,
            notes: "July setup",
            useUserIncomeManualOverride: true,
            userIncomeManualOverride: 50_000,
            splitMethod: .customPercent,
            customUserPercent: 80,
            customPartnerPercent: 20,
            context: context
        )

        let saved = try #require(try context.fetch(FetchDescriptor<HouseholdPartnerIncomeEstimate>()).first)
        #expect(saved.amount == 20_000)
        #expect(saved.useUserIncomeManualOverride)
        #expect(saved.userIncomeManualOverride == 50_000)
        #expect(saved.splitMethod == .customPercent)
        #expect(saved.customUserPercent == 80)
        #expect(saved.customPartnerPercent == 20)
        #expect(saved.notes == "July setup")
    }

    @Test("Copy summary uses WhatsApp-friendly labels")
    func copySummaryText() {
        let salary = category("Salary", kind: .income)
        let food = category("Groceries", kind: .expense)
        let result = report([
            transaction(amount: 500, category: salary),
            transaction(amount: -100, category: food, assignment: .shared),
            transaction(amount: -80, category: food, assignment: .partner)
        ], partnerIncome: 500)

        #expect(result.plainTextSummary.contains("Household Settlement"))
        #expect(result.plainTextSummary.contains("Fer estimate"))
        #expect(result.plainTextSummary.contains("Fer-only expenses paid by you"))
        #expect(result.plainTextSummary.contains("Total to recover from Fer"))
    }
}
