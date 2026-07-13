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

        #expect(result.plainTextSummary.contains("Household Settlement"))
        #expect(result.plainTextSummary.contains("Fer estimate"))
        #expect(result.plainTextSummary.contains("Fer-only expenses paid by you"))
        #expect(result.plainTextSummary.contains("Total to recover from Fer"))
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
}
