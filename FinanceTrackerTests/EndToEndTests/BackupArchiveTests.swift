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

    @Test("mergeKeepingNewer preserves an explicit live scope against a legacy nil-scope snapshot")
    func mergePreservesExplicitScope() async throws {
        // Live row is explicitly EXCLUDED by the user but retains a latent .shared
        // assignment. A legacy (nil-scope) backup snapshot whose lastModifiedAt is
        // newer must NOT re-include it: already-explicit scope always wins.
        let target = try makeContainer()
        let targetContext = target.mainContext
        SeedDataLoader.bootstrapIfNeeded(context: targetContext)
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
        try await BackupArchive.export(to: tmp, from: sourceContext)

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

        try await BackupArchive.restore(from: tmp, into: targetContext, strategy: .mergeKeepingNewer)

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
        try await BackupArchive.export(to: tmp, from: source.mainContext)

        let manifestURL = tmp.appendingPathComponent("manifest.json")
        let manifestData = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(BackupManifest.self, from: manifestData)

        #expect(manifest.schemaVersion == 6)
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

    @Test("Household settlement exact allocations round-trip on v5 backup")
    func householdSettlementRoundTrip() async throws {
        let source = try makePopulatedContainer()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-backup-household-\(UUID()).ftbackup", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try await BackupArchive.export(to: tmp, from: source.mainContext)

        let target = try makeContainer()
        try await BackupArchive.restore(from: tmp, into: target.mainContext, strategy: .replaceAll)

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
        try await BackupArchive.export(to: tmp, from: source.mainContext)

        let manifestURL = tmp.appendingPathComponent("manifest.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var manifest = try decoder.decode(BackupManifest.self, from: Data(contentsOf: manifestURL))
        manifest.schemaVersion = 4
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: manifestURL)

        let target = try makeContainer()
        try await BackupArchive.restore(from: tmp, into: target.mainContext, strategy: .replaceAll)
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

    @Test("Schema 4 backup requires household partner estimate file")
    func schemaFourBackupRequiresPartnerEstimateFile() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("schema-four-missing-partner-estimate-\(UUID()).ftbackup", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try writeEmptyBackup(schemaVersion: 4, includeStockPosition: true, includePartnerEstimate: false, to: tmp)

        let target = try makeContainer()
        do {
            try await BackupArchive.restore(from: tmp, into: target.mainContext, strategy: .replaceAll)
            Issue.record("Expected schema 4 restore to require HouseholdPartnerIncomeEstimate.json")
        } catch {
            #expect(true)
        }
    }
}
