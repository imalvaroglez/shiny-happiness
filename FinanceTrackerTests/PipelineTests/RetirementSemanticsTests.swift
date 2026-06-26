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

    private func removeStore(at url: URL) {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: url)
        try? fileManager.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
        try? fileManager.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
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

    @Test("Investment and retirement reclassification updates account metadata only")
    func investmentRetirementReclassification() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(
            institution: "Broker",
            type: .investment,
            liquidityRaw: AccountLiquidity.lockedUntilRetirement.rawValue
        )
        let transaction = Transaction(
            account: account,
            postedAt: date(),
            amount: 1_000,
            descriptionRaw: "Existing deposit",
            movementKindRaw: TransactionMovementKind.income.rawValue,
            treatmentKindRaw: TransactionTreatmentKind.regular.rawValue
        )
        context.insert(account)
        context.insert(transaction)
        try context.save()

        account.lastModifiedAt = .distantPast
        account.setInvestmentRetirementClassification(.retirement)

        #expect(account.type == .retirement)
        #expect(account.retirementKind == .other)
        #expect(account.liquidity == .restricted)
        #expect(account.effectiveIncludeInNetWorth)
        #expect(!account.effectiveIncludeInCashFlow)
        #expect(!account.effectiveIncludeInRegularIncome)
        #expect(account.taxTrackingEnabled == false)
        #expect(account.lastModifiedAt > .distantPast)
        #expect(transaction.account?.id == account.id)
        #expect(transaction.amount == 1_000)
        #expect(transaction.treatmentKind == .regular)

        account.liquidity = .lockedUntilRetirement
        account.includeInNetWorth = false
        account.includeInCashFlow = true
        account.includeInRegularIncome = true
        account.taxTrackingEnabled = true
        account.setInvestmentRetirementClassification(.investment)

        #expect(account.type == .investment)
        #expect(account.retirementKind == nil)
        #expect(account.liquidity == .lockedUntilRetirement)
        #expect(!account.effectiveIncludeInNetWorth)
        #expect(account.effectiveIncludeInCashFlow)
        #expect(account.effectiveIncludeInRegularIncome)
        #expect(account.taxTrackingEnabled == false)
        #expect(transaction.account?.id == account.id)
        #expect(transaction.amount == 1_000)
        #expect(transaction.treatmentKind == .regular)

        account.setInvestmentRetirementClassification(.checking)
        #expect(account.type == .investment)
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
        defer { removeStore(at: storeURL) }

        do {
            let v1Schema = Schema(versionedSchema: FinanceTrackerSchemaV1.self)
            let config = ModelConfiguration(schema: v1Schema, url: storeURL)
            let container = try ModelContainer(for: v1Schema, configurations: [config])
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

    @Test("V2 store migrates to V3 and registers stock positions")
    func v2StoreMigratesToV3AndRegistersStockPositions() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("finance-v2-\(UUID()).store")
        defer { removeStore(at: storeURL) }

        do {
            let v2Schema = Schema(versionedSchema: FinanceTrackerSchemaV2.self)
            let config = ModelConfiguration(schema: v2Schema, url: storeURL)
            let container = try ModelContainer(for: v2Schema, configurations: [config])
            let context = container.mainContext
            let account = FinanceTrackerSchemaV2.Account(
                institution: "PPR Test",
                type: .retirement,
                nickname: "PPR"
            )
            context.insert(account)
            context.insert(FinanceTrackerSchemaV2.Transaction(
                account: account,
                postedAt: date(),
                amount: 1_000,
                descriptionRaw: "PPR contribution",
                flowKindRaw: TransactionFlowKind.income.rawValue
            ))
            try context.save()
        }

        do {
            let config = ModelConfiguration(schema: AppSchema.schema, url: storeURL)
            let migrated = try ModelContainer(
                for: AppSchema.schema,
                migrationPlan: FinanceTrackerMigrationPlan.self,
                configurations: [config]
            )
            let context = migrated.mainContext
            let account = try #require(try context.fetch(FetchDescriptor<Account>()).first)
            let transaction = try #require(try context.fetch(FetchDescriptor<Transaction>()).first)

            #expect(account.retirementKind == .ppr)
            #expect(account.liquidity == .restricted)
            #expect(transaction.movementKind == .income)
            #expect(transaction.treatmentKind == .retirementContributionUserFunded)
            #expect(try context.fetchCount(FetchDescriptor<StockPosition>()) == 0)

            context.insert(StockPosition(account: account, emisoraSerie: "VOO", shares: 2, averageCost: 500))
            try context.save()
        }

        let config = ModelConfiguration(schema: AppSchema.schema, url: storeURL)
        let reopened = try ModelContainer(
            for: AppSchema.schema,
            migrationPlan: FinanceTrackerMigrationPlan.self,
            configurations: [config]
        )
        let positions = try reopened.mainContext.fetch(FetchDescriptor<StockPosition>())
        #expect(positions.map(\.emisoraSerie) == ["VOO"])
    }
}
