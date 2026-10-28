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

    @Test("Archived accounts do not count as operational accounts")
    func archivedAccountsAreNotActive() {
        let summary = DataHealthSummary(
            accounts: [
                DataHealthAccountInput(closedAt: nil, currency: "MXN"),
                DataHealthAccountInput(closedAt: nil, currency: "USD", archivedAt: newDate),
                DataHealthAccountInput(closedAt: oldDate, currency: "EUR", archivedAt: nil),
            ],
            transactions: [],
            pendingImports: [],
            activeCategoryCount: 0,
            importedStatementCount: 0
        )

        #expect(summary.activeAccountCount == 1)
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

    @Test("Account edits are isolated until save and a failed write leaves the account intact")
    func accountConfigurationDraft() throws {
        enum Failure: Error { case simulated }
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(institution: "Banco sintético", type: .creditCard, nickname: "Original", creditLimit: 500)
        context.insert(account)
        try context.save()
        let revision = account.lastModifiedAt
        let draft = AccountConfigurationEditor.makeDraft(from: account)
        draft.nickname = "Nuevo"
        draft.creditLimit = 800
        #expect(account.nickname == "Original")
        do {
            try AccountConfigurationEditor.save(draft: draft, accountID: account.id, expectedRevision: revision,
                container: container, commit: { _ in throw Failure.simulated })
            Issue.record("The simulated save should fail")
        } catch Failure.simulated {} catch { Issue.record("Unexpected error: \(error)") }
        let reader = ModelContext(container)
        let original = try #require(reader.fetch(FetchDescriptor<Account>()).first)
        #expect(original.nickname == "Original")
        #expect(original.creditLimit == 500)
        let savedSnapshot = try AccountConfigurationEditor.save(draft: draft, accountID: account.id,
            expectedRevision: revision, container: container)
        let verifiedContext = ModelContext(container)
        let verified = try #require(verifiedContext.fetch(FetchDescriptor<Account>()).first)
        #expect(verified.nickname == "Nuevo")
        #expect(verified.creditLimit == 800)
        #expect(verified.currency == "MXN")
        #expect(savedSnapshot.nickname == "Nuevo")
        #expect(savedSnapshot.lastModifiedAt != revision)
        let nextDraft = AccountConfigurationEditor.makeDraft(from: savedSnapshot)
        nextDraft.nickname = "Segunda edición"
        let secondSnapshot = try AccountConfigurationEditor.save(draft: nextDraft, accountID: account.id,
            expectedRevision: savedSnapshot.lastModifiedAt, container: container)
        #expect(secondSnapshot.nickname == "Segunda edición")
        do {
            try AccountConfigurationEditor.save(draft: draft, accountID: account.id,
                expectedRevision: revision, container: container)
            Issue.record("The stale editor should be rejected")
        } catch AccountConfigurationEditor.SaveError.changed {} catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test("Account configuration reopens from an isolated on-disk store")
    func accountConfigurationReopensOnDisk() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("account-config-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.store")
        let accountID: UUID
        do {
            let config = ModelConfiguration(schema: AppSchema.schema, url: url)
            let container = try ModelContainer(for: AppSchema.schema, configurations: [config])
            let context = container.mainContext
            let account = Account(institution: "Banco sintético", type: .creditCard, nickname: "Original", accountNumber: "1234", creditLimit: 500)
            context.insert(account)
            try context.save()
            accountID = account.id
            let draft = AccountConfigurationEditor.makeDraft(from: account)
            draft.nickname = "Editada"
            draft.creditLimit = 800
            try AccountConfigurationEditor.save(draft: draft, accountID: accountID,
                expectedRevision: account.lastModifiedAt, container: container)
        }
        do {
            let config = ModelConfiguration(schema: AppSchema.schema, url: url)
            let container = try ModelContainer(for: AppSchema.schema, configurations: [config])
            let accounts = try container.mainContext.fetch(FetchDescriptor<Account>())
            let restored = try #require(accounts.first { $0.id == accountID })
            #expect(restored.nickname == "Editada")
            #expect(restored.creditLimit == 800)
            #expect(restored.accountNumber == "1234")
            #expect(restored.type == .creditCard)
        }
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
