import AppKit
import Foundation
import SwiftData
import SwiftUI
import Testing
@testable import FinanceTracker

// `Transaction` is ambiguous once SwiftUI is imported (SwiftUI.Transaction),
// so bind the app model for this file. Same convention as the qualified
// `FinanceTracker.Category` uses below.
private typealias Transaction = FinanceTracker.Transaction

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
        partnerPercent: Decimal? = nil,
        customFerAmount: Decimal? = nil,
        scope: HouseholdScope = .included
    ) -> Transaction {
        let tx = Transaction(
            account: account(),
            postedAt: monthStart,
            amount: amount,
            descriptionRaw: category.name,
            category: category
        )
        tx.setHouseholdScope(scope)
        tx.setExpenseAssignment(assignment)
        tx.setSplitMethodOverride(split)
        tx.customUserPercent = userPercent
        tx.customPartnerPercent = partnerPercent
        if let customFerAmount {
            try! tx.setCustomFerAmount(customFerAmount)
        }
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

    private func report(_ transactions: [Transaction], dueDates: [UUID: Date], partnerIncome: Decimal = 0) -> HouseholdSettlementReport {
        HouseholdSettlementReportService.build(
            monthStart: monthStart,
            transactions: transactions,
            dueDates: dueDates,
            setup: HouseholdSettlementSetup(partnerIncomeEstimate: partnerIncome)
        )
    }

    /// Same as `transaction(...)` but with an explicit posted date (for cross-month
    /// due-date scenarios) and an explicit report month.
    private func transaction(
        amount: Decimal,
        category: FinanceTracker.Category,
        postedAt: Date,
        assignment: ExpenseAssignment,
        scope: HouseholdScope = .included
    ) -> Transaction {
        let tx = Transaction(
            account: account(),
            postedAt: postedAt,
            amount: amount,
            descriptionRaw: category.name,
            category: category
        )
        tx.setHouseholdScope(scope)
        tx.setExpenseAssignment(assignment)
        return tx
    }

    private func build(
        reportMonth: YearMonth,
        transactions: [Transaction],
        dueDates: [UUID: Date] = [:],
        partnerIncome: Decimal = 0
    ) -> HouseholdSettlementReport {
        HouseholdSettlementReportService.build(
            monthStart: reportMonth.startDate,
            transactions: transactions,
            dueDates: dueDates,
            setup: HouseholdSettlementSetup(partnerIncomeEstimate: partnerIncome)
        )
    }

    @Test("YearMonth navigation changes calendar months without days")
    func yearMonthNavigation() {
        let july = YearMonth(year: 2026, month: 7)

        #expect(july.addingMonths(-1) == YearMonth(year: 2026, month: 6))
        #expect(july.addingMonths(1) == YearMonth(year: 2026, month: 8))
        #expect(YearMonth(year: 2026, month: 12).addingMonths(1) == YearMonth(year: 2027, month: 1))
    }

    @Test("User assignment is included in paid total but not Fer recovery")
    func userAssignmentIncludedWithoutRecovery() {
        let food = category("Groceries", kind: .expense)
        let result = report([
            transaction(amount: -100, category: food, assignment: .user)
        ], partnerIncome: 1_000)

        #expect(result.totalSharedExpenses == 0)
        #expect(result.amountToRecoverFromPartner == 0)
        #expect(result.userRows.count == 1)
        #expect(result.totalPaidByUser == 100)
        #expect(result.userFinalCost == 100)
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
        #expect(result.ferRows.count == 1)
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

    @Test("Legacy transaction split overrides preserve exact intent")
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

    @Test("Screenshot case keeps the Fer-only amount distinct from the zero proportional share")
    func screenshotRecoveryComposition() {
        let salary = category("Salary", kind: .income)
        let shared = category("Shared expenses", kind: .expense)
        let ferOnly = category("Fer only", kind: .expense)
        let result = report([
            transaction(amount: 7_900, category: salary),
            transaction(amount: -5_260, category: shared, assignment: .shared),
            transaction(amount: -4_229, category: ferOnly, assignment: .partner),
        ], setup: HouseholdSettlementSetup(partnerIncomeEstimate: 0))

        #expect(result.partnerFairShare == 0)
        #expect(result.partnerOnlyTotal == 4_229)
        #expect(result.amountToRecoverFromPartner == 4_229)
    }

    @Test("Legacy Unassigned transactions resolve and repair to User")
    func unassignedTransactionsGroup() {
        let food = category("Groceries", kind: .expense)
        let legacy = transaction(amount: -100, category: food)
        legacy.expenseAssignmentRaw = "unassigned"
        let result = report([legacy], setup: HouseholdSettlementSetup(partnerIncomeEstimate: 0, splitMethod: .fiftyFifty))

        #expect(result.userRows.count == 1)
        #expect(HouseholdAllocationRepairService.repair(transactions: [legacy]))
        #expect(legacy.expenseAssignment == .user)
        #expect(legacy.expenseAssignmentRaw == nil)
    }

    @Test("Custom exact amount drives reconciled totals")
    func customExactAmountAndClarifiedTotals() {
        let food = category("Groceries", kind: .expense)
        let setup = HouseholdSettlementSetup(
            partnerIncomeEstimate: Decimal(string: "130.40")!,
            useUserIncomeManualOverride: true,
            userIncomeManualOverride: Decimal(string: "869.60")!
        )
        let result = report([
            transaction(amount: -500, category: food, assignment: .user),
            transaction(amount: -1_000, category: food, assignment: .shared),
            transaction(
                amount: -2_200,
                category: food,
                assignment: .custom,
                customFerAmount: Decimal(string: "1466.67")!
            ),
            transaction(amount: -900, category: food, assignment: .partner),
        ], setup: setup)

        #expect(result.totalPaidByUser == 4_600)
        #expect(result.amountToRecoverFromPartner == Decimal(string: "2497.07")!)
        #expect(result.userFinalCost == Decimal(string: "2102.93")!)
        #expect(result.sharedRows.count == 2)
        #expect(result.ferRows.count == 1)
        #expect(result.userRows.count == 1)
        let custom = result.sharedRows.first { $0.transaction.expenseAssignment == .custom }
        #expect(custom?.amount == 2_200)
        #expect(custom?.partnerShare == Decimal(string: "1466.67")!)
        #expect(custom?.userShare == Decimal(string: "733.33")!)
    }

    @Test("Credits, transfers, duplicates, and excluded treatments remain outside settlement")
    func excludedRowsDoNotRegress() {
        let food = category("Groceries", kind: .expense)
        let transferCategory = category("Transfer", kind: .transfer)
        let expense = transaction(amount: -100, category: food)
        let credit = transaction(amount: 20, category: food)
        let transfer = transaction(amount: -50, category: transferCategory)
        transfer.isTransfer = true
        let duplicate = transaction(amount: -60, category: food)
        duplicate.isDuplicate = true
        let fee = transaction(amount: -70, category: food)
        fee.setReportingTreatment(.fee)

        let result = report([expense, credit, transfer, duplicate, fee])

        #expect(result.totalPaidByUser == 100)
        #expect(result.userRows.map(\.id) == [expense.id])
        #expect(result.amountToRecoverFromPartner == 0)
    }

    @Test("Custom assignment validates and normalizes endpoints")
    func customValidationAndNormalization() throws {
        let food = category("Groceries", kind: .expense)
        let tx = transaction(amount: -2_200, category: food)

        #expect(throws: HouseholdAllocationError.negativeAmount) {
            try tx.setCustomFerAmount(-1)
        }
        #expect(throws: HouseholdAllocationError.exceedsExpense) {
            try tx.setCustomFerAmount(2_201)
        }
        #expect(throws: HouseholdAllocationError.requiresCurrencyPrecision) {
            try tx.setCustomFerAmount(Decimal(string: "1.001")!)
        }

        try tx.setCustomFerAmount(0)
        #expect(tx.expenseAssignment == .user)
        try tx.setCustomFerAmount(2_200)
        #expect(tx.expenseAssignment == .partner)
        try tx.setCustomFerAmount(Decimal(string: "1466.67")!)
        #expect(tx.expenseAssignment == .custom)
        #expect(tx.customFerAmount == Decimal(string: "1466.67")!)
        tx.setExpenseAssignment(.shared)
        #expect(tx.customFerAmount == nil)
        #expect(tx.customPartnerPercent == nil)
    }

    @Test("Custom exact allocation persists and reloads")
    func customPersistsAndReloads() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let checking = account()
        let food = category("Groceries", kind: .expense)
        let tx = Transaction(
            account: checking,
            postedAt: monthStart,
            amount: -2_200,
            descriptionRaw: "Mixed purchase",
            category: food
        )
        try tx.setCustomFerAmount(Decimal(string: "1466.67")!)
        tx.setHouseholdScope(.included)
        context.insert(checking)
        context.insert(food)
        context.insert(tx)
        try context.save()

        let restored = try #require(try context.fetch(FetchDescriptor<Transaction>()).first)
        #expect(restored.expenseAssignment == .custom)
        #expect(restored.customFerAmount == Decimal(string: "1466.67")!)
        let result = report([restored], setup: HouseholdSettlementSetup(partnerIncomeEstimate: 0, splitMethod: .fiftyFifty))
        #expect(result.sharedRows.first?.userShare == Decimal(string: "733.33")!)
    }

    @Test("Legacy override migration is exact and idempotent")
    func legacyOverrideMigration() {
        let food = category("Groceries", kind: .expense)
        let fifty = transaction(amount: -2_200, category: food, assignment: .shared, split: .fiftyFifty)
        let percentage = transaction(
            amount: -2_200,
            category: food,
            assignment: .shared,
            split: .customPercent,
            userPercent: Decimal(string: "33.333333")!,
            partnerPercent: Decimal(string: "66.666667")!
        )
        let zero = transaction(
            amount: -500,
            category: food,
            assignment: .shared,
            split: .customPercent,
            userPercent: 100,
            partnerPercent: 0
        )
        let full = transaction(
            amount: -500,
            category: food,
            assignment: .shared,
            split: .customPercent,
            userPercent: 0,
            partnerPercent: 100
        )
        let sameAsCurrentRatio = transaction(
            amount: -1_000,
            category: food,
            assignment: .shared,
            split: .customPercent,
            userPercent: 60,
            partnerPercent: 40
        )

        #expect(HouseholdAllocationRepairService.repair(
            transactions: [fifty, percentage, zero, full, sameAsCurrentRatio]
        ))
        #expect(fifty.expenseAssignment == .custom)
        #expect(fifty.customFerAmount == 1_100)
        #expect(percentage.expenseAssignment == .custom)
        #expect(percentage.customFerAmount == Decimal(string: "1466.67")!)
        #expect(percentage.customUserPercent == nil)
        #expect(percentage.splitMethodOverrideRaw == nil)
        #expect(zero.expenseAssignment == .user)
        #expect(full.expenseAssignment == .partner)
        #expect(sameAsCurrentRatio.expenseAssignment == .custom)
        #expect(sameAsCurrentRatio.customFerAmount == 400)

        percentage.amount = -3_000
        #expect(!HouseholdAllocationRepairService.repair(transactions: [fifty, percentage]))
        #expect(percentage.customFerAmount == Decimal(string: "1466.67")!)
        let changedIncome = report(
            [percentage],
            setup: HouseholdSettlementSetup(
                partnerIncomeEstimate: 9_000,
                useUserIncomeManualOverride: true,
                userIncomeManualOverride: 1_000
            )
        )
        #expect(changedIncome.partnerFairShare == Decimal(string: "1466.67")!)
    }

    @Test("Unknown assignment values repair safely to User")
    func unknownAssignmentRepairsToUser() {
        let food = category("Groceries", kind: .expense)
        let tx = transaction(amount: -100, category: food)
        tx.expenseAssignmentRaw = "future-value"

        #expect(tx.expenseAssignment == .user)
        #expect(HouseholdAllocationRepairService.repair(transactions: [tx]))
        #expect(tx.expenseAssignmentRaw == nil)
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

        #expect(result.plainTextSummary.contains("Cuentas del hogar"))
        #expect(result.plainTextSummary.contains("Estimación de Fer"))
        #expect(result.plainTextSummary.contains("Por cobrar a Fer este mes"))
        #expect(result.plainTextSummary.contains("Pendiente para los próximos meses"))
        #expect(result.plainTextSummary.contains("Total por cobrar a Fer"))
    }

    // MARK: - Explicit inclusion

    @Test("Excluded transactions contribute nothing regardless of assignment")
    func excludedTransactionsContributeNothing() {
        let food = category("Groceries", kind: .expense)
        let mine = transaction(amount: -900, category: food, assignment: .user, scope: .excluded)
        let shared = transaction(amount: -1_000, category: food, assignment: .shared, scope: .excluded)
        let fer = transaction(amount: -879.50, category: food, assignment: .partner, scope: .excluded)
        let custom = transaction(
            amount: -2_200,
            category: food,
            assignment: .custom,
            customFerAmount: Decimal(string: "1466.67")!,
            scope: .excluded
        )

        let result = report([mine, shared, fer, custom], partnerIncome: 1_000)

        #expect(result.includedTransactionCount == 0)
        #expect(result.totalPaidByUser == 0)
        #expect(result.amountToRecoverFromPartner == 0)
        #expect(result.userFinalCost == 0)
        #expect(result.userRows.isEmpty)
        #expect(result.sharedRows.isEmpty)
        #expect(result.ferRows.isEmpty)
    }

    @Test("Mixed month: personal excluded expense never affects the report")
    func mixedMonthExcludesPersonalSpending() {
        let food = category("Groceries", kind: .expense)
        let personal = transaction(amount: -576, category: food, assignment: .user, scope: .excluded)
        let shared = transaction(amount: -1_000, category: food, assignment: .shared, scope: .included)
        let fer = transaction(amount: Decimal(string: "-879.50")!, category: food, assignment: .partner, scope: .included)
        let custom = transaction(
            amount: -2_200,
            category: food,
            assignment: .custom,
            customFerAmount: 1_467,
            scope: .included
        )

        let result = report(
            [personal, shared, fer, custom],
            setup: HouseholdSettlementSetup(partnerIncomeEstimate: 1_000, splitMethod: .fiftyFifty)
        )

        #expect(result.includedTransactionCount == 3)
        #expect(result.totalPaidByUser == 1_000 + Decimal(string: "879.50")! + 2_200)
        #expect(result.ferRows.count == 1)
        // Shared bucket holds both the Shared and the Custom-split transaction.
        #expect(result.sharedRows.count == 2)
        // To recover = Fer's 50% shared portion (500) + custom 1467 + fer-only 879.50
        #expect(result.amountToRecoverFromPartner == 500 + 1_467 + Decimal(string: "879.50")!)
    }

    @Test("Scope migration derives included/excluded from legacy assignment and is idempotent")
    func scopeMigrationDerivesAndIsIdempotent() {
        let food = category("Groceries", kind: .expense)

        func legacy(_ raw: String?) -> Transaction {
            let tx = Transaction(account: account(), postedAt: monthStart, amount: -1_000, descriptionRaw: food.name, category: food)
            tx.expenseAssignmentRaw = raw
            return tx
        }

        let nilUser = legacy(nil)
        let explicitUser = legacy("user")
        let unassigned = legacy("unassigned")
        let unknown = legacy("future")
        let shared = legacy("shared")
        let partner = legacy("partner")
        let custom = legacy("custom")
        custom.customPartnerPercent = 400

        #expect(HouseholdAllocationRepairService.repair(transactions: [nilUser, explicitUser, unassigned, unknown, shared, partner, custom]))

        for excluded in [nilUser, explicitUser, unassigned, unknown] {
            #expect(excluded.householdScopeRaw == "excluded")
        }
        for included in [shared, partner, custom] {
            #expect(included.householdScopeRaw == "included")
        }
        // Exact custom amount preserved, not recalculated.
        #expect(custom.customFerAmount == 400)

        // Second pass: no changes (idempotent).
        #expect(!HouseholdAllocationRepairService.repair(transactions: [nilUser, shared, custom]))
        #expect(nilUser.householdScopeRaw == "excluded")
        #expect(shared.householdScopeRaw == "included")
        #expect(custom.customFerAmount == 400)
    }

    @Test("Missing and unknown scope values decode as excluded")
    func missingAndUnknownScopeDecodeAsExcluded() {
        let food = category("Groceries", kind: .expense)
        let missing = Transaction(account: account(), postedAt: monthStart, amount: -100, descriptionRaw: food.name, category: food)
        #expect(missing.householdScopeRaw == nil)
        #expect(missing.householdScope == .excluded)
        #expect(!missing.isIncludedInHouseholdSettlement)

        let unknown = Transaction(account: account(), postedAt: monthStart, amount: -100, descriptionRaw: food.name, category: food, householdScopeRaw: "bogus")
        #expect(unknown.householdScope == .excluded)
    }

    @Test("setHouseholdScope always persists an explicit raw value")
    func setHouseholdScopePersistsExplicitRaw() {
        let food = category("Groceries", kind: .expense)
        let tx = Transaction(account: account(), postedAt: monthStart, amount: -100, descriptionRaw: food.name, category: food)
        #expect(tx.householdScopeRaw == nil)

        tx.setHouseholdScope(.excluded)
        #expect(tx.householdScopeRaw == "excluded")
        tx.setHouseholdScope(.included)
        #expect(tx.householdScopeRaw == "included")
        tx.setHouseholdScope(.excluded)
        #expect(tx.householdScopeRaw == "excluded")
    }

    @Test("Excluding an included transaction preserves its assignment and custom amount")
    func excludingPreservesAssignmentAndCustomAmount() {
        let food = category("Groceries", kind: .expense)
        let tx = transaction(
            amount: -2_200,
            category: food,
            assignment: .custom,
            customFerAmount: Decimal(string: "1466.67")!,
            scope: .included
        )

        tx.setHouseholdScope(.excluded)
        #expect(tx.expenseAssignment == .custom)
        #expect(tx.customFerAmount == Decimal(string: "1466.67")!)

        // Re-including restores participation without losing the allocation.
        tx.setHouseholdScope(.included)
        let result = report([tx], partnerIncome: 1_000)
        #expect(result.sharedRows.count == 1)
        #expect(result.sharedRows.first?.partnerShare == Decimal(string: "1466.67")!)
    }

    @Test("Scope survives save and reload across relaunch")
    func scopePersistsAcrossReload() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let checking = account()
        let food = category("Groceries", kind: .expense)
        let included = Transaction(account: checking, postedAt: monthStart, amount: -1_000, descriptionRaw: "Rent", category: food)
        included.setExpenseAssignment(.shared)
        included.setHouseholdScope(.included)
        let excluded = Transaction(account: checking, postedAt: monthStart, amount: -50, descriptionRaw: "Coffee", category: food)
        excluded.setHouseholdScope(.excluded)
        context.insert(checking)
        context.insert(food)
        context.insert(included)
        context.insert(excluded)
        try context.save()

        let restored = try context.fetch(FetchDescriptor<Transaction>())
        let inc = restored.first { $0.descriptionRaw == "Rent" }
        let exc = restored.first { $0.descriptionRaw == "Coffee" }
        #expect(inc?.householdScopeRaw == "included")
        #expect(exc?.householdScopeRaw == "excluded")
    }

    @Test("V3 on-disk store migrates cleanly to the live model and defaults scope safely")
    func onDiskStoreMigratesScopeField() throws {
        // Write a real on-disk store under a pre-householdScopeRaw schema (V3),
        // then reopen it with the current AppSchema. This exercises the staged
        // migration path for older stores; the additive scope column is inferred
        // by SwiftData and decodes safely (nil → excluded) before the repair pass.
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("finance-scope-v3-\(UUID()).store")
        defer {
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + "-wal"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + "-shm"))
        }

        do {
            let v3Schema = Schema(versionedSchema: FinanceTrackerSchemaV3.self)
            let config = ModelConfiguration(schema: v3Schema, url: storeURL)
            let container = try ModelContainer(for: v3Schema, configurations: [config])
            let context = container.mainContext
            let acct = FinanceTrackerSchemaV3.Account(
                institution: "Bank",
                type: .checking,
                currency: "MXN",
                nickname: "Checking"
            )
            context.insert(acct)
            context.insert(FinanceTrackerSchemaV3.Transaction(
                account: acct,
                postedAt: monthStart,
                amount: -1_000,
                descriptionRaw: "Rent",
                flowKindRaw: TransactionFlowKind.expense.rawValue
            ))
            try context.save()
        }

        let config = ModelConfiguration(schema: AppSchema.schema, url: storeURL)
        let migrated = try ModelContainer(
            for: AppSchema.schema,
            migrationPlan: FinanceTrackerMigrationPlan.self,
            configurations: [config]
        )
        let context = migrated.mainContext
        let tx = try #require(try context.fetch(FetchDescriptor<Transaction>()).first)

        #expect(tx.householdScope == .excluded)
        #expect(tx.expenseAssignment == .user)

        HouseholdAllocationRepairService.repairIfNeeded(context: context)
        let repaired = try #require(try context.fetch(FetchDescriptor<Transaction>()).first)
        #expect(repaired.householdScopeRaw == "excluded")
    }

    // MARK: - Settlement due dates

    @Test("YearMonth is Comparable with year/month ordering")
    func yearMonthComparable() {
        #expect(YearMonth(year: 2026, month: 7) < YearMonth(year: 2026, month: 8))
        #expect(YearMonth(year: 2026, month: 12) < YearMonth(year: 2027, month: 1))
        #expect(!(YearMonth(year: 2026, month: 8) < YearMonth(year: 2026, month: 8)))
    }

    @Test("July Fer purchase due in August: July shows deferred, August recovers")
    func deferredAcrossMonths() {
        let food = category("Dinner", kind: .expense)
        let july = YearMonth(year: 2026, month: 7)
        let august = YearMonth(year: 2026, month: 8)
        let july13 = july.startDate.addingTimeInterval(12 * 86_400)
        let augDue = august.startDate.addingTimeInterval(10 * 86_400)

        let tx = transaction(amount: -1_000, category: food, postedAt: july13, assignment: .partner)
        let dueDates = [tx.id: augDue]

        let julyReport = build(reportMonth: july, transactions: [tx], dueDates: dueDates)
        #expect(julyReport.ferRows.isEmpty)
        #expect(julyReport.deferredFerRows.count == 1)
        #expect(julyReport.amountToRecoverFromPartner == 0)
        #expect(julyReport.pendingForUpcomingMonths == 1_000)
        // Cash left the account in July → counts in July's total paid.
        #expect(julyReport.totalPaidByUser == 1_000)
        #expect(julyReport.userFinalCost == 1_000)
        // Deferred-only month is not an empty state.
        #expect(julyReport.hasIncludedTransactions)

        // In August the same transaction (older, pulled in by the second fetch) is due
        // and recoverable; it does NOT count in August's total paid.
        let augustReport = build(reportMonth: august, transactions: [tx], dueDates: dueDates)
        #expect(augustReport.ferRows.count == 1)
        #expect(augustReport.deferredFerRows.isEmpty)
        #expect(augustReport.amountToRecoverFromPartner == 1_000)
        #expect(augustReport.totalPaidByUser == 0)
        #expect(augustReport.userFinalCost == -1_000)
    }

    @Test("Nil due date defaults to the purchase month")
    func nilDueDateDefaultsToPurchaseMonth() {
        let food = category("Dinner", kind: .expense)
        let tx = transaction(amount: -500, category: food, postedAt: monthStart, assignment: .partner)

        let result = build(reportMonth: YearMonth(date: monthStart), transactions: [tx], dueDates: [:])
        #expect(result.ferRows.count == 1)
        #expect(result.deferredFerRows.isEmpty)
        #expect(result.amountToRecoverFromPartner == 500)
        #expect(result.pendingForUpcomingMonths == 0)
    }

    @Test("Same-month due date recovers now")
    func sameMonthDueDate() {
        let food = category("Dinner", kind: .expense)
        let tx = transaction(amount: -300, category: food, postedAt: monthStart, assignment: .partner)
        let due = monthStart.addingTimeInterval(20 * 86_400) // still same month

        let result = build(reportMonth: YearMonth(date: monthStart), transactions: [tx], dueDates: [tx.id: due])
        #expect(result.ferRows.count == 1)
        #expect(result.deferredFerRows.isEmpty)
        #expect(result.amountToRecoverFromPartner == 300)
    }

    @Test("Stored due date before purchase defensively resolves to purchase month")
    func earlierDueDateDefensivelyResolves() {
        let food = category("Dinner", kind: .expense)
        let tx = transaction(amount: -300, category: food, postedAt: monthStart, assignment: .partner)
        // An impossible earlier due date must not hide the transaction in an earlier month.
        let earlier = monthStart.addingTimeInterval(-40 * 86_400)

        let result = build(reportMonth: YearMonth(date: monthStart), transactions: [tx], dueDates: [tx.id: earlier])
        #expect(result.ferRows.count == 1)
        #expect(result.deferredFerRows.isEmpty)
        #expect(result.amountToRecoverFromPartner == 300)
    }

    @Test("Shared and user rows ignore due dates and stay in their posted month")
    func nonPartnerRowsIgnoreDueDates() {
        let food = category("Dinner", kind: .expense)
        let shared = transaction(amount: -1_000, category: food, postedAt: monthStart, assignment: .shared)
        let mine = transaction(amount: -200, category: food, postedAt: monthStart, assignment: .user)
        // A due date next month should NOT defer shared/user rows.
        let nextMonth = YearMonth(date: monthStart).addingMonths(1).startDate
        let dueDates: [UUID: Date] = [shared.id: nextMonth, mine.id: nextMonth]

        let result = build(reportMonth: YearMonth(date: monthStart), transactions: [shared, mine], dueDates: dueDates, partnerIncome: 1_000)
        #expect(result.sharedRows.count == 1)
        #expect(result.userRows.count == 1)
        #expect(result.ferRows.isEmpty)
        #expect(result.deferredFerRows.isEmpty)
        #expect(result.totalPaidByUser == 1_200)
    }

    @Test("V5 on-disk store migrates to V6 and supports a due-date override")
    func v5StoreMigratesToV6WithDueDateOverride() throws {
        // Write a real on-disk store under V5 (no SettlementDueDateOverride model
        // yet), reopen with the current AppSchema (V6) through the staged migration,
        // verify prior data survived, then write an override and reopen again.
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("finance-v6-\(UUID()).store")
        defer {
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + "-wal"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + "-shm"))
        }

        var savedTxID: UUID?
        do {
            let v5Schema = Schema(versionedSchema: FinanceTrackerSchemaV5.self)
            let config = ModelConfiguration(schema: v5Schema, url: storeURL)
            let container = try ModelContainer(for: v5Schema, configurations: [config])
            let context = container.mainContext
            let acct = Account(institution: "Bank", type: .checking, currency: "MXN", nickname: "Checking")
            context.insert(acct)
            let tx = Transaction(account: acct, postedAt: monthStart, amount: -1_000, descriptionRaw: "Dinner")
            tx.setHouseholdScope(.included)
            tx.setExpenseAssignment(.partner)
            context.insert(tx)
            try context.save()
            savedTxID = tx.id
        }

        // Reopen with the live schema (V6) via the staged migration plan.
        let config = ModelConfiguration(schema: AppSchema.schema, url: storeURL)
        let migrated = try ModelContainer(
            for: AppSchema.schema,
            migrationPlan: FinanceTrackerMigrationPlan.self,
            configurations: [config]
        )
        let context = migrated.mainContext
        let tx = try #require(try context.fetch(FetchDescriptor<Transaction>()).first)
        #expect(tx.id == savedTxID)
        #expect(tx.expenseAssignment == .partner)

        // The new sidecar model is queryable post-migration.
        #expect((try? context.fetchCount(FetchDescriptor<SettlementDueDateOverride>())) == 0)

        // Write an override, then verify a context-aware report resolves it.
        let due = YearMonth(date: monthStart).addingMonths(1).startDate
        try SettlementDueDateService.setDueDate(due, for: tx.id, context: context)

        let input = HouseholdSettlementReportService.reportInput(for: monthStart, context: context)
        #expect(input.dueDates[tx.id] != nil)

        let julyReport = HouseholdSettlementReportService.build(
            monthStart: monthStart,
            transactions: input.transactions,
            dueDates: input.dueDates,
            setup: HouseholdSettlementSetup(partnerIncomeEstimate: 0)
        )
        #expect(julyReport.deferredFerRows.count == 1)
        #expect(julyReport.amountToRecoverFromPartner == 0)

        try SettlementDueDateService.clear(for: tx.id, context: context)
        #expect(SettlementDueDateService.activeDueDates(for: [tx.id], context: context).isEmpty)
    }

    @Test("A due-date override pulls an older Fer tx into the due month via reportInput")
    func reportInputPullsOlderFerTxIntoDueMonth() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let july = YearMonth(year: 2026, month: 7)
        let august = YearMonth(year: 2026, month: 8)
        let acct = Account(institution: "Bank", type: .checking, currency: "MXN", nickname: "2now")
        context.insert(acct)
        let food = FinanceTracker.Category(name: "Clothing", kind: .expense)
        let tx = Transaction(account: acct, postedAt: july.startDate.addingTimeInterval(12 * 86_400), amount: -1_000, descriptionRaw: "Shein", category: food)
        tx.setHouseholdScope(.included)
        tx.setExpenseAssignment(.partner)
        context.insert(tx)
        try context.save()

        // Due date lands in August.
        let augDue = august.startDate.addingTimeInterval(10 * 86_400)
        try SettlementDueDateService.setDueDate(augDue, for: tx.id, context: context)

        // July report: the tx is posted here, deferred to August (not summed).
        let julyInput = HouseholdSettlementReportService.reportInput(for: july.startDate, context: context)
        let julyReport = HouseholdSettlementReportService.build(monthStart: july.startDate, transactions: julyInput.transactions, dueDates: julyInput.dueDates, setup: HouseholdSettlementSetup(partnerIncomeEstimate: 0))
        #expect(julyReport.deferredFerRows.count == 1)
        #expect(julyReport.ferRows.isEmpty)

        // August report: the older Fer tx must be pulled in by its due date and summed.
        let augInput = HouseholdSettlementReportService.reportInput(for: august.startDate, context: context)
        #expect(augInput.transactions.contains { $0.id == tx.id }, "August input should include the July tx via its due date")
        #expect(augInput.dueDates[tx.id] != nil)
        let augReport = HouseholdSettlementReportService.build(monthStart: august.startDate, transactions: augInput.transactions, dueDates: augInput.dueDates, setup: HouseholdSettlementSetup(partnerIncomeEstimate: 0))
        #expect(augReport.ferRows.count == 1)
        #expect(augReport.amountToRecoverFromPartner == 1_000)
    }

    @Test("setDueDate clamps an earlier date up to the purchase day")
    func setDueDateClampsEarlierDateToPurchaseDay() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let july = YearMonth(year: 2026, month: 7)
        let food = FinanceTracker.Category(name: "Dinner", kind: .expense)
        let tx = Transaction(account: account(), postedAt: july.startDate.addingTimeInterval(15 * 86_400), amount: -500, descriptionRaw: "Dinner", category: food)
        tx.setHouseholdScope(.included)
        tx.setExpenseAssignment(.partner)
        context.insert(tx)
        try context.save()

        // An impossible earlier date (June) must be clamped to the July purchase day,
        // not stored as-is and surface the tx in the wrong month.
        let june = YearMonth(year: 2026, month: 6).startDate.addingTimeInterval(5 * 86_400)
        try SettlementDueDateService.setDueDate(june, for: tx.id, context: context)

        let active = SettlementDueDateService.activeDueDates(for: [tx.id], context: context)
        let resolved = try #require(active[tx.id])
        #expect(YearMonth(date: resolved) == july, "Earlier due date must clamp to the purchase month")
    }

    @Test("activeDueDates resolves deterministically when duplicate rows share a timestamp")
    func activeDueDatesBreaksTiesDeterministically() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let tx = Transaction(account: account(), postedAt: monthStart, amount: -100, descriptionRaw: "X", category: category("Food", kind: .expense))
        tx.setHouseholdScope(.included)
        tx.setExpenseAssignment(.partner)
        context.insert(tx)
        try context.save()

        // Manually seed two rows for the same tx: an active date and a tombstone,
        // both with identical lastModifiedAt. The active date must win (or neither
        // should nondeterministically hide it) — the fetch is sorted so the result is
        // stable across runs.
        let sameTimestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let active = SettlementDueDateOverride(transactionID: tx.id, dueDate: YearMonth(date: monthStart).addingMonths(1).startDate)
        active.lastModifiedAt = sameTimestamp
        let tombstone = SettlementDueDateOverride(transactionID: tx.id, dueDate: nil)
        tombstone.lastModifiedAt = sameTimestamp
        context.insert(active)
        context.insert(tombstone)
        try context.save()

        // Run many times — if the tie-break were nondeterministic this would flake.
        for _ in 0..<50 {
            let resolved = SettlementDueDateService.activeDueDates(for: [tx.id], context: context)
            #expect(resolved[tx.id] != nil, "Identical-timestamp rows must resolve deterministically (active present)")
        }
    }

    // MARK: - Property workspace over SwiftData (moved from the former
    // PropertyWorkspaceTests and PropertyMonthlyRefactorTests suites). These
    // reuse this suite's makeContainer(); pure ledger tests live in
    // PropertyManagementTests.

    private enum SimulatedFailure: Error { case save }
    private var november2026: Date { YearMonth(year: 2026, month: 11).startDate }
    private var march2026: Date { YearMonth(year: 2026, month: 3).startDate }
    private func workspaceLedgerURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("property-workspace-\(UUID()).json")
    }

    @Test("Switching homes, sections, and income assumptions reuses one period fetch")
    func periodCache() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(institution: "Banco de prueba", type: .checking)
        context.insert(account)
        let tx = Transaction(account: account, postedAt: november2026, amount: -500, descriptionRaw: "Gasto compartido")
        tx.setHouseholdScope(.included)
        tx.setExpenseAssignment(.shared)
        context.insert(tx)
        try context.save()
        let workspace = PropertyWorkspaceModel(month: november2026, asOf: .distantFuture)
        workspace.configure(context: context, hasAccounts: true)
        await workspace.refreshPeriod()
        #expect(workspace.transactionFetchCount == 1)
        #expect(workspace.householdReport?.totalSharedExpenses == 500)
        workspace.destination = .household
        workspace.section = .configuration
        workspace.updateHouseholdSetup(HouseholdSettlementSetup(partnerIncomeEstimate: 1_000,
            useUserIncomeManualOverride: true, userIncomeManualOverride: 1_000))
        await workspace.refreshPeriod()
        workspace.destination = .allHomes
        await workspace.refreshPeriod()
        #expect(workspace.transactionFetchCount == 1)
        #expect(workspace.householdReport?.amountToRecoverFromPartner == 250)
        workspace.shiftMonth(1)
        await workspace.refreshPeriod()
        #expect(workspace.transactionFetchCount == 2)
        #expect(workspace.householdReport?.totalSharedExpenses == 0)
    }

    @Test("The unified query retains historical Fer due dates and linked property sources")
    func historicalSourcesAndDueDates() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(institution: "Banco de prueba", type: .checking)
        context.insert(account)
        let oldMonth = YearMonth(year: 2026, month: 10).startDate
        let tx = Transaction(account: account, postedAt: oldMonth, amount: -600, descriptionRaw: "Compra anterior")
        tx.setHouseholdScope(.included)
        tx.setExpenseAssignment(.partner)
        context.insert(tx)
        context.insert(SettlementDueDateOverride(transactionID: tx.id, dueDate: november2026))
        let propertyTx = Transaction(account: account, postedAt: oldMonth, amount: -800, descriptionRaw: "Reparación anterior")
        context.insert(propertyTx)
        try context.save()
        let property = PropertyRecord(name: "Casa norte")
        var ledger = PropertyLedger()
        ledger.properties = [property]
        ledger.attributions = [.init(propertyID: property.id, transactionID: propertyTx.id,
            kind: .maintenance, responsibility: .owner)]
        ledger.attributions.append(.init(propertyID: property.id, transactionID: UUID(),
            kind: .maintenance, responsibility: .owner))
        let workspace = PropertyWorkspaceModel(month: november2026, asOf: .distantFuture)
        workspace.applyLedger(ledger)
        workspace.configure(context: context, hasAccounts: true)
        await workspace.refreshPeriod()
        #expect(workspace.transactionFetchCount == 1)
        #expect(workspace.transactionInputs.contains { $0.id == propertyTx.id })
        #expect(workspace.householdReport?.amountToRecoverFromPartner == 600)
        #expect(workspace.householdReport?.totalPaidByUser == 0)
        let presentation = try #require(workspace.householdReport.map(PropertyPresentationAdapter.household))
        #expect(presentation.metrics.first?.amount == 0)
        #expect(presentation.people.last?.amount == 600)
        workspace.applyLedger(ledger)
        await workspace.refreshPeriod()
        #expect(workspace.transactionFetchCount == 1, "Known missing sources must not invalidate an unchanged input set")
    }

    @Test("No-account startup never materializes transaction rows")
    func emptyAccounts() async throws {
        let container = try makeContainer()
        let workspace = PropertyWorkspaceModel(month: november2026, asOf: .distantFuture)
        workspace.configure(context: container.mainContext, hasAccounts: false)
        await workspace.refreshPeriod()
        #expect(workspace.transactionFetchCount == 0)
        #expect(workspace.householdReport?.totalPaidByUser == 0)
    }

    @Test("Failed income inserts and updates cannot leak into later shared-context saves")
    func isolatedSetupFailure() throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.autosaveEnabled = false
        let unrelated = Account(institution: "Pendiente sin guardar", type: .checking)
        context.insert(unrelated)
        let original = HouseholdSettlementSetup(partnerIncomeEstimate: 500)
        #expect(throws: SimulatedFailure.self) {
            try HouseholdWorkspacePersistence.save(original, month: november2026, container: container,
                commit: { _ in throw SimulatedFailure.save })
        }
        #expect(try HouseholdWorkspacePersistence.read(month: november2026, container: container).partnerIncomeEstimate == 0)
        #expect(context.hasChanges)
        try HouseholdWorkspacePersistence.save(original, month: november2026, container: container)
        #expect(throws: SimulatedFailure.self) {
            try HouseholdWorkspacePersistence.save(HouseholdSettlementSetup(partnerIncomeEstimate: 900),
                month: november2026, container: container, commit: { _ in throw SimulatedFailure.save })
        }
        try context.save()
        #expect(try HouseholdWorkspacePersistence.read(month: november2026, container: container).partnerIncomeEstimate == 500)
        #expect(try context.fetch(FetchDescriptor<Account>()).contains { $0.id == unrelated.id })
    }

    @Test("Retry invalidates a previously successful period cache")
    func retryRefreshesExternalChanges() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(institution: "Banco de prueba", type: .checking)
        context.insert(account)
        try context.save()
        let workspace = PropertyWorkspaceModel(month: november2026, asOf: .distantFuture, readLedger: { _ in PropertyLedger() })
        workspace.configure(context: context, hasAccounts: true)
        await workspace.refreshPeriod()
        let revision = workspace.inputRevision
        let tx = Transaction(account: account, postedAt: november2026, amount: -700, descriptionRaw: "Nuevo gasto")
        tx.setHouseholdScope(.included)
        tx.setExpenseAssignment(.partner)
        context.insert(tx)
        try context.save()
        await workspace.retry()
        #expect(workspace.transactionFetchCount == 2)
        #expect(workspace.inputRevision > revision)
        #expect(workspace.householdReport?.amountToRecoverFromPartner == 700)
    }

    @Test("Failed period reads never expose a previous report under a new month")
    func failedMonthDoesNotExposePreviousReport() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(institution: "Banco de prueba", type: .checking)
        context.insert(account)
        try context.save()
        let property = PropertyRecord(name: "Casa norte")
        var ledger = PropertyLedger()
        ledger.properties = [property]
        ledger.rents = [.init(propertyID: property.id, monthlyAmount: 3_000, effectiveMonth: november2026)]
        var fail = false
        let workspace = PropertyWorkspaceModel(month: november2026, asOf: .distantFuture, readLedger: { _ in PropertyLedger() },
            fetchTransactions: { context, descriptor in
                if fail { throw SimulatedFailure.save }
                return try context.fetch(descriptor)
            })
        workspace.applyLedger(ledger)
        workspace.configure(context: context, hasAccounts: true)
        await workspace.refreshPeriod()
        #expect(workspace.reports[property.id]?.rent == 3_000)
        fail = true
        workspace.shiftMonth(1)
        await workspace.refreshPeriod()
        #expect(!workspace.periodReady)
        #expect(workspace.reports.isEmpty)
        #expect(workspace.householdReport == nil)
        #expect(workspace.error != nil)
        workspace.configure(context: context, hasAccounts: false)
        await workspace.refreshPeriod(force: true)
        #expect(workspace.periodReady)
        #expect(workspace.error == nil)
    }

    @Test("No-account refresh preserves persisted assumptions and abandoning an invalid draft restores them")
    func persistedSetupWithoutAccounts() async throws {
        let container = try makeContainer()
        let saved = HouseholdSettlementSetup(partnerIncomeEstimate: 850, splitMethod: .customPercent,
            customUserPercent: 50, customPartnerPercent: 50)
        try HouseholdWorkspacePersistence.save(saved, month: november2026, container: container)
        let workspace = PropertyWorkspaceModel(month: november2026, asOf: .distantFuture)
        workspace.configure(context: container.mainContext, hasAccounts: false)
        await workspace.refreshPeriod()
        #expect(workspace.householdSetup == saved)
        #expect(workspace.transactionFetchCount == 0)
        workspace.updateHouseholdSetup(HouseholdSettlementSetup(partnerIncomeEstimate: 850,
            splitMethod: .customPercent, customUserPercent: 60, customPartnerPercent: 50))
        workspace.discardHouseholdDraft()
        #expect(workspace.householdSetup == saved)
        #expect(workspace.persistedHouseholdSetup == saved)
    }

    @Test("Overlapping month changes publish only the last requested period")
    func overlappingMonthChanges() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(institution: "Banco de prueba", type: .checking)
        context.insert(account)
        for index in 0..<200 {
            context.insert(Transaction(account: account, postedAt: november2026, amount: -10,
                descriptionRaw: "Gasto \(index)"))
        }
        try context.save()
        let workspace = PropertyWorkspaceModel(month: november2026, asOf: .distantFuture)
        workspace.configure(context: context, hasAccounts: true)
        let first = Task { await workspace.refreshPeriod() }
        await Task.yield()
        workspace.shiftMonth(1)
        await workspace.refreshPeriod()
        await first.value
        #expect(workspace.periodReady)
        #expect(workspace.householdReport?.monthStart == YearMonth(year: 2026, month: 12).startDate)
        #expect(workspace.transactionInputs.isEmpty)
    }

    @Test("Representative workspace loads 1,000 expenses and draws its shared summary")
    func representativeWorkspacePerformance() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(institution: "Banco de prueba", type: .checking)
        context.insert(account)
        let property = PropertyRecord(name: "Casa norte")
        var ledger = PropertyLedger()
        ledger.properties = [property]
        for index in 0..<3 {
            let resident = PropertyResident(propertyID: property.id, name: "Residente \(index + 1)",
                activeFrom: november2026, referenceMonthlyIncome: 1_000)
            ledger.residents.append(resident)
            ledger.incomes.append(PropertyIncome(propertyID: property.id, residentID: resident.id,
                monthStart: november2026, amount: 1_000, confirmedAt: november2026))
        }
        for index in 0..<1_000 {
            let tx = Transaction(account: account, postedAt: november2026, amount: -10,
                descriptionRaw: "Gasto de prueba \(index)")
            context.insert(tx)
            ledger.attributions.append(PropertyTransactionAttribution(propertyID: property.id,
                transactionID: tx.id, kind: .operation, responsibility: .shared))
        }
        try context.save()
        let workspace = PropertyWorkspaceModel(month: november2026, asOf: .distantFuture)
        workspace.applyLedger(ledger)
        workspace.configure(context: context, hasAccounts: true)
        let start = ContinuousClock.now
        await workspace.refreshPeriod()
        let loaded = ContinuousClock.now
        let report = try #require(workspace.reports[property.id])
        #expect(report.expenses == 10_000)
        let view = NSHostingView(rootView: PropertySummaryPanel(
            presentation: PropertyPresentationAdapter.property(report), onOpenSettlement: {}))
        view.frame = NSRect(x: 0, y: 0, width: 780, height: 700)
        view.layoutSubtreeIfNeeded()
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
        }
        let drawn = ContinuousClock.now
        workspace.destination = .property(property.id)
        workspace.section = .configuration
        workspace.section = .month
        await workspace.refreshPeriod()
        #expect(workspace.transactionFetchCount == 1)
        print("PROPERTY_WORKSPACE_PERF: 1000 expenses; query/reports \(start.duration(to: loaded)); first offscreen summary layout/draw \(loaded.duration(to: drawn))")
    }

    @Test("Confirmed zero survives reopen; edits invalidate confirmation without writing legacy setup")
    func householdConfirmationAuthority() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        try HouseholdWorkspacePersistence.save(HouseholdSettlementSetup(partnerIncomeEstimate: 900), month: march2026, container: container)
        let url = workspaceLedgerURL(); defer { try? FileManager.default.removeItem(at: url) }
        let workspace = PropertyWorkspaceModel(month: march2026, fileURL: url)
        workspace.configure(context: context, hasAccounts: false)
        await workspace.loadLedger(); await workspace.refreshPeriod()
        workspace.destination = .household
        let member = PropertyHouseholdAdapter.link.partnerID
        #expect(workspace.saveMonthlyIncome(residentID: member, amount: 0, confirmed: true, month: march2026))
        #expect(workspace.householdMonth(march2026)?.partnerConfirmedAt != nil)
        #expect(workspace.householdSetup.partnerIncomeEstimate == 0)
        #expect(try HouseholdWorkspacePersistence.read(month: march2026, container: container).partnerIncomeEstimate == 900)
        #expect(workspace.saveMonthlyIncome(residentID: member, amount: 1250, confirmed: false, month: march2026))
        #expect(workspace.householdMonth(march2026)?.partnerConfirmedAt == nil)
        #expect(workspace.saveMonthlyIncome(residentID: member, amount: 1250, confirmed: true, month: march2026))
        let reopened = PropertyWorkspaceModel(month: march2026, fileURL: url)
        reopened.configure(context: context, hasAccounts: false)
        await reopened.loadLedger(); await reopened.refreshPeriod()
        #expect(reopened.householdSetup.partnerIncomeEstimate == 1250)
        #expect(reopened.householdMonth(march2026)?.partnerConfirmedAt != nil)
        #expect(reopened.properties.isEmpty) // household remains one sidebar entry
    }

    @Test("Household adapter retains exact split and recognizes direct user expenses once")
    func householdReconciliation() async throws {
        let container = try makeContainer(); let context = container.mainContext
        let account = Account(institution: "Pruebas", type: .checking); context.insert(account)
        let expense = Transaction(account: account, postedAt: march2026, amount: -1000, descriptionRaw: "Gasto compartido")
        expense.setHouseholdScope(.included); expense.setExpenseAssignment(.shared); context.insert(expense)
        try context.save()
        let url = workspaceLedgerURL(); defer { try? FileManager.default.removeItem(at: url) }
        let workspace = PropertyWorkspaceModel(month: march2026, fileURL: url)
        workspace.configure(context: context, hasAccounts: true)
        await workspace.loadLedger(); await workspace.refreshPeriod(); workspace.destination = .household
        let link = PropertyHouseholdAdapter.link
        #expect(workspace.saveMonthlyIncome(residentID: link.userID, amount: 1000, confirmed: true, month: march2026))
        #expect(workspace.saveMonthlyIncome(residentID: link.partnerID, amount: 1000, confirmed: true, month: march2026))
        let original = try #require(workspace.householdReport)
        let report = try #require(workspace.householdMonthlyReport)
        #expect(original.amountToRecoverFromPartner == 500)
        #expect(report.residents.first { $0.id == link.userID }?.balance == 0)
        #expect(report.residents.first { $0.id == link.partnerID }?.balance == original.amountToRecoverFromPartner)
        #expect(report.canClose)
        #expect(report.expenses == original.totalPaidByUser)
        #expect(workspace.transactionFetchCount == 1)
    }
}
