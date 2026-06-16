import Testing
import Foundation
import SwiftData
@testable import FinanceTracker

@Suite("Retirement Semantics")
@MainActor
struct RetirementSemanticsTests {
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(schema: AppSchema.schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: AppSchema.schema, configurations: [config])
    }

    private func date(_ year: Int = 2026, _ month: Int = 6, _ day: Int = 1) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.timeZone = TimeZone(identifier: "America/Mexico_City")
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    @Test("Retirement account defaults are deterministic")
    func retirementAccountDefaults() throws {
        let ppr = Account(institution: "PPR", type: .retirement, retirementKindRaw: RetirementKind.ppr.rawValue)
        #expect(ppr.liquidity == .restricted)
        #expect(ppr.effectiveIncludeInNetWorth)
        #expect(!ppr.effectiveIncludeInCashFlow)
        #expect(!ppr.effectiveIncludeInRegularIncome)
        #expect(ppr.taxTrackingEnabled == true)

        let afore = Account(institution: "AFORE", type: .retirement, retirementKindRaw: RetirementKind.afore.rawValue)
        #expect(afore.liquidity == .lockedUntilRetirement)
        #expect(afore.effectiveIncludeInNetWorth)
        #expect(!afore.effectiveIncludeInCashFlow)
        #expect(!afore.effectiveIncludeInRegularIncome)
        #expect(afore.taxTrackingEnabled == false)

        let investment = Account(institution: "Broker", type: .investment)
        #expect(investment.effectiveIncludeInNetWorth)
        #expect(!investment.effectiveIncludeInCashFlow)
        #expect(!investment.effectiveIncludeInRegularIncome)
    }

    @Test("Salary and expense stay regular cash flow")
    func regularSalaryAndExpense() throws {
        let account = Account(institution: "Bank", type: .checking)
        let salary = Transaction(
            account: account,
            postedAt: date(),
            amount: 10_000,
            descriptionRaw: "Payroll",
            movementKindRaw: TransactionMovementKind.income.rawValue,
            treatmentKindRaw: TransactionTreatmentKind.regular.rawValue
        )
        let expense = Transaction(
            account: account,
            postedAt: date(),
            amount: -300,
            descriptionRaw: "Groceries",
            movementKindRaw: TransactionMovementKind.expense.rawValue,
            treatmentKindRaw: TransactionTreatmentKind.regular.rawValue
        )

        let classifier = TransactionClassifier()
        #expect(classifier.classify(transaction: salary).countsAsRegularIncome)
        #expect(classifier.classify(transaction: salary).countsAsOperatingCashFlow)
        #expect(classifier.classify(transaction: expense).countsAsRegularExpense)
        #expect(classifier.classify(transaction: expense).countsAsOperatingCashFlow)
    }

    @Test("Checking to PPR stays transfer and is tax-trackable retirement activity")
    func pprTransferClassification() throws {
        let checking = Account(institution: "Bank", type: .checking)
        let ppr = Account(institution: "PPR", type: .retirement, retirementKindRaw: RetirementKind.ppr.rawValue)
        let tx = Transaction(
            account: checking,
            postedAt: date(),
            amount: -1_000,
            descriptionRaw: "PPR contribution",
            isTransfer: true,
            movementKindRaw: TransactionMovementKind.transfer.rawValue,
            treatmentKindRaw: TransactionTreatmentKind.retirementContributionUserFunded.rawValue
        )

        let classification = TransactionClassifier().classify(transaction: tx, sourceAccount: checking, destinationAccount: ppr)
        #expect(classification.isTransfer)
        #expect(!classification.countsAsRegularIncome)
        #expect(!classification.countsAsRegularExpense)
        #expect(!classification.countsAsOperatingCashFlow)
        #expect(classification.countsAsRetirementContribution)
        #expect(classification.countsAsTaxTrackablePPR)
    }

    @Test("Retirement treatments do not inflate dashboard income or cash flow")
    func retirementActivityExcludedFromDashboardIncome() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let checking = Account(institution: "Bank", type: .checking)
        let afore = Account(institution: "AFORE", type: .retirement, retirementKindRaw: RetirementKind.afore.rawValue)
        context.insert(checking)
        context.insert(afore)

        context.insert(Transaction(
            account: checking,
            postedAt: date(),
            amount: 20_000,
            descriptionRaw: "Payroll",
            movementKindRaw: TransactionMovementKind.income.rawValue,
            treatmentKindRaw: TransactionTreatmentKind.regular.rawValue
        ))
        context.insert(Transaction(
            account: afore,
            postedAt: date(),
            amount: 2_000,
            descriptionRaw: "AFORE statutory contribution",
            movementKindRaw: TransactionMovementKind.adjustment.rawValue,
            treatmentKindRaw: TransactionTreatmentKind.statutoryRetirementContribution.rawValue
        ))
        try context.save()

        let viewModel = DashboardViewModel()
        viewModel.dateRange = DateRange(start: .distantPast, end: .distantFuture)
        viewModel.configure(context: context)

        guard case .consolidated(let snapshot) = viewModel.snapshot else {
            Issue.record("Expected consolidated dashboard")
            return
        }
        #expect(snapshot.totalIncome == 20_000)
        #expect(snapshot.monthlyCashFlow.reduce(Decimal.zero) { $0 + $1.income } == 20_000)
    }

    @Test("Manual balance snapshots are not cash flow")
    func manualBalanceSnapshotsAreNotCashFlow() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(institution: "PPR", type: .retirement, retirementKindRaw: RetirementKind.ppr.rawValue)
        context.insert(account)
        context.insert(AccountBalanceSnapshot(account: account, date: date(), amount: 50_000, kind: .manualOpening))
        try context.save()

        let viewModel = DashboardViewModel()
        viewModel.dateRange = DateRange(start: .distantPast, end: .distantFuture)
        viewModel.configure(context: context)

        guard case .consolidated(let snapshot) = viewModel.snapshot else {
            Issue.record("Expected consolidated dashboard")
            return
        }
        #expect(snapshot.totalIncome == 0)
        #expect(snapshot.totalExpenses == 0)
        #expect(snapshot.monthlyCashFlow.isEmpty)
        #expect(snapshot.netWorth == 50_000)
    }

    @Test("V1 store migrates retirement semantics")
    func v1StoreMigratesRetirementSemantics() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("finance-v1-\(UUID()).store")
        defer { try? FileManager.default.removeItem(at: storeURL) }

        do {
            let v1Schema = Schema(FinanceTrackerSchemaV1.models)
            let config = ModelConfiguration(schema: v1Schema, url: storeURL)
            let container = try ModelContainer(
                for: v1Schema,
                migrationPlan: FinanceTrackerMigrationPlan.self,
                configurations: [config]
            )
            let context = container.mainContext
            let account = FinanceTrackerSchemaV1.Account(
                institution: "AFORE Test",
                type: .retirement,
                nickname: "AFORE"
            )
            context.insert(account)
            context.insert(FinanceTrackerSchemaV1.Transaction(
                account: account,
                postedAt: date(),
                amount: 1_000,
                descriptionRaw: "AFORE contribution",
                flowKindRaw: TransactionFlowKind.income.rawValue
            ))
            try context.save()
        }

        let config = ModelConfiguration(schema: AppSchema.schema, url: storeURL)
        let migrated = try ModelContainer(
            for: AppSchema.schema,
            migrationPlan: FinanceTrackerMigrationPlan.self,
            configurations: [config]
        )
        let account = try #require(try migrated.mainContext.fetch(FetchDescriptor<Account>()).first)
        let transaction = try #require(try migrated.mainContext.fetch(FetchDescriptor<Transaction>()).first)

        #expect(account.retirementKind == .afore)
        #expect(account.liquidity == .lockedUntilRetirement)
        #expect(transaction.movementKind == .income)
        #expect(transaction.treatmentKind == .statutoryRetirementContribution)
        #expect(!TransactionClassifier().classify(transaction: transaction).countsAsRegularIncome)
    }
}
