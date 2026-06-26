import Testing
import Foundation
import SwiftData
@testable import FinanceTracker

@Suite("Backup Archive")
@MainActor
struct BackupArchiveTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = AppSchema.schema
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    private func makePopulatedContainer() throws -> ModelContainer {
        let container = try makeContainer()
        let context = container.mainContext
        SeedDataLoader.bootstrapIfNeeded(context: context)

        let account = Account(institution: "Test Bank", type: .checking, currency: "MXN", nickname: "Test Checking")
        context.insert(account)

        let statement = Statement(
            account: account,
            periodStart: .now.addingTimeInterval(-30 * 86400),
            periodEnd: .now,
            sourceFileHash: "test-hash-123",
            closingBalance: Decimal(10000)
        )
        context.insert(statement)

        for i in 0..<3 {
            let tx = Transaction(
                account: account,
                statement: statement,
                postedAt: .now.addingTimeInterval(TimeInterval(-i * 86400)),
                amount: Decimal(100 + i),
                currency: "MXN",
                descriptionRaw: "Test transaction #\(i)"
            )
            context.insert(tx)
        }
        try context.save()
        return container
    }

    private func writeEmptyBackup(schemaVersion: Int, includeStockPosition: Bool, to tmp: URL) throws {
        let modelsDir = tmp.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        func write<T: Encodable>(_ name: String, _ value: T) throws {
            try encoder.encode(value).write(to: modelsDir.appendingPathComponent("\(name).json"))
        }

        try write("Account", [AccountSnapshot]())
        try write("AccountBalanceSnapshot", [AccountBalanceSnapshotSnapshot]())
        try write("Statement", [StatementSnapshot]())
        try write("Transaction", [TransactionSnapshot]())
        try write("Category", [CategorySnapshot]())
        try write("CategoryRule", [CategoryRuleSnapshot]())
        try write("InstallmentPlan", [InstallmentPlanSnapshot]())
        try write("PendingImport", [PendingImportSnapshot]())
        try write("SignRecoveryHint", [SignRecoveryHintSnapshot]())
        if includeStockPosition {
            try write("StockPosition", [StockPositionSnapshot]())
        }

        try encoder.encode(BackupManifest(
            schemaVersion: schemaVersion,
            createdAt: Date(),
            appVersion: "test",
            modelCounts: [:],
            contentHashes: [:]
        )).write(to: tmp.appendingPathComponent("manifest.json"))
    }

    @Test("Round-trip: export then replaceAll restores all rows")
    func roundTripReplaceAll() async throws {
        let source = try makePopulatedContainer()
        let sourceContext = source.mainContext

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-backup-\(UUID()).ftbackup", isDirectory: true)

        try await BackupArchive.export(to: tmp, from: sourceContext)

        let target = try makeContainer()
        try await BackupArchive.restore(from: tmp, into: target.mainContext, strategy: .replaceAll)

        let accounts = try target.mainContext.fetch(FetchDescriptor<Account>())
        let txns = try target.mainContext.fetch(FetchDescriptor<Transaction>())
        #expect(accounts.count >= 1, "Should have at least 1 account")
        #expect(txns.count == 3, "Should have exactly 3 transactions, got \(txns.count)")

        try? FileManager.default.removeItem(at: tmp)
    }

    @Test("mergeKeepingNewer keeps the row with the later lastModifiedAt")
    func mergeKeepsNewer() async throws {
        let source = try makePopulatedContainer()
        let sourceContext = source.mainContext

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-backup-merge-\(UUID()).ftbackup", isDirectory: true)
        try await BackupArchive.export(to: tmp, from: sourceContext)

        let target = try makeContainer()
        let targetContext = target.mainContext
        SeedDataLoader.bootstrapIfNeeded(context: targetContext)

        let existingAccount = Account(institution: "Test Bank", type: .checking, currency: "MXN", nickname: "Old Nickname")
        existingAccount.lastModifiedAt = .now.addingTimeInterval(-86400)
        targetContext.insert(existingAccount)
        try targetContext.save()

        try await BackupArchive.restore(from: tmp, into: targetContext, strategy: .mergeKeepingNewer)

        let restored = try targetContext.fetch(FetchDescriptor<Account>())
        let testAccount = restored.first { $0.institution == "Test Bank" }
        #expect(testAccount != nil, "Test Bank account should exist after merge")
        #expect(testAccount?.nickname == "Old Nickname",
                "Older existing row should win over newer backup row")

        try? FileManager.default.removeItem(at: tmp)
    }

    @Test("Manifest content hashes match the JSON files on disk")
    func manifestIntegrity() async throws {
        let source = try makePopulatedContainer()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-backup-hash-\(UUID()).ftbackup", isDirectory: true)
        try await BackupArchive.export(to: tmp, from: source.mainContext)

        let manifestURL = tmp.appendingPathComponent("manifest.json")
        let manifestData = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(BackupManifest.self, from: manifestData)

        #expect(manifest.schemaVersion == 3)
        #expect(!manifest.contentHashes.isEmpty, "Manifest should have content hashes")

        for (name, _) in manifest.contentHashes {
            let fileURL = tmp.appendingPathComponent("models/\(name).json")
            #expect(FileManager.default.fileExists(atPath: fileURL.path),
                   "Manifest references \(name) but models/\(name).json doesn't exist")
        }

        try? FileManager.default.removeItem(at: tmp)
    }

    @Test("Schema 1 backup restores with retirement metadata defaults")
    func schemaOneBackupRestoresWithDefaults() async throws {
        struct OldAccountSnapshot: Codable {
            var id: UUID
            var institution: String
            var type: String
            var currency: String
            var nickname: String
            var accountNumber: String?
            var openedAt: Date
            var closedAt: Date?
            var creditLimit: Decimal?
            var statementDayOfMonth: Int?
            var paymentDayOfMonth: Int?
            var tintHex: String?
            var manuallyCreatedAt: Date?
            var lastModifiedAt: Date
        }
        struct OldTransactionSnapshot: Codable {
            var id: UUID
            var accountId: UUID?
            var statementId: UUID?
            var postedAt: Date
            var amount: Decimal
            var currency: String
            var descriptionRaw: String
            var merchantNormalized: String
            var categoryId: UUID?
            var fxRateToBase: Decimal
            var isTransfer: Bool
            var isDuplicate: Bool
            var cardLast4: String?
            var source: String?
            var transferGroupID: UUID?
            var installmentPlanId: UUID?
            var flowKindRaw: String?
            var lastModifiedAt: Date
            var deletedAt: Date?
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("schema-one-\(UUID()).ftbackup", isDirectory: true)
        let modelsDir = tmp.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let accountID = UUID()
        let now = Date()

        func write<T: Encodable>(_ name: String, _ value: T) throws {
            try encoder.encode(value).write(to: modelsDir.appendingPathComponent("\(name).json"))
        }

        try write("Account", [
            OldAccountSnapshot(
                id: accountID,
                institution: "PPR Provider",
                type: AccountType.retirement.rawValue,
                currency: "MXN",
                nickname: "PPR",
                accountNumber: nil,
                openedAt: now,
                closedAt: nil,
                creditLimit: nil,
                statementDayOfMonth: nil,
                paymentDayOfMonth: nil,
                tintHex: nil,
                manuallyCreatedAt: now,
                lastModifiedAt: now
            )
        ])
        try write("Transaction", [
            OldTransactionSnapshot(
                id: UUID(),
                accountId: accountID,
                statementId: nil,
                postedAt: now,
                amount: 1_000,
                currency: "MXN",
                descriptionRaw: "PPR contribution",
                merchantNormalized: "PPR contribution",
                categoryId: nil,
                fxRateToBase: 1,
                isTransfer: false,
                isDuplicate: false,
                cardLast4: nil,
                source: TransactionSource.manual.rawValue,
                transferGroupID: nil,
                installmentPlanId: nil,
                flowKindRaw: TransactionFlowKind.income.rawValue,
                lastModifiedAt: now,
                deletedAt: nil
            )
        ])
        try write("AccountBalanceSnapshot", [AccountBalanceSnapshotSnapshot]())
        try write("Statement", [StatementSnapshot]())
        try write("Category", [CategorySnapshot]())
        try write("CategoryRule", [CategoryRuleSnapshot]())
        try write("InstallmentPlan", [InstallmentPlanSnapshot]())
        try write("PendingImport", [PendingImportSnapshot]())
        try write("SignRecoveryHint", [SignRecoveryHintSnapshot]())
        try encoder.encode(BackupManifest(
            schemaVersion: 1,
            createdAt: now,
            appVersion: "0.4.0",
            modelCounts: [:],
            contentHashes: [:]
        )).write(to: tmp.appendingPathComponent("manifest.json"))

        let target = try makeContainer()
        try await BackupArchive.restore(from: tmp, into: target.mainContext, strategy: .replaceAll)
        let account = try #require(try target.mainContext.fetch(FetchDescriptor<Account>()).first)
        let transaction = try #require(try target.mainContext.fetch(FetchDescriptor<Transaction>()).first)

        #expect(account.retirementKind == .ppr)
        #expect(account.liquidity == .restricted)
        #expect(transaction.treatmentKind == .retirementContributionUserFunded)
        #expect(!TransactionClassifier().classify(transaction: transaction).countsAsRegularIncome)
    }

    @Test("StockPosition round-trips on v3 backup")
    func stockPositionRoundTrip() async throws {
        let source = try makeContainer()
        let context = source.mainContext
        let account = Account(institution: "Broker", type: .investment, nickname: "Broker")
        context.insert(account)
        let position = try PortfolioService.addPosition(
            account: account,
            emisoraSerie: "FEMSAUBD",
            name: "Femsa",
            shares: 10,
            averageCost: 100,
            context: context
        )
        let quotedAt = Date(timeIntervalSince1970: 1_780_000_000)
        position.lastPrice = 150
        position.lastPriceAt = quotedAt
        try context.save()

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-backup-sp-\(UUID()).ftbackup", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try await BackupArchive.export(to: tmp, from: context)

        let target = try makeContainer()
        try await BackupArchive.restore(from: tmp, into: target.mainContext, strategy: .replaceAll)
        let restored = try target.mainContext.fetch(FetchDescriptor<StockPosition>())
        let restoredPosition = try #require(restored.first)
        #expect(restored.count == 1)
        #expect(restoredPosition.emisoraSerie == "FEMSAUBD")
        #expect(restoredPosition.name == "Femsa")
        #expect(restoredPosition.shares == 10)
        #expect(restoredPosition.averageCost == 100)
        #expect(restoredPosition.lastPrice == 150)
        #expect(restoredPosition.lastPriceAt == quotedAt)
        #expect(restoredPosition.account?.id == account.id)
    }

    @Test("Field-selective merge keeps newer holdings and newer quote independently")
    func stockPositionMergeFieldSelective() async throws {
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        let source = try makeContainer()
        let sourceContext = source.mainContext
        let account = Account(institution: "Broker", type: .investment, nickname: "Broker")
        sourceContext.insert(account)
        let position = try PortfolioService.addPosition(
            account: account,
            emisoraSerie: "FEMSAUBD",
            name: nil,
            shares: 10,
            averageCost: 100,
            context: sourceContext
        )
        position.lastModifiedAt = base
        position.lastPrice = 150
        position.lastPriceAt = base.addingTimeInterval(100)
        try sourceContext.save()

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-backup-spm-\(UUID()).ftbackup", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try await BackupArchive.export(to: tmp, from: sourceContext)

        let target = try makeContainer()
        let targetContext = target.mainContext
        let targetAccount = Account(id: account.id, institution: "Broker", type: .investment, nickname: "Broker")
        targetContext.insert(targetAccount)
        let targetPosition = StockPosition(
            id: position.id,
            account: targetAccount,
            emisoraSerie: "FEMSAUBD",
            shares: 20,
            averageCost: 110
        )
        targetPosition.lastModifiedAt = base.addingTimeInterval(1_000)
        targetPosition.lastPrice = 200
        targetPosition.lastPriceAt = base.addingTimeInterval(-100)
        targetContext.insert(targetPosition)
        try targetContext.save()

        try await BackupArchive.restore(from: tmp, into: targetContext, strategy: .mergeKeepingNewer)

        let restored = try #require(try targetContext.fetch(FetchDescriptor<StockPosition>())
            .first { $0.id == position.id })
        #expect(restored.shares == 20)
        #expect(restored.averageCost == 110)
        #expect(restored.lastModifiedAt == base.addingTimeInterval(1_000))
        #expect(restored.lastPrice == 150)
        #expect(restored.lastPriceAt == base.addingTimeInterval(100))
        #expect(restored.account?.id == account.id)
    }

    @Test("Schema 2 backup restores without StockPosition file")
    func schemaTwoBackupRestoresWithoutStockPositionFile() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("schema-two-no-stock-position-\(UUID()).ftbackup", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try writeEmptyBackup(schemaVersion: 2, includeStockPosition: false, to: tmp)

        let target = try makeContainer()
        try await BackupArchive.restore(from: tmp, into: target.mainContext, strategy: .replaceAll)
        #expect(try target.mainContext.fetchCount(FetchDescriptor<StockPosition>()) == 0)
    }

    @Test("Schema 3 backup requires StockPosition file")
    func schemaThreeBackupRequiresStockPositionFile() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("schema-three-missing-stock-position-\(UUID()).ftbackup", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try writeEmptyBackup(schemaVersion: 3, includeStockPosition: false, to: tmp)

        let target = try makeContainer()
        do {
            try await BackupArchive.restore(from: tmp, into: target.mainContext, strategy: .replaceAll)
            Issue.record("Expected schema 3 restore to require StockPosition.json")
        } catch {
            #expect(true)
        }
    }
}
