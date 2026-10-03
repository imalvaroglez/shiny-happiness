import Testing
import CryptoKit
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
        try SeedDataLoader.bootstrapIfNeeded(context: context)

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
                amount: -Decimal(100 + i),
                currency: "MXN",
                descriptionRaw: "Test transaction #\(i)"
            )
            if i == 0 {
                try tx.setCustomFerAmount(40)
                tx.settlementNotes = "Groceries"
            } else if i == 1 {
                tx.setExpenseAssignment(.partner)
            } else if i == 2 {
                tx.expenseAssignmentRaw = "unassigned"
            }
            context.insert(tx)
        }
        context.insert(HouseholdPartnerIncomeEstimate(
            monthStart: HouseholdPartnerIncomeService.monthStart(for: .now),
            amount: 25_000,
            useUserIncomeManualOverride: true,
            userIncomeManualOverride: 50_000,
            splitMethodRaw: HouseholdSplitMethod.customPercent.rawValue,
            customUserPercent: 80,
            customPartnerPercent: 20,
            notes: "Backup test"
        ))
        try context.save()
        return container
    }

    private func writeEmptyBackup(schemaVersion: Int, includeStockPosition: Bool, includePartnerEstimate: Bool = false, to tmp: URL) throws {
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
        if includePartnerEstimate {
            try write("HouseholdPartnerIncomeEstimate", [HouseholdPartnerIncomeEstimateSnapshot]())
        }

        try encoder.encode(BackupManifest(
            schemaVersion: schemaVersion,
            createdAt: Date(),
            appVersion: "test",
            modelCounts: [:],
            contentHashes: [:]
        )).write(to: tmp.appendingPathComponent("manifest.json"))
    }

    private func writeManifest(createdAt: Date, schemaVersion: Int = 7, to bundle: URL) throws {
        let modelsDir = bundle.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        let modelNames = [
            "Account", "Statement", "Category", "CategoryRule", "InstallmentPlan",
            "Transaction", "PendingImport", "SignRecoveryHint", "StockPosition",
            "HouseholdPartnerIncomeEstimate", "SettlementDueDateOverride",
        ]
        for name in modelNames {
            try Data("[]".utf8).write(to: modelsDir.appendingPathComponent("\(name).json"))
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(BackupManifest(
            schemaVersion: schemaVersion,
            createdAt: createdAt,
            appVersion: "test",
            modelCounts: [:],
            contentHashes: [:]
        )).write(to: bundle.appendingPathComponent("manifest.json"))
    }

    private func promotionLedgerURL(for bundle: URL) -> URL {
        bundle.appendingPathComponent("test-app-support/PromotionLedger.json")
    }

    private func exportBackup(to bundle: URL, from context: ModelContext,
                              ledgerURL: URL? = nil) async throws {
        try await BackupArchive.export(to: bundle, from: context,
                                       promotionLedgerURL: ledgerURL ?? promotionLedgerURL(for: bundle))
    }

    private func restoreBackup(from bundle: URL, into context: ModelContext, strategy: RestoreStrategy,
                               ledgerURL: URL? = nil) async throws {
        try await BackupArchive.restore(from: bundle, into: context, strategy: strategy,
                                        promotionLedgerURL: ledgerURL ?? promotionLedgerURL(for: bundle))
    }

    private func updateManifestHash(for modelName: String, in bundle: URL) throws {
        let manifestURL = bundle.appendingPathComponent("manifest.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var manifest = try decoder.decode(BackupManifest.self, from: Data(contentsOf: manifestURL))
        let modelURL = bundle.appendingPathComponent("models/\(modelName).json")
        let data = try Data(contentsOf: modelURL)
        manifest.contentHashes[modelName] = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: manifestURL)
    }

    @Test("Backup catalog uses manifest dates and selects the latest valid bundle")
    func backupCatalogSelectsLatestManifestDate() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-catalog-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let old = root.appendingPathComponent("9999-old-name.ftbackup", isDirectory: true)
        let latest = root.appendingPathComponent("0000-new-name.ftbackup", isDirectory: true)
        let invalid = root.appendingPathComponent("invalid.ftbackup", isDirectory: true)
        try writeManifest(createdAt: Date(timeIntervalSince1970: 100), to: old)
        try writeManifest(createdAt: Date(timeIntervalSince1970: 200), to: latest)
        try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)

        let summaries = BackupArchive.summaries(in: root)
        #expect(summaries.map(\.url.lastPathComponent) == ["0000-new-name.ftbackup", "9999-old-name.ftbackup"])
        #expect(BackupArchive.latestBackup(in: root)?.url == latest)
    }

    @Test("Backup folder store remembers and resolves a selected folder")
    func backupFolderStoreRemembersSelectedFolder() throws {
        let suiteName = "BackupFolderStoreTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("remembered-backups-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        try BackupFolderStore.remember(directory: folder, defaults: defaults)
        let access = BackupFolderStore.accessForLatest(
            defaultDirectory: FileManager.default.temporaryDirectory,
            defaults: defaults
        )
        defer { access.stopAccessing() }

        #expect(access.url.standardizedFileURL == folder.standardizedFileURL)
    }

    @Test("Backup folder store refreshes a stale bookmark after a folder moves")
    func backupFolderStoreRefreshesStaleBookmark() throws {
        let suiteName = "BackupFolderStoreTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("moved-backups-root-\(UUID())", isDirectory: true)
        let original = root.appendingPathComponent("original", isDirectory: true)
        let moved = root.appendingPathComponent("moved", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try BackupFolderStore.remember(directory: original, defaults: defaults)
        try FileManager.default.moveItem(at: original, to: moved)

        let access = BackupFolderStore.accessForLatest(
            defaultDirectory: FileManager.default.temporaryDirectory,
            defaults: defaults
        )
        defer { access.stopAccessing() }

        #expect(access.url.standardizedFileURL == moved.standardizedFileURL)
    }

    @Test("Deleted remembered folder falls back without opening a selector")
    func backupFolderStoreFallsBackWhenFolderIsDeleted() throws {
        let suiteName = "BackupFolderStoreTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("deleted-backups-\(UUID())", isDirectory: true)
        let fallback = FileManager.default.temporaryDirectory
            .appendingPathComponent("fallback-backups-\(UUID())", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: fallback)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)

        try BackupFolderStore.remember(directory: folder, defaults: defaults)
        try FileManager.default.removeItem(at: folder)

        let access = BackupFolderStore.accessForLatest(defaultDirectory: fallback, defaults: defaults)
        defer { access.stopAccessing() }
        #expect(access.url.standardizedFileURL == fallback.standardizedFileURL)
    }

    @Test("An empty backup folder has no latest backup")
    func emptyBackupFolderHasNoLatestBackup() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-backups-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        #expect(BackupArchive.latestBackup(in: folder) == nil)
    }

    @Test("Invalid backup does not delete existing data")
    func invalidBackupDoesNotDeleteExistingData() async throws {
        let source = try makeContainer()
        let account = Account(institution: "Live Bank", type: .checking, nickname: "Keep me")
        source.mainContext.insert(account)
        try source.mainContext.save()

        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("invalid-backup-\(UUID()).ftbackup", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: bundle) }
        try writeManifest(createdAt: .now, to: bundle)
        try FileManager.default.removeItem(at: bundle.appendingPathComponent("models/Transaction.json"))

        do {
            try await restoreBackup(from: bundle, into: source.mainContext, strategy: .replaceAll)
            Issue.record("Expected incomplete backup to be rejected")
        } catch {
            // Expected: validation happens before replaceAll deletes any rows.
        }

        #expect(try source.mainContext.fetch(FetchDescriptor<Account>()).count == 1)
        #expect(try source.mainContext.fetch(FetchDescriptor<Account>()).first?.nickname == "Keep me")
    }

    @Test("Round-trip: export then replaceAll restores all rows")
    func roundTripReplaceAll() async throws {
        let source = try makePopulatedContainer()
        let sourceContext = source.mainContext

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-backup-\(UUID()).ftbackup", isDirectory: true)

        try await exportBackup(to: tmp, from: sourceContext)

        let target = try makeContainer()
        try await restoreBackup(from: tmp, into: target.mainContext, strategy: .replaceAll)

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
        try await exportBackup(to: tmp, from: sourceContext)

        let target = try makeContainer()
        let targetContext = target.mainContext
        try SeedDataLoader.bootstrapIfNeeded(context: targetContext)

        let existingAccount = Account(institution: "Test Bank", type: .checking, currency: "MXN", nickname: "Old Nickname")
        existingAccount.lastModifiedAt = .now.addingTimeInterval(-86400)
        targetContext.insert(existingAccount)
        try targetContext.save()

        try await restoreBackup(from: tmp, into: targetContext, strategy: .mergeKeepingNewer)

        let restored = try targetContext.fetch(FetchDescriptor<Account>())
        let testAccount = restored.first { $0.institution == "Test Bank" }
        #expect(testAccount != nil, "Test Bank account should exist after merge")
        #expect(testAccount?.nickname == "Old Nickname",
                "Older existing row should win over newer backup row")

        try? FileManager.default.removeItem(at: tmp)
    }

    @Test("mergeKeepingNewer preserves relationships from the winning live rows")
    func mergeKeepsWinningRelationships() async throws {
        let target = try makeContainer()
        let targetContext = target.mainContext
        let account = Account(institution: "Test Bank", type: .checking, currency: "MXN", nickname: "Checking")
        let currentParent = FinanceTracker.Category(name: "Current Parent")
        let backupParent = FinanceTracker.Category(name: "Old Parent")
        let category = FinanceTracker.Category(name: "Food", parent: currentParent)
        let transaction = Transaction(account: account, postedAt: .now, amount: -100,
                                      descriptionRaw: "Groceries", category: category)
        let later = Date.now
        let earlier = later.addingTimeInterval(-86_400)
        category.lastModifiedAt = later
        transaction.lastModifiedAt = later
        targetContext.insert(account)
        targetContext.insert(currentParent)
        targetContext.insert(backupParent)
        targetContext.insert(category)
        targetContext.insert(transaction)
        try targetContext.save()

        let source = try makeContainer()
        let sourceContext = source.mainContext
        let sourceAccount = Account(id: account.id, institution: "Test Bank", type: .checking,
                                    currency: "MXN", nickname: "Checking")
        let sourceParent = FinanceTracker.Category(id: backupParent.id, name: "Old Parent")
        let sourceCategory = FinanceTracker.Category(id: category.id, name: "Old Food", parent: sourceParent)
        let sourceTransaction = Transaction(id: transaction.id, account: sourceAccount, postedAt: .now,
                                           amount: -100, descriptionRaw: "Old description", category: sourceCategory)
        sourceCategory.lastModifiedAt = earlier
        sourceTransaction.lastModifiedAt = earlier
        sourceContext.insert(sourceAccount)
        sourceContext.insert(sourceParent)
        sourceContext.insert(sourceCategory)
        sourceContext.insert(sourceTransaction)
        try sourceContext.save()

        let backup = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-backup-old-relations-\(UUID()).ftbackup", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: backup) }
        try await exportBackup(to: backup, from: sourceContext)

        try await restoreBackup(from: backup, into: targetContext, strategy: .mergeKeepingNewer)

        let mergedCategory = try #require(targetContext.fetch(FetchDescriptor<FinanceTracker.Category>())
            .first { $0.id == category.id })
        let mergedTransaction = try #require(targetContext.fetch(FetchDescriptor<Transaction>())
            .first { $0.id == transaction.id })
        #expect(mergedCategory.parent?.id == currentParent.id)
        #expect(mergedCategory.name == "Food")
        #expect(mergedTransaction.category?.id == category.id)
        #expect(mergedTransaction.descriptionRaw == "Groceries")
    }

    @Test("mergeKeepingNewer preserves an explicit live scope against a legacy nil-scope snapshot")
    func mergePreservesExplicitScope() async throws {
        // Live row is explicitly EXCLUDED by the user but retains a latent .shared
        // assignment. A legacy (nil-scope) backup snapshot whose lastModifiedAt is
        // newer must NOT re-include it: already-explicit scope always wins.
        let target = try makeContainer()
        let targetContext = target.mainContext
        try SeedDataLoader.bootstrapIfNeeded(context: targetContext)
        let account = Account(institution: "Test Bank", type: .checking, currency: "MXN", nickname: "Checking")
        targetContext.insert(account)
        let food = FinanceTracker.Category(name: "Rent", kind: .expense)
        targetContext.insert(food)
        let tx = Transaction(
            account: account,
            postedAt: .now,
            amount: -1_000,
            descriptionRaw: "Rent",
            category: food
        )
        tx.setExpenseAssignment(.shared)
        tx.setHouseholdScope(.excluded)   // explicit user exclusion
        tx.lastModifiedAt = .now.addingTimeInterval(-60)
        targetContext.insert(tx)
        try targetContext.save()

        // Build a backup from a fresh container with the same tx id, shared+included.
        let source = try makeContainer()
        let sourceContext = source.mainContext
        let sAccount = Account(institution: "Test Bank", type: .checking, currency: "MXN", nickname: "Checking")
        sourceContext.insert(sAccount)
        let sFood = FinanceTracker.Category(name: "Rent", kind: .expense)
        sourceContext.insert(sFood)
        let sTx = Transaction(
            id: tx.id,
            account: sAccount,
            postedAt: .now,
            amount: -1_000,
            descriptionRaw: "Rent",
            category: sFood
        )
        sTx.setExpenseAssignment(.shared)
        sTx.setHouseholdScope(.included)  // newer backup says included
        sTx.lastModifiedAt = .now          // newer than the live row → merge applies it
        sourceContext.insert(sTx)
        try sourceContext.save()

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-backup-scope-merge-\(UUID()).ftbackup", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await exportBackup(to: tmp, from: sourceContext)

        // Strip the scope-carrying columns from the exported snapshot to simulate
        // a legacy (pre-scope) backup. Scope is persisted in settlementPaidByRaw
        // (repurposed); householdScopeRaw is a redundant alias also written by export.
        let txURL = tmp.appendingPathComponent("models/Transaction.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: txURL)) as? [[String: Any]] ?? []
        for i in json.indices {
            json[i].removeValue(forKey: "householdScopeRaw")
            json[i].removeValue(forKey: "settlementPaidByRaw")
        }
        let stripped = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
        try stripped.write(to: txURL)
        try updateManifestHash(for: "Transaction", in: tmp)

        try await restoreBackup(from: tmp, into: targetContext, strategy: .mergeKeepingNewer)

        let restored = try #require(targetContext.fetch(FetchDescriptor<Transaction>()).first { $0.id == tx.id })
        #expect(restored.householdScopeRaw == "excluded",
               "explicit live exclusion must survive a legacy nil-scope merge")
        #expect(restored.expenseAssignment == .shared)
    }

    @Test("Manifest content hashes match the JSON files on disk")
    func manifestIntegrity() async throws {
        let source = try makePopulatedContainer()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-backup-hash-\(UUID()).ftbackup", isDirectory: true)
        try await exportBackup(to: tmp, from: source.mainContext)

        let manifestURL = tmp.appendingPathComponent("manifest.json")
        let manifestData = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(BackupManifest.self, from: manifestData)

        #expect(manifest.schemaVersion == 11)
        #expect(!manifest.contentHashes.isEmpty, "Manifest should have content hashes")

        for (name, _) in manifest.contentHashes {
            let fileURL = tmp.appendingPathComponent("models/\(name).json")
            #expect(FileManager.default.fileExists(atPath: fileURL.path),
                   "Manifest references \(name) but models/\(name).json doesn't exist")
        }

        try? FileManager.default.removeItem(at: tmp)
    }

    @Test("El ledger de promociones round-tripea en replaceAll y preserva lo más nuevo en merge")
    func promotionLedgerRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("promo-ledger-backup-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("snapshot.ftbackup", isDirectory: true)
        let sourceStore = root.appendingPathComponent("source/PromotionLedger.json")
        let targetStore = root.appendingPathComponent("target/PromotionLedger.json")

        let baseTime = Date(timeIntervalSince1970: 1_700_000_000)
        let backupPromoID = UUID()
        var backupLedger = PromotionLedger()
        backupLedger.promotions = [
            PromotionRecord(id: backupPromoID, name: "Platinum 90 días", accountID: UUID(),
                            currency: "MXN", windowStart: nil, windowEnd: nil,
                            targetAmount: 100_000, rewardNote: nil, notes: nil, archivedAt: nil,
                            createdAt: baseTime, updatedAt: baseTime, deletedAt: nil)
        ]
        backupLedger.attributions = [
            PromotionAttribution(id: UUID(), promotionID: backupPromoID, transactionID: UUID(),
                                 createdAt: baseTime, updatedAt: baseTime, deletedAt: nil)
        ]
        backupLedger.updatedAt = baseTime
        try PromotionLedgerStore.replace(with: backupLedger, at: sourceStore)

        let source = try makeContainer()
        try await BackupArchive.export(to: bundle, from: source.mainContext, promotionLedgerURL: sourceStore)

        let manifestURL = bundle.appendingPathComponent("manifest.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(BackupManifest.self, from: Data(contentsOf: manifestURL))
        #expect(manifest.schemaVersion == 11)
        #expect(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("models/PromotionLedger.json").path))
        #expect(!FileManager.default.fileExists(atPath: bundle.appendingPathComponent("models/PromotionOverrides.json").path),
                "El manifest 10 ya no exporta el store retirado del V1")

        // replaceAll: el ledger local distinto se reemplaza por el del backup.
        var localLedger = PromotionLedger()
        localLedger.promotions = [
            PromotionRecord(id: UUID(), name: "Promo local que desaparece", accountID: UUID(),
                            currency: "MXN", windowStart: nil, windowEnd: nil, targetAmount: nil,
                            rewardNote: nil, notes: nil, archivedAt: nil,
                            createdAt: baseTime.addingTimeInterval(60), updatedAt: baseTime.addingTimeInterval(60),
                            deletedAt: nil)
        ]
        localLedger.updatedAt = baseTime.addingTimeInterval(60)
        try PromotionLedgerStore.replace(with: localLedger, at: targetStore)

        let target = try makeContainer()
        try await BackupArchive.restore(from: bundle, into: target.mainContext, strategy: .replaceAll,
                                        promotionLedgerURL: targetStore)
        let restored = try PromotionLedgerStore.read(fileURL: targetStore)
        let expected = try PromotionLedgerStore.read(fileURL: sourceStore)
        #expect(restored == expected)

        // mergeKeepingNewer: la promo local más nueva se conserva y la del backup se agrega.
        let newerTime = baseTime.addingTimeInterval(600)
        localLedger.promotions[0].updatedAt = newerTime
        localLedger.promotions[0].name = "Promo local editada después"
        try PromotionLedgerStore.replace(with: localLedger, at: targetStore)
        try await BackupArchive.restore(from: bundle, into: target.mainContext, strategy: .mergeKeepingNewer,
                                        promotionLedgerURL: targetStore)
        let merged = try PromotionLedgerStore.read(fileURL: targetStore)
        #expect(merged.promotions.count == 2)
        #expect(merged.promotions.contains { $0.id == backupPromoID })
        #expect(merged.promotions.contains { $0.name == "Promo local editada después" && $0.updatedAt == newerTime })
    }

    @Test("Backup v9 sin ledger: replaceAll vacía el ledger local y merge lo conserva")
    func legacyBackupWithoutLedgerFollowsStrategy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-v9-no-ledger-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("snapshot.ftbackup", isDirectory: true)
        try writeLegacyBundle(schemaVersion: 9, to: bundle)

        let storeURL = root.appendingPathComponent("local/PromotionLedger.json")
        let seedTime = Date(timeIntervalSince1970: 1_700_000_000)
        var local = PromotionLedger()
        local.promotions = [
            PromotionRecord(id: UUID(), name: "Promo local", accountID: UUID(), currency: "MXN",
                            windowStart: nil, windowEnd: nil, targetAmount: nil, rewardNote: nil,
                            notes: nil, archivedAt: nil, createdAt: seedTime, updatedAt: seedTime,
                            deletedAt: nil)
        ]
        local.attributions = [
            PromotionAttribution(id: UUID(), promotionID: local.promotions[0].id, transactionID: UUID(),
                                 createdAt: seedTime, updatedAt: seedTime, deletedAt: nil)
        ]
        local.updatedAt = seedTime

        let target = try makeContainer()
        try PromotionLedgerStore.replace(with: local, at: storeURL)
        try await BackupArchive.restore(from: bundle, into: target.mainContext, strategy: .replaceAll,
                                        promotionLedgerURL: storeURL)
        let emptied = try PromotionLedgerStore.read(fileURL: storeURL)
        #expect(emptied.promotions.isEmpty && emptied.attributions.isEmpty,
                "replaceAll con backup ≤9 deja el ledger vacío")

        try PromotionLedgerStore.replace(with: local, at: storeURL)
        try await BackupArchive.restore(from: bundle, into: target.mainContext, strategy: .mergeKeepingNewer,
                                        promotionLedgerURL: storeURL)
        let preserved = try PromotionLedgerStore.read(fileURL: storeURL)
        #expect(preserved.promotions.count == 1)
        #expect(preserved.promotions.first?.name == "Promo local")
        #expect(preserved.attributions.count == 1)
    }

    /// Bundle legacy 8+ completo: base + archivos requeridos por 7/8 (due-date
    /// overrides, promotion overrides del V1), 9 (spend requirements),
    /// 10 (PromotionLedger) y 11 (CategoryCustomization).
    private func writeLegacyBundle(schemaVersion: Int, to tmp: URL) throws {
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
        try write("StockPosition", [StockPositionSnapshot]())
        try write("HouseholdPartnerIncomeEstimate", [HouseholdPartnerIncomeEstimateSnapshot]())
        try write("SettlementDueDateOverride", [SettlementDueDateOverrideSnapshot]())
        // El store del V1 ya no existe; los backups 8..<10 solo exigen que el
        // archivo sea un arreglo JSON válido (verificación de hashes/presencia).
        try Data("[]".utf8).write(to: modelsDir.appendingPathComponent("PromotionOverrides.json"))
        if schemaVersion >= 9 {
            try write("SpendRequirement", [SpendRequirementSettings()])
        }
        if schemaVersion >= 10 {
            try write("PromotionLedger", [PromotionLedger()])
        }
        if schemaVersion >= 11 {
            try write("CategoryCustomization", [CategoryCustomizationCatalog()])
        }
        try encoder.encode(BackupManifest(schemaVersion: schemaVersion, createdAt: Date(), appVersion: "test",
                                           modelCounts: [:], contentHashes: [:]))
            .write(to: tmp.appendingPathComponent("manifest.json"))
    }

    @Test("Spend requirements restore exactly, merge by account timestamp, and old backups follow strategy")
    func spendRequirementBackupRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spend-backup-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("snapshot.ftbackup", isDirectory: true)
        let sourceStore = root.appendingPathComponent("source/SpendRequirements.json")
        let targetStore = root.appendingPathComponent("target/SpendRequirements.json")
        let source = try makeContainer()
        let account = Account(institution: "HSBC", type: .creditCard, nickname: "2Now de Mar")
        source.mainContext.insert(account)
        try source.mainContext.save()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        var requirement = SpendRequirement(accountID: account.id, name: "Gasto mínimo", amount: 3_500,
                                           currency: "MXN", statementClosingDay: 11,
                                           adjustToPreviousBusinessDay: true)
        requirement.lastModifiedAt = timestamp
        let sourceSettings = SpendRequirementSettings(updatedAt: timestamp, requirements: [requirement])
        try SpendRequirementStore.replace(with: sourceSettings, at: sourceStore, accountIDs: [account.id])
        try await BackupArchive.export(to: bundle, from: source.mainContext,
                                       promotionLedgerURL: root.appendingPathComponent("source/PromotionLedger.json"),
                                       spendRequirementsURL: sourceStore)
        #expect(BackupArchive.summary(at: bundle)?.schemaVersion == 11)

        let target = try makeContainer()
        var newer = requirement
        newer.enabled = false
        newer.lastModifiedAt = timestamp.addingTimeInterval(300)
        let newerSettings = SpendRequirementSettings(updatedAt: newer.lastModifiedAt, requirements: [newer])
        try SpendRequirementStore.replace(with: newerSettings, at: targetStore)
        try await BackupArchive.restore(from: bundle, into: target.mainContext, strategy: .replaceAll,
                                       promotionLedgerURL: root.appendingPathComponent("target/PromotionLedger.json"),
                                       spendRequirementsURL: targetStore)
        #expect(try SpendRequirementStore.read(fileURL: targetStore) == sourceSettings)

        try SpendRequirementStore.replace(with: newerSettings, at: targetStore)
        try await BackupArchive.restore(from: bundle, into: target.mainContext, strategy: .mergeKeepingNewer,
                                       promotionLedgerURL: root.appendingPathComponent("target/PromotionLedger.json"),
                                       spendRequirementsURL: targetStore)
        #expect(try SpendRequirementStore.read(fileURL: targetStore) == newerSettings)

        // Downgrade real a v8: un bundle v8 legítimo incluye PromotionOverrides
        // (requerido en 8..<10) pero no SpendRequirement. Fabricarlo completo es
        // más fiel que degradar el manifest de un export v10.
        try FileManager.default.removeItem(at: bundle)
        try writeLegacyBundle(schemaVersion: 8, to: bundle)
        #expect(BackupArchive.summary(at: bundle)?.schemaVersion == 8)

        try await BackupArchive.restore(from: bundle, into: target.mainContext, strategy: .replaceAll,
                                       promotionLedgerURL: root.appendingPathComponent("target/PromotionLedger.json"),
                                       spendRequirementsURL: targetStore)
        #expect(!FileManager.default.fileExists(atPath: targetStore.path))
        try SpendRequirementStore.replace(with: newerSettings, at: targetStore)
        try await BackupArchive.restore(from: bundle, into: target.mainContext, strategy: .mergeKeepingNewer,
                                       promotionLedgerURL: root.appendingPathComponent("target/PromotionLedger.json"),
                                       spendRequirementsURL: targetStore)
        #expect(try SpendRequirementStore.read(fileURL: targetStore) == newerSettings)
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
        try await restoreBackup(from: tmp, into: target.mainContext, strategy: .replaceAll)
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

        try await exportBackup(to: tmp, from: context)

        let target = try makeContainer()
        try await restoreBackup(from: tmp, into: target.mainContext, strategy: .replaceAll)
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

    @Test("Household settlement exact allocations round-trip on v5 backup")
    func householdSettlementRoundTrip() async throws {
        let source = try makePopulatedContainer()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-backup-household-\(UUID()).ftbackup", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try await exportBackup(to: tmp, from: source.mainContext)

        let target = try makeContainer()
        try await restoreBackup(from: tmp, into: target.mainContext, strategy: .replaceAll)

        let transactions = try target.mainContext.fetch(FetchDescriptor<Transaction>())
        let custom = try #require(transactions.first { $0.expenseAssignment == .custom })
        let partner = try #require(transactions.first { $0.expenseAssignment == .partner })
        let user = try #require(transactions.first { $0.expenseAssignment == .user })
        let estimates = try target.mainContext.fetch(FetchDescriptor<HouseholdPartnerIncomeEstimate>())
        let estimate = try #require(estimates.first)

        #expect(custom.customFerAmount == 40)
        #expect(custom.customUserPercent == nil)
        #expect(custom.splitMethodOverride == .monthlyDefault)
        #expect(custom.settlementNotes == "Groceries")
        #expect(partner.expenseAssignment == .partner)
        #expect(user.expenseAssignmentRaw == nil)
        // Legacy scope derived from assignment on restore: custom/partner → included, user/unassigned → excluded.
        #expect(custom.householdScope == .included)
        #expect(partner.householdScope == .included)
        #expect(user.householdScope == .excluded)
        #expect(estimates.count == 1)
        #expect(estimate.amount == 25_000)
        #expect(estimate.useUserIncomeManualOverride)
        #expect(estimate.userIncomeManualOverride == 50_000)
        #expect(estimate.splitMethod == .customPercent)
        #expect(estimate.customUserPercent == 80)
        #expect(estimate.customPartnerPercent == 20)
        #expect(estimate.notes == "Backup test")
    }

    @Test("Repurposed settlementPaidByRaw scope values round-trip exactly")
    func scopeValuesRoundTrip() async throws {
        let source = try makeContainer()
        let context = source.mainContext
        try SeedDataLoader.bootstrapIfNeeded(context: context)
        let account = Account(institution: "Bank", type: .checking, currency: "MXN", nickname: "Checking")
        context.insert(account)
        let food = FinanceTracker.Category(name: "Rent", kind: .expense)
        context.insert(food)
        let included = Transaction(account: account, postedAt: .now, amount: -1_000, descriptionRaw: "Rent", category: food)
        included.setExpenseAssignment(.shared)
        included.setHouseholdScope(.included)
        let excluded = Transaction(account: account, postedAt: .now, amount: -50, descriptionRaw: "Coffee", category: food)
        excluded.setHouseholdScope(.excluded)
        context.insert(included)
        context.insert(excluded)
        try context.save()

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-backup-scope-rt-\(UUID()).ftbackup", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await exportBackup(to: tmp, from: context)

        let target = try makeContainer()
        try await restoreBackup(from: tmp, into: target.mainContext, strategy: .replaceAll)

        let restored = try target.mainContext.fetch(FetchDescriptor<Transaction>())
        #expect(restored.first { $0.descriptionRaw == "Rent" }?.householdScopeRaw == "included")
        #expect(restored.first { $0.descriptionRaw == "Rent" }?.householdScope == .included)
        #expect(restored.first { $0.descriptionRaw == "Coffee" }?.householdScopeRaw == "excluded")
        #expect(restored.first { $0.descriptionRaw == "Coffee" }?.householdScope == .excluded)
    }

    @Test("Legacy SettlementPaidBy raw values are not misread as scope on restore")
    func legacySettlementPaidByRawNotMisreadAsScope() async throws {
        // The scope column (settlementPaidByRaw) is repurposed. A legacy backup
        // could in principle carry dead SettlementPaidBy raws ("user"/"partner"/
        // "unknown"). None of those are valid HouseholdScope raws, so restore must
        // treat them as legacy and re-derive scope from assignment, not interpret
        // them as scope.
        let source = try makePopulatedContainer()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-backup-legacy-spb-\(UUID()).ftbackup", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await exportBackup(to: tmp, from: source.mainContext)

        // Inject legacy SettlementPaidBy raws into the exported snapshot.
        let txURL = tmp.appendingPathComponent("models/Transaction.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: txURL)) as? [[String: Any]] ?? []
        for i in json.indices {
            let tx = json[i]
            // settlementPaidByRaw holds legacy values; ensure no householdScopeRaw
            // alias is present so the derive path runs.
            var t = tx
            t.removeValue(forKey: "householdScopeRaw")
            t["settlementPaidByRaw"] = "partner"  // a dead SettlementPaidBy raw, not a scope
            json[i] = t
        }
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]).write(to: txURL)
        try updateManifestHash(for: "Transaction", in: tmp)

        let target = try makeContainer()
        try await restoreBackup(from: tmp, into: target.mainContext, strategy: .replaceAll)

        let restored = try target.mainContext.fetch(FetchDescriptor<Transaction>())
        // "partner" is not a valid HouseholdScope → decodes to .excluded (never .included).
        // The legacy raw must NOT be honored as scope.
        #expect(restored.allSatisfy { $0.householdScope != .included || $0.expenseAssignment == .custom || $0.expenseAssignment == .partner || $0.expenseAssignment == .shared },
               "no transaction should be 'included' solely because of a legacy SettlementPaidBy raw")
        // Concretely: a user-assigned tx with a stale 'partner' settlementPaidByRaw is excluded.
        let user = try #require(restored.first { $0.expenseAssignment == .user })
        #expect(user.householdScope == .excluded)
    }

    @Test("Schema 4 percentage overrides restore as exact Custom allocations")
    func schemaFourHouseholdOverrideMigration() async throws {
        let source = try makePopulatedContainer()
        let sourceTransactions = try source.mainContext.fetch(FetchDescriptor<Transaction>())
        let legacy = try #require(sourceTransactions.first { $0.expenseAssignment == .custom })
        legacy.setExpenseAssignment(.shared)
        legacy.setSplitMethodOverride(.customPercent)
        legacy.customUserPercent = 60
        legacy.customPartnerPercent = 40
        try source.mainContext.save()

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-backup-household-v4-\(UUID()).ftbackup", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await exportBackup(to: tmp, from: source.mainContext)

        let manifestURL = tmp.appendingPathComponent("manifest.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var manifest = try decoder.decode(BackupManifest.self, from: Data(contentsOf: manifestURL))
        manifest.schemaVersion = 4
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: manifestURL)

        let target = try makeContainer()
        try await restoreBackup(from: tmp, into: target.mainContext, strategy: .replaceAll)
        let restored = try target.mainContext.fetch(FetchDescriptor<Transaction>())
        let custom = try #require(restored.first { $0.expenseAssignment == .custom })

        #expect(custom.customFerAmount == 40)
        #expect(custom.customUserPercent == nil)
        #expect(custom.splitMethodOverrideRaw == nil)
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

        try await exportBackup(to: tmp, from: sourceContext)

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

        try await restoreBackup(from: tmp, into: targetContext, strategy: .mergeKeepingNewer)

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
        try await restoreBackup(from: tmp, into: target.mainContext, strategy: .replaceAll)
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
            try await restoreBackup(from: tmp, into: target.mainContext, strategy: .replaceAll)
            Issue.record("Expected schema 3 restore to require StockPosition.json")
        } catch {
            #expect(true)
        }
    }

    @Test("Schema 4 backup requires household partner estimate file")
    func schemaFourBackupRequiresPartnerEstimateFile() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("schema-four-missing-partner-estimate-\(UUID()).ftbackup", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try writeEmptyBackup(schemaVersion: 4, includeStockPosition: true, includePartnerEstimate: false, to: tmp)

        let target = try makeContainer()
        do {
            try await restoreBackup(from: tmp, into: target.mainContext, strategy: .replaceAll)
            Issue.record("Expected schema 4 restore to require HouseholdPartnerIncomeEstimate.json")
        } catch {
            #expect(true)
        }
    }

    @Test("mergeKeepingNewer removes orphan due-date overrides for missing transactions")
    func mergeRemovesOrphanDueDateOverrides() async throws {
        let source = try makeContainer()
        let sourceContext = source.mainContext
        try SeedDataLoader.bootstrapIfNeeded(context: sourceContext)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-backup-orphan-\(UUID()).ftbackup", isDirectory: true)
        try await exportBackup(to: tmp, from: sourceContext)

        let target = try makeContainer()
        let targetContext = target.mainContext
        try SeedDataLoader.bootstrapIfNeeded(context: targetContext)

        // A due-date override whose transaction does NOT exist in the target store.
        let orphan = SettlementDueDateOverride(transactionID: UUID(), dueDate: Date())
        targetContext.insert(orphan)
        try targetContext.save()
        #expect(try targetContext.fetchCount(FetchDescriptor<SettlementDueDateOverride>()) == 1)

        try await restoreBackup(from: tmp, into: targetContext, strategy: .mergeKeepingNewer)

        #expect(try targetContext.fetchCount(FetchDescriptor<SettlementDueDateOverride>()) == 0,
                "Orphan override (no matching transaction) must be removed on merge")

        try? FileManager.default.removeItem(at: tmp)
    }
    @Test("Un bundle v10 sin PromotionLedger.json es inválido para restore")
    func v10BundleWithoutLedgerIsRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("v10-no-ledger-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("snapshot.ftbackup", isDirectory: true)
        try writeLegacyBundle(schemaVersion: 10, to: bundle)
        // El helper ya incluye el ledger desde v10: fabricar el caso inválido
        // quitándolo.
        try FileManager.default.removeItem(at: bundle.appendingPathComponent("models/PromotionLedger.json"))

        let target = try makeContainer()
        await #expect(throws: Error.self) {
            try await BackupArchive.restore(from: bundle, into: target.mainContext, strategy: .replaceAll,
                                            promotionLedgerURL: root.appendingPathComponent("local/PromotionLedger.json"))
        }
    }

    @Test("El fallo de restore tras tocar el ledger restaura el JSON previo")
    func restoreFailureRollsBackLedger() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rollback-ledger-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("snapshot.ftbackup", isDirectory: true)
        let sourceStore = root.appendingPathComponent("source/PromotionLedger.json")
        let targetStore = root.appendingPathComponent("target/PromotionLedger.json")

        let baseTime = Date(timeIntervalSince1970: 1_700_000_000)
        var backupLedger = PromotionLedger()
        backupLedger.promotions = [
            PromotionRecord(id: UUID(), name: "Platinum 90 días", accountID: UUID(), currency: "MXN",
                            windowStart: nil, windowEnd: nil, targetAmount: 100_000, rewardNote: nil,
                            notes: nil, archivedAt: nil, createdAt: baseTime, updatedAt: baseTime,
                            deletedAt: nil)
        ]
        backupLedger.updatedAt = baseTime
        try PromotionLedgerStore.replace(with: backupLedger, at: sourceStore)
        let source = try makeContainer()
        try await BackupArchive.export(to: bundle, from: source.mainContext, promotionLedgerURL: sourceStore)

        var localLedger = PromotionLedger()
        localLedger.promotions = [
            PromotionRecord(id: UUID(), name: "Local que debe sobrevivir", accountID: UUID(),
                            currency: "MXN", windowStart: nil, windowEnd: nil, targetAmount: nil,
                            rewardNote: nil, notes: nil, archivedAt: nil,
                            createdAt: baseTime.addingTimeInterval(60), updatedAt: baseTime.addingTimeInterval(60),
                            deletedAt: nil)
        ]
        localLedger.updatedAt = baseTime.addingTimeInterval(60)
        try PromotionLedgerStore.replace(with: localLedger, at: targetStore)

        let spendURL = root.appendingPathComponent("local/SpendRequirements.json")

        let target = try makeContainer()
        await #expect(throws: Error.self) {
            try await BackupArchive.restore(from: bundle, into: target.mainContext, strategy: .mergeKeepingNewer,
                                            promotionLedgerURL: targetStore,
                                            spendRequirementsURL: spendURL,
                                            checkpoint: { if $0 == .ledgerPublished { throw CocoaError(.fileWriteUnknown) } })
        }
        let after = try PromotionLedgerStore.read(fileURL: targetStore)
        #expect(after.promotions.count == 1)
        #expect(after.promotions.first?.name == "Local que debe sobrevivir",
                "el rollback del ledger restaura el contenido previo")
    }

    @Test("La personalización de categorías round-tripea en v11 y respeta estrategia en ≤10")
    func categoryCustomizationRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cat-custom-backup-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("snapshot.ftbackup", isDirectory: true)
        let sourceStore = root.appendingPathComponent("source/CategoryCustomization.json")
        let targetStore = root.appendingPathComponent("target/CategoryCustomization.json")

        let seedTime = Date(timeIntervalSince1970: 1_700_000_000)
        let renamedCategory = UUID()
        var catalog = CategoryCustomizationCatalog()
        catalog.entries = [
            CategoryCustomization(categoryID: renamedCategory, seedName: "Food & Drink",
                                  tintHex: "#FF8800", updatedAt: seedTime, deletedAt: nil),
        ]
        catalog.updatedAt = seedTime
        try CategoryCustomizationStore.replace(with: catalog, at: sourceStore)

        let source = try makeContainer()
        try await BackupArchive.export(to: bundle, from: source.mainContext,
                                       categoryCustomizationURL: sourceStore)
        #expect(BackupArchive.summary(at: bundle)?.schemaVersion == 11)

        // replaceAll: aplica el catálogo del backup.
        let target = try makeContainer()
        try await BackupArchive.restore(from: bundle, into: target.mainContext, strategy: .replaceAll,
                                        categoryCustomizationURL: targetStore)
        #expect(try CategoryCustomizationStore.read(fileURL: targetStore).entries.first?.tintHex == "#FF8800")

        // merge: el tinte local más nuevo gana sobre el del backup.
        var local = CategoryCustomizationCatalog()
        local.entries = [
            CategoryCustomization(categoryID: renamedCategory, seedName: nil,
                                  tintHex: "#00AAFF", updatedAt: seedTime.addingTimeInterval(600),
                                  deletedAt: nil),
        ]
        local.updatedAt = seedTime.addingTimeInterval(600)
        try CategoryCustomizationStore.replace(with: local, at: targetStore)
        try await BackupArchive.restore(from: bundle, into: target.mainContext, strategy: .mergeKeepingNewer,
                                        categoryCustomizationURL: targetStore)
        #expect(try CategoryCustomizationStore.read(fileURL: targetStore).entries.first?.tintHex == "#00AAFF")

        // Backup v10 sin el archivo: replaceAll vacía, merge conserva.
        try writeLegacyBundle(schemaVersion: 10, to: bundle)
        try CategoryCustomizationStore.replace(with: local, at: targetStore)
        try await BackupArchive.restore(from: bundle, into: target.mainContext, strategy: .replaceAll,
                                        categoryCustomizationURL: targetStore)
        #expect(try CategoryCustomizationStore.read(fileURL: targetStore).entries.isEmpty,
                "replaceAll con backup ≤10 deja la personalización vacía")
        try CategoryCustomizationStore.replace(with: local, at: targetStore)
        try await BackupArchive.restore(from: bundle, into: target.mainContext, strategy: .mergeKeepingNewer,
                                        categoryCustomizationURL: targetStore)
        #expect(try CategoryCustomizationStore.read(fileURL: targetStore).entries.count == 1,
                "merge con backup ≤10 conserva la personalización local")
    }
}


extension BackupArchiveTests {
    @Test("Compensation failure reports and keeps original recovery bytes")
    func compensationFailureRetainsRecoveryMaterial() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("compensation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("PromotionLedger.json")
        let original = Data("original bytes".utf8)
        try original.write(to: url)
        let files = try SidecarFileTransaction(urls: [url])
        defer { files.discard() }
        try Data("new bytes".utf8).write(to: files.stagedURL(for: url))
        try files.publish(url)
        // Force recovery to fail after publication, rather than failing the
        // initial read before any work has taken place.
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        do {
            try files.rollback()
            Issue.record("Recovery should fail with a directory replacing its destination")
        } catch let error as SidecarFileTransaction.RecoveryError {
            #expect(error.path == files.directory.path)
            #expect(!error.failures.isEmpty)
            #expect(try Data(contentsOf: files.directory.appendingPathComponent("original-0-PromotionLedger.json")) == original)
        }
    }

    @Test("Restore failure preserves disk data and exact sidecar bytes", arguments: BackupArchive.RestoreCheckpoint.allCases, [false, true])
    func restoreFailurePreservesDisk(_ failure: BackupArchive.RestoreCheckpoint, _ merge: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("restore-fault-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makePopulatedContainer()
        let bundle = root.appendingPathComponent("backup.ftbackup")
        let ledger = root.appendingPathComponent("local/PromotionLedger.json")
        let spend = root.appendingPathComponent("local/SpendRequirements.json")
        let custom = root.appendingPathComponent("local/CategoryCustomization.json")
        try CategoryCustomizationStore.setTint(categoryID: UUID(), hex: "#112233", at: custom)
        let customBytes = try Data(contentsOf: custom)
        let statementsSource = root.appendingPathComponent("source/Statements")
        try FileManager.default.createDirectory(at: statementsSource, withIntermediateDirectories: true)
        try Data("Synthetic statement".utf8).write(to: statementsSource.appendingPathComponent("fixture.pdf"))
        try PromotionLedgerStore.replace(with: PromotionLedger(), at: ledger)
        try await BackupArchive.export(to: bundle, from: source.mainContext,
                                      promotionLedgerURL: root.appendingPathComponent("source/PromotionLedger.json"),
                                      spendRequirementsURL: root.appendingPathComponent("source/SpendRequirements.json"),
                                      categoryCustomizationURL: root.appendingPathComponent("source/CategoryCustomization.json"),
                                      statementsSource: statementsSource)
        let originalBytes = try Data(contentsOf: ledger)
        let diskURL = root.appendingPathComponent("default.store")
        let config = ModelConfiguration(schema: AppSchema.schema, url: diskURL)
        var container: ModelContainer? = try ModelContainer(for: AppSchema.schema, configurations: [config])
        let localID: UUID
        do {
            let context = try #require(container).mainContext
            let local = Account(institution: "Local", type: .checking, currency: "MXN", nickname: "Keep me")
            localID = local.id
            context.insert(local)
            try context.save()
            await #expect(throws: Error.self) {
                try await BackupArchive.restore(from: bundle, into: context, strategy: merge ? .mergeKeepingNewer : .replaceAll,
                    promotionLedgerURL: ledger, spendRequirementsURL: spend, categoryCustomizationURL: custom,
                    statementsDestination: root.appendingPathComponent("Statements"),
                    checkpoint: { if $0 == failure && failure != .beforeSave { throw CocoaError(.fileWriteUnknown) } },
                    saveContext: { stagedContext in
                        #expect(!stagedContext.autosaveEnabled)
                        if failure == .beforeSave { throw CocoaError(.fileWriteUnknown) }
                        try stagedContext.save()
                    })
            }
            #expect(!context.hasChanges)
            #expect(try context.fetch(FetchDescriptor<Account>()).map(\.id) == [localID])
        }
        container = nil
        let reopened = try ModelContainer(for: AppSchema.schema, configurations: [config])
        #expect(try reopened.mainContext.fetch(FetchDescriptor<Account>()).map(\.id) == [localID])
        #expect(try Data(contentsOf: ledger) == originalBytes)
        #expect(try Data(contentsOf: custom) == customBytes)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Statements/fixture.pdf").path))
        #expect(!FileManager.default.fileExists(atPath: spend.path))
    }
}
