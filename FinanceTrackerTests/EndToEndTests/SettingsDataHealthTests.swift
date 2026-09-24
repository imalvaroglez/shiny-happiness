import Foundation
import SwiftData
import Testing
@testable import FinanceTracker

@Suite("Settings data health")
struct SettingsDataHealthTests {
    private let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
    private let newDate = Date(timeIntervalSince1970: 1_700_086_400)

    @Test("Excludes deleted and duplicate transactions from history and activity")
    func activeTransactionHistory() {
        let summary = DataHealthSummary(
            accounts: [DataHealthAccountInput(closedAt: nil, currency: "MXN")],
            transactions: [
                DataHealthTransactionInput(postedAt: oldDate, deletedAt: nil, isDuplicate: false, currency: "MXN"),
                DataHealthTransactionInput(postedAt: newDate, deletedAt: nil, isDuplicate: false, currency: "USD"),
                DataHealthTransactionInput(postedAt: newDate, deletedAt: Date(), isDuplicate: false, currency: "USD"),
                DataHealthTransactionInput(postedAt: newDate, deletedAt: nil, isDuplicate: true, currency: "EUR"),
            ],
            pendingImports: [],
            activeCategoryCount: 3,
            importedStatementCount: 2
        )

        #expect(summary.historyStart == oldDate)
        #expect(summary.historyEnd == newDate)
        #expect(summary.lastActivity == newDate)
        #expect(summary.currenciesInUse == ["MXN", "USD"])
    }

    @Test("Counts only open accounts and unresolved pending imports")
    func accountAndPendingHealth() {
        let summary = DataHealthSummary(
            accounts: [
                DataHealthAccountInput(closedAt: nil, currency: "MXN"),
                DataHealthAccountInput(closedAt: Date(), currency: "USD"),
            ],
            transactions: [],
            pendingImports: [
                DataHealthPendingInput(isResolved: false),
                DataHealthPendingInput(isResolved: true),
                DataHealthPendingInput(isResolved: false),
            ],
            activeCategoryCount: 8,
            importedStatementCount: 4
        )

        #expect(summary.activeAccountCount == 1)
        #expect(summary.unresolvedPendingCount == 2)
        #expect(summary.activeCategoryCount == 8)
        #expect(summary.importedStatementCount == 4)
        #expect(summary.currenciesInUse == ["MXN"])
    }

    @Test("Empty store has explicit empty health state")
    func emptyStore() {
        let summary = DataHealthSummary(
            accounts: [],
            transactions: [],
            pendingImports: [],
            activeCategoryCount: 0,
            importedStatementCount: 0
        )

        #expect(summary.activeAccountCount == 0)
        #expect(summary.historyStart == nil)
        #expect(summary.historyEnd == nil)
        #expect(summary.lastActivity == nil)
        #expect(summary.unresolvedPendingCount == 0)
        #expect(summary.currenciesInUse.isEmpty)
        #expect(!summary.hasTransactionHistory)
    }
}

@Suite("Settings account state")
@MainActor
struct SettingsAccountStateTests {
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(schema: AppSchema.schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: AppSchema.schema, configurations: [config])
    }

    @Test("Loads transaction counts per account and portfolio availability")
    func accountState() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let checking = Account(institution: "Bank", type: .checking)
        let investment = Account(institution: "Broker", type: .investment)
        context.insert(checking)
        context.insert(investment)
        context.insert(Transaction(account: checking, postedAt: .now, amount: 100, descriptionRaw: "Deposit"))
        try context.save()

        let states = SettingsAccountStateLoader.load(accounts: [checking, investment], context: context)

        #expect(states[checking.id]?.transactionCount == 1)
        #expect(states[investment.id]?.transactionCount == 0)
        #expect(states[investment.id]?.canAddPositions == true)

        context.insert(Transaction(account: investment, postedAt: .now, amount: 20, descriptionRaw: "Purchase"))
        try context.save()
        let updatedStates = SettingsAccountStateLoader.load(accounts: [checking, investment], context: context)

        #expect(updatedStates[investment.id]?.transactionCount == 1)
        #expect(updatedStates[investment.id]?.canAddPositions == false)
    }

    @Test("Account summaries update when an unchanged transaction moves accounts")
    func accountSummaryTracksReassignmentWithoutTotalCountChange() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let checking = Account(institution: "Bank", type: .checking)
        let investment = Account(institution: "Broker", type: .investment)
        let transaction = Transaction(account: checking, postedAt: .now, amount: -100,
                                      descriptionRaw: "Purchase")
        context.insert(checking)
        context.insert(investment)
        context.insert(transaction)
        try context.save()

        let before = SettingsAccountStateLoader.load(accounts: [checking, investment], context: context)
        let totalBefore = try context.fetchCount(FetchDescriptor<Transaction>())

        transaction.account = investment
        try context.save()

        let after = SettingsAccountStateLoader.load(accounts: [checking, investment], context: context)
        let totalAfter = try context.fetchCount(FetchDescriptor<Transaction>())
        #expect(totalBefore == totalAfter)
        #expect(before[checking.id]?.transactionCount == 1)
        #expect(after[checking.id]?.transactionCount == 0)
        #expect(after[investment.id]?.transactionCount == 1)
    }

    @Test("Empty account list does not load account state")
    func emptyAccountState() throws {
        let container = try makeContainer()
        let states = SettingsAccountStateLoader.load(accounts: [], context: container.mainContext)

        #expect(states.isEmpty)
    }

    @Test("Data health loads from an isolated model actor")
    func backgroundDataHealthLoad() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(institution: "Bank", type: .checking, currency: "MXN")
        context.insert(account)
        context.insert(Transaction(account: account, postedAt: .now, amount: -25, descriptionRaw: "Groceries"))
        try context.save()

        let loader = DataHealthSnapshotLoader(modelContainer: container)
        let summary = try await loader.load(activeCategoryCount: 12)

        #expect(summary.activeAccountCount == 1)
        #expect(summary.hasTransactionHistory)
        #expect(summary.activeCategoryCount == 12)
        #expect(summary.importedStatementCount == 0)
    }
}

#if os(macOS)
@Suite("Backup status presentation")
struct BackupStatusPresentationTests {
    @Test("Exposes the complete verified bundle path and managed folder")
    func verifiedBackupPath() {
        let directory = URL(fileURLWithPath: "/tmp/FinanceTracker/Backups")
        let bundle = directory.appendingPathComponent("FinanceTracker-2026-08-10T11-47-00.ftbackup")
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let presentation = BackupStatusPresentation(
            latestBackup: BackupSummary(url: bundle, createdAt: createdAt, schemaVersion: 7),
            managedDirectory: directory
        )

        #expect(presentation.latestPath == bundle.path)
        #expect(presentation.latestPath != bundle.lastPathComponent)
        #expect(presentation.managedDirectoryPath == directory.path)
        #expect(presentation.createdAt == createdAt)
        #expect(presentation.hasVerifiedSnapshot)
    }

    @Test("Distinguishes an unavailable verified snapshot")
    func noVerifiedBackup() {
        let directory = URL(fileURLWithPath: "/tmp/FinanceTracker/Backups")
        let presentation = BackupStatusPresentation(latestBackup: nil, managedDirectory: directory)

        #expect(presentation.latestPath == nil)
        #expect(presentation.createdAt == nil)
        #expect(!presentation.hasVerifiedSnapshot)
        #expect(presentation.managedDirectoryPath == directory.path)
    }
}
#endif
