import Testing
import Foundation
import SwiftData
@testable import FinanceTracker

@Suite("App Data Reset Service")
@MainActor
struct AppDataResetServiceTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = AppSchema.schema
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    private func seedFullDataset(context: ModelContext) throws {
        let account = Account(institution: "Test Bank", type: .creditCard, currency: "MXN", nickname: "Card")
        context.insert(account)

        let snapshot = AccountBalanceSnapshot(account: account, date: .now, amount: 5000, kind: .manualOpening)
        context.insert(snapshot)

        let statement = Statement(
            account: account,
            periodStart: .now,
            periodEnd: .now,
            sourceFileHash: "test",
            closingBalance: -3000
        )
        context.insert(statement)

        let tx = Transaction(postedAt: .now, amount: -100, descriptionRaw: "STORE")
        tx.account = account
        tx.statement = statement
        context.insert(tx)

        let plan = InstallmentPlan(
            account: account,
            originalPurchase: tx,
            originalAmount: 1200,
            totalMonths: 12,
            currentMonth: 1,
            monthlyAmount: 100,
            firstChargeDate: .now,
            merchantDescription: "STORE MSI"
        )
        context.insert(plan)

        let pending = PendingImport(
            account: account,
            statement: statement,
            rawText: "BAD LINE",
            reason: "No amount"
        )
        context.insert(pending)

        let hint = SignRecoveryHint(
            pattern: "ABONO",
            implicitSign: 1,
            source: "user_correction"
        )
        context.insert(hint)

        let investmentAccount = Account(institution: "Broker", type: .investment, currency: "MXN", nickname: "Broker")
        context.insert(investmentAccount)
        _ = try PortfolioService.addPosition(
            account: investmentAccount,
            emisoraSerie: "FEMSAUBD",
            name: nil,
            shares: 1,
            averageCost: 100,
            context: context
        )

        try context.save()
    }

    @Test("deletePersistentModels removes all model types")
    func testDeletePersistentModels() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        SeedDataLoader.bootstrapIfNeeded(context: context)
        try seedFullDataset(context: context)

        let userCategory = Category(name: "My Category", kind: .expense)
        context.insert(userCategory)
        let userRule = CategoryRule(patternRegex: "MINE", merchantMatch: "My Store", category: userCategory, priority: 100, source: "user_correction")
        context.insert(userRule)
        try context.save()

        try AppDataResetService.deletePersistentModels(from: context)
        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<Account>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<AccountBalanceSnapshot>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<StockPosition>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Transaction>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Statement>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<InstallmentPlan>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<PendingImport>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<SignRecoveryHint>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<FinanceTracker.Category>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<CategoryRule>()) == 0)
    }

    @Test("resetAllData restores seed categories and rules")
    func testResetAllDataRestoresSeeds() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        SeedDataLoader.bootstrapIfNeeded(context: context)
        try seedFullDataset(context: context)

        try AppDataResetService.resetAllData(context: context)

        #expect(try context.fetchCount(FetchDescriptor<Account>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<AccountBalanceSnapshot>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<StockPosition>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Transaction>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Statement>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<InstallmentPlan>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<PendingImport>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<SignRecoveryHint>()) == 0)

        let categories = try context.fetch(FetchDescriptor<FinanceTracker.Category>())
        #expect(categories.count == 79)

        let rules = try context.fetch(FetchDescriptor<CategoryRule>())
        #expect(rules.count == 43)
    }

    @Test("resetAllData is idempotent")
    func testResetIdempotent() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        SeedDataLoader.bootstrapIfNeeded(context: context)
        try seedFullDataset(context: context)

        try AppDataResetService.resetAllData(context: context)
        let categoriesAfterFirst = try context.fetchCount(FetchDescriptor<FinanceTracker.Category>())
        let rulesAfterFirst = try context.fetchCount(FetchDescriptor<CategoryRule>())

        try AppDataResetService.resetAllData(context: context)
        let categoriesAfterSecond = try context.fetchCount(FetchDescriptor<FinanceTracker.Category>())
        let rulesAfterSecond = try context.fetchCount(FetchDescriptor<CategoryRule>())

        #expect(categoriesAfterFirst == categoriesAfterSecond)
        #expect(rulesAfterFirst == rulesAfterSecond)
        #expect(try context.fetchCount(FetchDescriptor<Account>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Transaction>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<StockPosition>()) == 0)
    }

    @Test("Repair removes all financial orphans when accounts are zero")
    func testRepairRemovesOrphansWhenAccountsZero() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let tx = Transaction(postedAt: .now, amount: -100, descriptionRaw: "ORPHAN TX")
        context.insert(tx)

        let plan = InstallmentPlan(
            originalAmount: 1200,
            totalMonths: 12,
            currentMonth: 3,
            monthlyAmount: 100,
            firstChargeDate: .now,
            merchantDescription: "ORPHAN MSI"
        )
        context.insert(plan)

        let pending = PendingImport(rawText: "ORPHAN", reason: "Leftover")
        context.insert(pending)

        let hint = SignRecoveryHint(pattern: "ABONO", implicitSign: 1, source: "seed")
        context.insert(hint)

        let snapshot = AccountBalanceSnapshot(date: .now, amount: 5000, kind: .manualOpening)
        context.insert(snapshot)

        let position = StockPosition(emisoraSerie: "FEMSAUBD", shares: 1, averageCost: 100)
        context.insert(position)

        try context.save()

        let outcome = AppDataResetService.repairIncompleteResetIfNeeded(context: context)
        #expect(outcome == .repaired)

        #expect(try context.fetchCount(FetchDescriptor<Transaction>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<InstallmentPlan>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<PendingImport>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<SignRecoveryHint>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<AccountBalanceSnapshot>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<StockPosition>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Account>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Statement>()) == 0)

        let categories = try context.fetch(FetchDescriptor<FinanceTracker.Category>())
        #expect(categories.count == 79)
    }

    @Test("Repair returns noRepairNeeded when no orphans exist")
    func testRepairNoOpWhenClean() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        SeedDataLoader.bootstrapIfNeeded(context: context)

        let outcome = AppDataResetService.repairIncompleteResetIfNeeded(context: context)
        #expect(outcome == .noRepairNeeded)

        let categories = try context.fetchCount(FetchDescriptor<FinanceTracker.Category>())
        #expect(categories == 79)
    }

    @Test("Repair is a no-op when financial data exists")
    func testRepairNoOpWhenDataExists() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let account = Account(institution: "Bank", type: .checking, currency: "MXN", nickname: "Checking")
        context.insert(account)

        let tx = Transaction(postedAt: .now, amount: -50, descriptionRaw: "Coffee")
        tx.account = account
        context.insert(tx)

        let pending = PendingImport(
            account: account,
            rawText: "ORPHAN",
            reason: "Leftover"
        )
        context.insert(pending)
        try context.save()

        let outcome = AppDataResetService.repairIncompleteResetIfNeeded(context: context)
        #expect(outcome == .noRepairNeeded)

        #expect(try context.fetchCount(FetchDescriptor<Account>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<Transaction>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<PendingImport>()) == 1)
    }

    @Test("Repair removes orphan transactions and installment plans with zero accounts")
    func testRepairRemovesOrphanTransactions() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let tx = Transaction(postedAt: .now, amount: -250, descriptionRaw: "GHOST TX")
        context.insert(tx)

        let plan = InstallmentPlan(
            originalAmount: 500,
            totalMonths: 5,
            currentMonth: 2,
            monthlyAmount: 100,
            firstChargeDate: .now,
            merchantDescription: "GHOST PLAN"
        )
        context.insert(plan)

        try context.save()

        let outcome = AppDataResetService.repairIncompleteResetIfNeeded(context: context)
        #expect(outcome == .repaired)

        #expect(try context.fetchCount(FetchDescriptor<Transaction>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<InstallmentPlan>()) == 0)

        let categories = try context.fetch(FetchDescriptor<FinanceTracker.Category>())
        #expect(categories.count == 79)
    }

    @Test("StoreFileResetService creates flag and detects it")
    func testStoreFileResetFlagRoundTrip() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        StoreFileResetService.appSupportOverride = tmp
        StoreFileResetService.skipTestGuard = true
        defer { StoreFileResetService.appSupportOverride = nil; StoreFileResetService.skipTestGuard = false }

        #expect(!StoreFileResetService.isHardResetRequested)

        StoreFileResetService.requestHardReset(reason: "test")
        #expect(StoreFileResetService.isHardResetRequested)

        let flagDir = tmp.appendingPathComponent("FinanceTracker", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: flagDir.path))

        StoreFileResetService.performHardResetIfNeeded()
        #expect(!StoreFileResetService.isHardResetRequested)
    }

    @Test("StoreFileResetService quarantines store files")
    func testStoreFileResetQuarantinesFiles() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let storeFile = tmp.appendingPathComponent("default.store")
        let walFile = tmp.appendingPathComponent("default.store-wal")
        try Data("fake".utf8).write(to: storeFile)
        try Data("wal".utf8).write(to: walFile)

        StoreFileResetService.appSupportOverride = tmp
        StoreFileResetService.skipTestGuard = true
        defer { StoreFileResetService.appSupportOverride = nil; StoreFileResetService.skipTestGuard = false }

        StoreFileResetService.requestHardReset(reason: "test quarantine")
        StoreFileResetService.performHardResetIfNeeded()

        #expect(!FileManager.default.fileExists(atPath: storeFile.path))
        #expect(!FileManager.default.fileExists(atPath: walFile.path))

        let backupDir = tmp.appendingPathComponent("FinanceTracker/ResetBackups")
        let backupContents = try FileManager.default.contentsOfDirectory(
            at: backupDir, includingPropertiesForKeys: nil)
        #expect(backupContents.count == 1)
        let quarantined = backupContents[0]
        #expect(FileManager.default.fileExists(
            atPath: quarantined.appendingPathComponent("default.store").path))
        #expect(FileManager.default.fileExists(
            atPath: quarantined.appendingPathComponent("default.store-wal").path))
    }
}
