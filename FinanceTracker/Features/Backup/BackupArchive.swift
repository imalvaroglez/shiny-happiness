import CryptoKit
import Foundation
import SwiftData

#if os(macOS)

enum RestoreStrategy {
    case mergeKeepingNewer
    case replaceAll
}

@MainActor
enum BackupArchive {
    private static let schemaVersion = 3
    private static let modelsSubdirectory = "models"
    private static let statementsSubdirectory = "statements"

    static func export(to bundleURL: URL, from context: ModelContext) async throws {
        let fm = FileManager.default
        let modelsDir = bundleURL.appendingPathComponent(modelsSubdirectory)
        let statementsDir = bundleURL.appendingPathComponent(statementsSubdirectory)

        try fm.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: statementsDir, withIntermediateDirectories: true)

        let plistURL = bundleURL.appendingPathComponent("Info.plist")
        let plist: [String: Any] = [
            "CFBundlePackageType": "BNDL",
            "CFBundleIdentifier": "com.financeTracker.app.backup",
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: plistURL)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]

        var modelCounts: [String: Int] = [:]
        var contentHashes: [String: String] = [:]

        func writeJSON<T: Codable>(_ name: String, _ snapshots: [T]) throws {
            let data = try encoder.encode(snapshots)
            let fileURL = modelsDir.appendingPathComponent("\(name).json")
            try data.write(to: fileURL)
            modelCounts[name] = snapshots.count
            contentHashes[name] = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
        }

        let accounts = try context.fetch(FetchDescriptor<Account>())
        try writeJSON("Account", accounts.map { AccountSnapshot($0) })

        let balanceSnapshots = try context.fetch(FetchDescriptor<AccountBalanceSnapshot>())
        try writeJSON("AccountBalanceSnapshot", balanceSnapshots.map { AccountBalanceSnapshotSnapshot($0) })

        let statements = try context.fetch(FetchDescriptor<Statement>())
        try writeJSON("Statement", statements.map { StatementSnapshot($0) })

        let transactions = try context.fetch(FetchDescriptor<Transaction>())
        try writeJSON("Transaction", transactions.map { TransactionSnapshot($0) })

        let categories = try context.fetch(FetchDescriptor<Category>())
        try writeJSON("Category", categories.map { CategorySnapshot($0) })

        let categoryRules = try context.fetch(FetchDescriptor<CategoryRule>())
        try writeJSON("CategoryRule", categoryRules.map { CategoryRuleSnapshot($0) })

        let installmentPlans = try context.fetch(FetchDescriptor<InstallmentPlan>())
        try writeJSON("InstallmentPlan", installmentPlans.map { InstallmentPlanSnapshot($0) })

        let pendingImports = try context.fetch(FetchDescriptor<PendingImport>())
        try writeJSON("PendingImport", pendingImports.map { PendingImportSnapshot($0) })

        let signRecoveryHints = try context.fetch(FetchDescriptor<SignRecoveryHint>())
        try writeJSON("SignRecoveryHint", signRecoveryHints.map { SignRecoveryHintSnapshot($0) })

        let stockPositions = try context.fetch(FetchDescriptor<StockPosition>())
        try writeJSON("StockPosition", stockPositions.map { StockPositionSnapshot($0) })

        let appSupport = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let sourceStatements = appSupport.appendingPathComponent("FinanceTracker/Statements")
        if fm.fileExists(atPath: sourceStatements.path) {
            let enumerator = fm.enumerator(at: sourceStatements, includingPropertiesForKeys: nil)
            while let file = enumerator?.nextObject() as? URL {
                let relative = file.path.replacingOccurrences(of: sourceStatements.path + "/", with: "")
                let dest = statementsDir.appendingPathComponent(relative)
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: file, to: dest)
            }
        }

        let manifest = BackupManifest(
            schemaVersion: schemaVersion,
            createdAt: .now,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
            modelCounts: modelCounts,
            contentHashes: contentHashes
        )
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: bundleURL.appendingPathComponent("manifest.json"))
    }

    static func restore(from bundleURL: URL, into context: ModelContext, strategy: RestoreStrategy) async throws {
        let fm = FileManager.default
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let manifestData = try Data(contentsOf: bundleURL.appendingPathComponent("manifest.json"))
        let manifest = try decoder.decode(BackupManifest.self, from: manifestData)
        guard [1, 2, 3].contains(manifest.schemaVersion) else {
            throw RestoreError.unsupportedSchema(manifest.schemaVersion)
        }

        let modelsDir = bundleURL.appendingPathComponent(modelsSubdirectory)

        func loadJSON<T: Codable>(_ type: T.Type, _ name: String) throws -> [T] {
            let data = try Data(contentsOf: modelsDir.appendingPathComponent("\(name).json"))
            return try decoder.decode([T].self, from: data)
        }

        func loadOptionalJSON<T: Codable>(_ type: T.Type, _ name: String) throws -> [T] {
            let url = modelsDir.appendingPathComponent("\(name).json")
            guard fm.fileExists(atPath: url.path) else { return [] }
            let data = try Data(contentsOf: url)
            return try decoder.decode([T].self, from: data)
        }

        switch strategy {
        case .replaceAll:
            try deleteAll(from: context)
        case .mergeKeepingNewer:
            break
        }

        let accountsSnap = try loadJSON(AccountSnapshot.self, "Account")
        let balanceSnapshotsSnap = try loadOptionalJSON(AccountBalanceSnapshotSnapshot.self, "AccountBalanceSnapshot")
        let statementsSnap = try loadJSON(StatementSnapshot.self, "Statement")
        let categoriesSnap = try loadJSON(CategorySnapshot.self, "Category")
        let categoryRulesSnap = try loadJSON(CategoryRuleSnapshot.self, "CategoryRule")
        let installmentPlansSnap = try loadJSON(InstallmentPlanSnapshot.self, "InstallmentPlan")
        let transactionsSnap = try loadJSON(TransactionSnapshot.self, "Transaction")
        let pendingImportsSnap = try loadJSON(PendingImportSnapshot.self, "PendingImport")
        let signRecoveryHintsSnap = try loadJSON(SignRecoveryHintSnapshot.self, "SignRecoveryHint")
        let stockPositionsSnap: [StockPositionSnapshot]
        if manifest.schemaVersion >= 3 {
            stockPositionsSnap = try loadJSON(StockPositionSnapshot.self, "StockPosition")
        } else {
            stockPositionsSnap = try loadOptionalJSON(StockPositionSnapshot.self, "StockPosition")
        }

        let existingAccounts = try context.fetch(FetchDescriptor<Account>())
        let existingBalanceSnapshots = try context.fetch(FetchDescriptor<AccountBalanceSnapshot>())
        let existingStatements = try context.fetch(FetchDescriptor<Statement>())
        let existingCategories = try context.fetch(FetchDescriptor<Category>())
        let existingCategoryRules = try context.fetch(FetchDescriptor<CategoryRule>())
        let existingInstallmentPlans = try context.fetch(FetchDescriptor<InstallmentPlan>())
        let existingTransactions = try context.fetch(FetchDescriptor<Transaction>())
        let existingPendingImports = try context.fetch(FetchDescriptor<PendingImport>())
        let existingSignRecoveryHints = try context.fetch(FetchDescriptor<SignRecoveryHint>())
        let existingStockPositions = try context.fetch(FetchDescriptor<StockPosition>())

        var accountMap = indexByID(existingAccounts, keyPath: \Account.id)
        var balanceSnapshotMap = indexByID(existingBalanceSnapshots, keyPath: \AccountBalanceSnapshot.id)
        var statementMap = indexByID(existingStatements, keyPath: \Statement.id)
        var categoryMap = indexByID(existingCategories, keyPath: \Category.id)
        var categoryRuleMap = indexByID(existingCategoryRules, keyPath: \CategoryRule.id)
        var installmentPlanMap = indexByID(existingInstallmentPlans, keyPath: \InstallmentPlan.id)
        var transactionMap = indexByID(existingTransactions, keyPath: \Transaction.id)
        var pendingImportMap = indexByID(existingPendingImports, keyPath: \PendingImport.id)
        var signRecoveryHintMap = indexByID(existingSignRecoveryHints, keyPath: \SignRecoveryHint.id)
        var stockPositionMap = indexByID(existingStockPositions, keyPath: \StockPosition.id)

        func resolveOrInsertAccount(_ id: UUID, _ snap: AccountSnapshot) -> Account {
            if let existing = accountMap[id] {
                if case .mergeKeepingNewer = strategy, snap.lastModifiedAt > existing.lastModifiedAt {
                    existing.apply(snap)
                }
                return existing
            }
            let obj = Account(snap)
            context.insert(obj)
            accountMap[id] = obj
            return obj
        }

        func resolveOrInsertBalanceSnapshot(_ id: UUID, _ snap: AccountBalanceSnapshotSnapshot) -> AccountBalanceSnapshot {
            if let existing = balanceSnapshotMap[id] {
                if case .mergeKeepingNewer = strategy, snap.lastModifiedAt > existing.lastModifiedAt {
                    existing.apply(snap)
                }
                return existing
            }
            let obj = AccountBalanceSnapshot(snap)
            context.insert(obj)
            balanceSnapshotMap[id] = obj
            return obj
        }

        func resolveOrInsertStatement(_ id: UUID, _ snap: StatementSnapshot) -> Statement {
            if let existing = statementMap[id] {
                if case .mergeKeepingNewer = strategy, snap.lastModifiedAt > existing.lastModifiedAt {
                    existing.apply(snap)
                }
                return existing
            }
            let obj = Statement(snap)
            context.insert(obj)
            statementMap[id] = obj
            return obj
        }

        func resolveOrInsertCategory(_ id: UUID, _ snap: CategorySnapshot) -> Category {
            if let existing = categoryMap[id] {
                if case .mergeKeepingNewer = strategy, snap.lastModifiedAt > existing.lastModifiedAt {
                    existing.apply(snap)
                }
                return existing
            }
            let obj = Category(snap)
            context.insert(obj)
            categoryMap[id] = obj
            return obj
        }

        func resolveOrInsertCategoryRule(_ id: UUID, _ snap: CategoryRuleSnapshot) -> CategoryRule {
            if let existing = categoryRuleMap[id] {
                if case .mergeKeepingNewer = strategy, snap.lastModifiedAt > existing.lastModifiedAt {
                    existing.apply(snap)
                }
                return existing
            }
            let obj = CategoryRule(snap)
            context.insert(obj)
            categoryRuleMap[id] = obj
            return obj
        }

        func resolveOrInsertInstallmentPlan(_ id: UUID, _ snap: InstallmentPlanSnapshot) -> InstallmentPlan {
            if let existing = installmentPlanMap[id] {
                if case .mergeKeepingNewer = strategy, snap.lastModifiedAt > existing.lastModifiedAt {
                    existing.apply(snap)
                }
                return existing
            }
            let obj = InstallmentPlan(snap)
            context.insert(obj)
            installmentPlanMap[id] = obj
            return obj
        }

        func resolveOrInsertTransaction(_ id: UUID, _ snap: TransactionSnapshot) -> Transaction {
            if let existing = transactionMap[id] {
                if case .mergeKeepingNewer = strategy, snap.lastModifiedAt > existing.lastModifiedAt {
                    existing.apply(snap)
                }
                return existing
            }
            let obj = Transaction(snap)
            context.insert(obj)
            transactionMap[id] = obj
            return obj
        }

        func resolveOrInsertPendingImport(_ id: UUID, _ snap: PendingImportSnapshot) -> PendingImport {
            if let existing = pendingImportMap[id] {
                if case .mergeKeepingNewer = strategy, snap.lastModifiedAt > existing.lastModifiedAt {
                    existing.apply(snap)
                }
                return existing
            }
            let obj = PendingImport(snap)
            context.insert(obj)
            pendingImportMap[id] = obj
            return obj
        }

        func resolveOrInsertSignRecoveryHint(_ id: UUID, _ snap: SignRecoveryHintSnapshot) -> SignRecoveryHint {
            if let existing = signRecoveryHintMap[id] {
                if case .mergeKeepingNewer = strategy, snap.lastModifiedAt > existing.lastModifiedAt {
                    existing.apply(snap)
                }
                return existing
            }
            let obj = SignRecoveryHint(snap)
            context.insert(obj)
            signRecoveryHintMap[id] = obj
            return obj
        }

        func resolveOrInsertStockPosition(_ id: UUID, _ snap: StockPositionSnapshot) -> StockPosition {
            if let existing = stockPositionMap[id] {
                if case .mergeKeepingNewer = strategy {
                    if snap.lastModifiedAt > existing.lastModifiedAt {
                        existing.emisoraSerie = snap.emisoraSerie
                        existing.name = snap.name
                        existing.shares = snap.shares
                        existing.averageCost = snap.averageCost
                        existing.lastModifiedAt = snap.lastModifiedAt
                    }
                    if let snapAt = snap.lastPriceAt {
                        let shouldUpdatePrice: Bool
                        if let existingAt = existing.lastPriceAt {
                            shouldUpdatePrice = snapAt > existingAt
                        } else {
                            shouldUpdatePrice = true
                        }
                        if shouldUpdatePrice {
                            existing.lastPrice = snap.lastPrice
                            existing.lastPriceAt = snapAt
                        }
                    }
                } else {
                    existing.apply(snap)
                }
                return existing
            }
            let obj = StockPosition(snap)
            context.insert(obj)
            stockPositionMap[id] = obj
            return obj
        }

        for snap in accountsSnap { _ = resolveOrInsertAccount(snap.id, snap) }
        for snap in balanceSnapshotsSnap { _ = resolveOrInsertBalanceSnapshot(snap.id, snap) }
        for snap in categoriesSnap { _ = resolveOrInsertCategory(snap.id, snap) }
        for snap in statementsSnap { _ = resolveOrInsertStatement(snap.id, snap) }
        for snap in categoryRulesSnap { _ = resolveOrInsertCategoryRule(snap.id, snap) }
        for snap in installmentPlansSnap { _ = resolveOrInsertInstallmentPlan(snap.id, snap) }
        for snap in transactionsSnap { _ = resolveOrInsertTransaction(snap.id, snap) }
        for snap in pendingImportsSnap { _ = resolveOrInsertPendingImport(snap.id, snap) }
        for snap in signRecoveryHintsSnap { _ = resolveOrInsertSignRecoveryHint(snap.id, snap) }
        for snap in stockPositionsSnap { _ = resolveOrInsertStockPosition(snap.id, snap) }

        for snap in accountsSnap {
            guard let obj = accountMap[snap.id] else { continue }
            if case .replaceAll = strategy { obj.lastModifiedAt = snap.lastModifiedAt }
        }
        for snap in balanceSnapshotsSnap {
            guard let obj = balanceSnapshotMap[snap.id] else { continue }
            obj.account = snap.accountId.flatMap { accountMap[$0] }
            if case .replaceAll = strategy { obj.lastModifiedAt = snap.lastModifiedAt }
        }
        for snap in categoriesSnap {
            guard let obj = categoryMap[snap.id] else { continue }
            obj.parent = snap.parentId.flatMap { categoryMap[$0] }
            if case .replaceAll = strategy { obj.lastModifiedAt = snap.lastModifiedAt }
        }
        for snap in statementsSnap {
            guard let obj = statementMap[snap.id] else { continue }
            obj.account = snap.accountId.flatMap { accountMap[$0] }
            if case .replaceAll = strategy { obj.lastModifiedAt = snap.lastModifiedAt }
        }
        for snap in categoryRulesSnap {
            guard let obj = categoryRuleMap[snap.id] else { continue }
            obj.category = snap.categoryId.flatMap { categoryMap[$0] }
            if case .replaceAll = strategy { obj.lastModifiedAt = snap.lastModifiedAt }
        }
        for snap in installmentPlansSnap {
            guard let obj = installmentPlanMap[snap.id] else { continue }
            obj.account = snap.accountId.flatMap { accountMap[$0] }
            obj.originalPurchase = snap.originalPurchaseId.flatMap { transactionMap[$0] }
            obj.installments = snap.installmentsIds.compactMap { transactionMap[$0] }
            if case .replaceAll = strategy { obj.lastModifiedAt = snap.lastModifiedAt }
        }
        for snap in transactionsSnap {
            guard let obj = transactionMap[snap.id] else { continue }
            obj.account = snap.accountId.flatMap { accountMap[$0] }
            obj.statement = snap.statementId.flatMap { statementMap[$0] }
            obj.category = snap.categoryId.flatMap { categoryMap[$0] }
            obj.installmentPlan = snap.installmentPlanId.flatMap { installmentPlanMap[$0] }
            if obj.movementKindRaw == nil {
                obj.movementKindRaw = Transaction.movementKind(from: obj.flowKind, amount: obj.amount, isTransfer: obj.isTransfer).rawValue
            }
            if obj.treatmentKindRaw == nil {
                obj.treatmentKindRaw = inferredBackupTreatmentKind(obj).rawValue
            }
            if case .replaceAll = strategy { obj.lastModifiedAt = snap.lastModifiedAt }
        }
        for snap in pendingImportsSnap {
            guard let obj = pendingImportMap[snap.id] else { continue }
            obj.account = snap.accountId.flatMap { accountMap[$0] }
            obj.statement = snap.statementId.flatMap { statementMap[$0] }
            obj.resolvedTransaction = snap.resolvedTransactionId.flatMap { transactionMap[$0] }
            if case .replaceAll = strategy { obj.lastModifiedAt = snap.lastModifiedAt }
        }
        for snap in stockPositionsSnap {
            guard let obj = stockPositionMap[snap.id] else { continue }
            obj.account = snap.accountId.flatMap { accountMap[$0] }
            if case .replaceAll = strategy { obj.lastModifiedAt = snap.lastModifiedAt }
        }

        try context.save()

        let statementsSource = bundleURL.appendingPathComponent(statementsSubdirectory)
        if fm.fileExists(atPath: statementsSource.path) {
            let appSupport = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            let dest = appSupport.appendingPathComponent("FinanceTracker/Statements")
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            let enumerator = fm.enumerator(at: statementsSource, includingPropertiesForKeys: nil)
            while let file = enumerator?.nextObject() as? URL {
                let relative = file.path.replacingOccurrences(of: statementsSource.path + "/", with: "")
                let target = dest.appendingPathComponent(relative)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !fm.fileExists(atPath: target.path) {
                    try fm.copyItem(at: file, to: target)
                }
            }
        }
    }

    private static func deleteAll(from context: ModelContext) throws {
        try AppDataResetService.deletePersistentModels(from: context)
    }

    private static func indexByID<T>(_ items: [T], keyPath: KeyPath<T, UUID>) -> [UUID: T] {
        var map: [UUID: T] = [:]
        for item in items {
            map[item[keyPath: keyPath]] = item
        }
        return map
    }

    private static func inferredBackupTreatmentKind(_ transaction: Transaction) -> TransactionTreatmentKind {
        guard transaction.account?.type == .retirement else { return .regular }
        let text = "\(transaction.descriptionRaw) \(transaction.category?.name ?? "")".lowercased()
        if ["interest", "return", "yield", "gain", "rendimiento", "interes"].contains(where: { text.contains($0) }) {
            return .investmentReturn
        }
        switch transaction.account?.retirementKind ?? .other {
        case .ppr:
            return .retirementContributionUserFunded
        case .afore:
            return .statutoryRetirementContribution
        case .employerRetirementPlan:
            return .retirementContributionEmployerFunded
        case .other:
            return .retirementContributionUserFunded
        }
    }
}

private enum RestoreError: LocalizedError {
    case unsupportedSchema(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let v): "Unsupported backup schema version: \(v)"
        }
    }
}

extension Account {
    convenience init(_ snap: AccountSnapshot) {
        self.init(
            id: snap.id,
            institution: snap.institution,
            type: AccountType(rawValue: snap.type) ?? .other,
            currency: snap.currency,
            nickname: snap.nickname,
            accountNumber: snap.accountNumber,
            openedAt: snap.openedAt,
            closedAt: snap.closedAt,
            creditLimit: snap.creditLimit,
            statementDayOfMonth: snap.statementDayOfMonth,
            paymentDayOfMonth: snap.paymentDayOfMonth,
            tintHex: snap.tintHex,
            manuallyCreatedAt: snap.manuallyCreatedAt,
            retirementKindRaw: snap.retirementKindRaw,
            liquidityRaw: snap.liquidityRaw,
            includeInNetWorth: snap.includeInNetWorth,
            includeInCashFlow: snap.includeInCashFlow,
            includeInRegularIncome: snap.includeInRegularIncome,
            taxTrackingEnabled: snap.taxTrackingEnabled
        )
        applyBackupMetadataDefaults(from: snap)
    }

    func apply(_ snap: AccountSnapshot) {
        institution = snap.institution
        type = AccountType(rawValue: snap.type) ?? .other
        currency = snap.currency
        nickname = snap.nickname
        accountNumber = snap.accountNumber
        openedAt = snap.openedAt
        closedAt = snap.closedAt
        creditLimit = snap.creditLimit
        statementDayOfMonth = snap.statementDayOfMonth
        paymentDayOfMonth = snap.paymentDayOfMonth
        tintHex = snap.tintHex
        manuallyCreatedAt = snap.manuallyCreatedAt
        applyBackupMetadataDefaults(from: snap)
        lastModifiedAt = snap.lastModifiedAt
    }

    private func applyBackupMetadataDefaults(from snap: AccountSnapshot) {
        let kind = snap.retirementKindRaw.flatMap(RetirementKind.init(rawValue:)) ?? inferredBackupRetirementKind
        retirementKindRaw = kind?.rawValue
        liquidityRaw = snap.liquidityRaw ?? Account.defaultLiquidity(type: type, retirementKind: kind).rawValue
        includeInNetWorth = snap.includeInNetWorth ?? true
        includeInCashFlow = snap.includeInCashFlow ?? (type == .retirement ? false : true)
        includeInRegularIncome = snap.includeInRegularIncome ?? (type == .retirement ? false : true)
        taxTrackingEnabled = snap.taxTrackingEnabled ?? (kind == .ppr)
    }

    private var inferredBackupRetirementKind: RetirementKind? {
        guard type == .retirement else { return nil }
        let text = "\(institution) \(nickname) \(accountNumber ?? "")".lowercased()
        if text.contains("ppr") { return .ppr }
        if text.contains("afore") { return .afore }
        if text.contains("employer") || text.contains("empresa") || text.contains("plan") {
            return .employerRetirementPlan
        }
        return .other
    }
}

extension AccountSnapshot {
    init(_ account: Account) {
        self.init(
            id: account.id,
            institution: account.institution,
            type: account.type.rawValue,
            currency: account.currency,
            nickname: account.nickname,
            accountNumber: account.accountNumber,
            openedAt: account.openedAt,
            closedAt: account.closedAt,
            creditLimit: account.creditLimit,
            statementDayOfMonth: account.statementDayOfMonth,
            paymentDayOfMonth: account.paymentDayOfMonth,
            tintHex: account.tintHex,
            manuallyCreatedAt: account.manuallyCreatedAt,
            retirementKindRaw: account.retirementKindRaw,
            liquidityRaw: account.liquidityRaw,
            includeInNetWorth: account.includeInNetWorth,
            includeInCashFlow: account.includeInCashFlow,
            includeInRegularIncome: account.includeInRegularIncome,
            taxTrackingEnabled: account.taxTrackingEnabled,
            lastModifiedAt: account.lastModifiedAt
        )
    }
}

extension AccountBalanceSnapshot {
    convenience init(_ snap: AccountBalanceSnapshotSnapshot) {
        self.init(
            id: snap.id,
            date: snap.date,
            amount: snap.amount,
            kind: AccountBalanceSnapshotKind(rawValue: snap.kind) ?? .manualAdjustment,
            note: snap.note,
            createdAt: snap.createdAt
        )
        lastModifiedAt = snap.lastModifiedAt
    }

    func apply(_ snap: AccountBalanceSnapshotSnapshot) {
        date = snap.date
        amount = snap.amount
        kind = AccountBalanceSnapshotKind(rawValue: snap.kind) ?? .manualAdjustment
        note = snap.note
        createdAt = snap.createdAt
        lastModifiedAt = snap.lastModifiedAt
    }
}

extension AccountBalanceSnapshotSnapshot {
    init(_ snapshot: AccountBalanceSnapshot) {
        self.init(
            id: snapshot.id,
            accountId: snapshot.account?.id,
            date: snapshot.date,
            amount: snapshot.amount,
            kind: snapshot.kind.rawValue,
            note: snapshot.note,
            createdAt: snapshot.createdAt,
            lastModifiedAt: snapshot.lastModifiedAt
        )
    }
}

extension StockPosition {
    convenience init(_ snap: StockPositionSnapshot) {
        self.init(
            id: snap.id,
            emisoraSerie: snap.emisoraSerie,
            name: snap.name,
            shares: snap.shares,
            averageCost: snap.averageCost,
            lastPrice: snap.lastPrice,
            lastPriceAt: snap.lastPriceAt,
            createdAt: snap.createdAt
        )
        lastModifiedAt = snap.lastModifiedAt
    }

    func apply(_ snap: StockPositionSnapshot) {
        emisoraSerie = snap.emisoraSerie
        name = snap.name
        shares = snap.shares
        averageCost = snap.averageCost
        lastPrice = snap.lastPrice
        lastPriceAt = snap.lastPriceAt
        createdAt = snap.createdAt
        lastModifiedAt = snap.lastModifiedAt
    }
}

extension StockPositionSnapshot {
    init(_ position: StockPosition) {
        self.init(
            id: position.id,
            accountId: position.account?.id,
            emisoraSerie: position.emisoraSerie,
            name: position.name,
            shares: position.shares,
            averageCost: position.averageCost,
            lastPrice: position.lastPrice,
            lastPriceAt: position.lastPriceAt,
            createdAt: position.createdAt,
            lastModifiedAt: position.lastModifiedAt
        )
    }
}

extension Statement {
    convenience init(_ snap: StatementSnapshot) {
        self.init(
            id: snap.id,
            periodStart: snap.periodStart,
            periodEnd: snap.periodEnd,
            sourceFileHash: snap.sourceFileHash,
            sourceFileName: snap.sourceFileName,
            sourceArchivedPath: snap.sourceArchivedPath,
            importedAt: snap.importedAt,
            ocrUsed: snap.ocrUsed,
            openingBalance: snap.openingBalance,
            closingBalance: snap.closingBalance,
            minimumPayment: snap.minimumPayment,
            paymentForNoInterest: snap.paymentForNoInterest,
            paymentDueDate: snap.paymentDueDate,
            interestCharged: snap.interestCharged,
            feesCharged: snap.feesCharged,
            ivaCharged: snap.ivaCharged
        )
    }

    func apply(_ snap: StatementSnapshot) {
        periodStart = snap.periodStart
        periodEnd = snap.periodEnd
        sourceFileHash = snap.sourceFileHash
        sourceFileName = snap.sourceFileName
        sourceArchivedPath = snap.sourceArchivedPath
        importedAt = snap.importedAt
        ocrUsed = snap.ocrUsed
        openingBalance = snap.openingBalance
        closingBalance = snap.closingBalance
        minimumPayment = snap.minimumPayment
        paymentForNoInterest = snap.paymentForNoInterest
        paymentDueDate = snap.paymentDueDate
        interestCharged = snap.interestCharged
        feesCharged = snap.feesCharged
        ivaCharged = snap.ivaCharged
        lastModifiedAt = snap.lastModifiedAt
    }
}

extension StatementSnapshot {
    init(_ statement: Statement) {
        self.init(
            id: statement.id,
            accountId: statement.account?.id,
            periodStart: statement.periodStart,
            periodEnd: statement.periodEnd,
            sourceFileHash: statement.sourceFileHash,
            sourceFileName: statement.sourceFileName,
            sourceArchivedPath: statement.sourceArchivedPath,
            importedAt: statement.importedAt,
            ocrUsed: statement.ocrUsed,
            openingBalance: statement.openingBalance,
            closingBalance: statement.closingBalance,
            minimumPayment: statement.minimumPayment,
            paymentForNoInterest: statement.paymentForNoInterest,
            paymentDueDate: statement.paymentDueDate,
            interestCharged: statement.interestCharged,
            feesCharged: statement.feesCharged,
            ivaCharged: statement.ivaCharged,
            lastModifiedAt: statement.lastModifiedAt
        )
    }
}

extension Transaction {
    convenience init(_ snap: TransactionSnapshot) {
        self.init(
            id: snap.id,
            postedAt: snap.postedAt,
            amount: snap.amount,
            currency: snap.currency,
            descriptionRaw: snap.descriptionRaw,
            merchantNormalized: snap.merchantNormalized,
            fxRateToBase: snap.fxRateToBase,
            isTransfer: snap.isTransfer,
            isDuplicate: snap.isDuplicate,
            cardLast4: snap.cardLast4,
            source: snap.source.flatMap { TransactionSource(rawValue: $0) } ?? .imported,
            transferGroupID: snap.transferGroupID,
            flowKindRaw: snap.flowKindRaw,
            movementKindRaw: snap.movementKindRaw,
            treatmentKindRaw: snap.treatmentKindRaw
        )
        deletedAt = snap.deletedAt
    }

    func apply(_ snap: TransactionSnapshot) {
        postedAt = snap.postedAt
        amount = snap.amount
        currency = snap.currency
        descriptionRaw = snap.descriptionRaw
        merchantNormalized = snap.merchantNormalized
        fxRateToBase = snap.fxRateToBase
        isTransfer = snap.isTransfer
        isDuplicate = snap.isDuplicate
        cardLast4 = snap.cardLast4
        source = snap.source.flatMap { TransactionSource(rawValue: $0) } ?? .imported
        transferGroupID = snap.transferGroupID
        flowKindRaw = snap.flowKindRaw
        movementKindRaw = snap.movementKindRaw
        treatmentKindRaw = snap.treatmentKindRaw
        deletedAt = snap.deletedAt
        lastModifiedAt = snap.lastModifiedAt
    }
}

extension TransactionSnapshot {
    init(_ transaction: Transaction) {
        self.init(
            id: transaction.id,
            accountId: transaction.account?.id,
            statementId: transaction.statement?.id,
            postedAt: transaction.postedAt,
            amount: transaction.amount,
            currency: transaction.currency,
            descriptionRaw: transaction.descriptionRaw,
            merchantNormalized: transaction.merchantNormalized,
            categoryId: transaction.category?.id,
            fxRateToBase: transaction.fxRateToBase,
            isTransfer: transaction.isTransfer,
            isDuplicate: transaction.isDuplicate,
            cardLast4: transaction.cardLast4,
            source: transaction.source.rawValue,
            transferGroupID: transaction.transferGroupID,
            installmentPlanId: transaction.installmentPlan?.id,
            flowKindRaw: transaction.flowKindRaw,
            movementKindRaw: transaction.movementKindRaw,
            treatmentKindRaw: transaction.treatmentKindRaw,
            lastModifiedAt: transaction.lastModifiedAt,
            deletedAt: transaction.deletedAt
        )
    }
}

extension Category {
    convenience init(_ snap: CategorySnapshot) {
        self.init(
            id: snap.id,
            name: snap.name,
            kind: CategoryKind(rawValue: snap.kind) ?? .expense
        )
    }

    func apply(_ snap: CategorySnapshot) {
        name = snap.name
        kind = CategoryKind(rawValue: snap.kind) ?? .expense
        deletedAt = snap.deletedAt
        lastModifiedAt = snap.lastModifiedAt
    }
}

extension CategorySnapshot {
    init(_ category: Category) {
        self.init(
            id: category.id,
            name: category.name,
            parentId: category.parent?.id,
            kind: category.kind.rawValue,
            deletedAt: category.deletedAt,
            lastModifiedAt: category.lastModifiedAt
        )
    }
}

extension CategoryRule {
    convenience init(_ snap: CategoryRuleSnapshot) {
        self.init(
            id: snap.id,
            patternRegex: snap.patternRegex,
            merchantMatch: snap.merchantMatch,
            priority: snap.priority,
            source: snap.source,
            matchCount: snap.matchCount,
            createdFrom: snap.createdFrom
        )
    }

    func apply(_ snap: CategoryRuleSnapshot) {
        patternRegex = snap.patternRegex
        merchantMatch = snap.merchantMatch
        priority = snap.priority
        source = snap.source
        matchCount = snap.matchCount
        createdFrom = snap.createdFrom
        lastModifiedAt = snap.lastModifiedAt
    }
}

extension CategoryRuleSnapshot {
    init(_ rule: CategoryRule) {
        self.init(
            id: rule.id,
            patternRegex: rule.patternRegex,
            merchantMatch: rule.merchantMatch,
            categoryId: rule.category?.id,
            priority: rule.priority,
            source: rule.source,
            matchCount: rule.matchCount,
            createdFrom: rule.createdFrom,
            lastModifiedAt: rule.lastModifiedAt
        )
    }
}

extension InstallmentPlan {
    convenience init(_ snap: InstallmentPlanSnapshot) {
        self.init(
            id: snap.id,
            originalAmount: snap.originalAmount,
            totalMonths: snap.totalMonths,
            currentMonth: snap.currentMonth,
            monthlyAmount: snap.monthlyAmount,
            ratePercent: snap.ratePercent,
            firstChargeDate: snap.firstChargeDate,
            merchantDescription: snap.merchantDescription
        )
    }

    func apply(_ snap: InstallmentPlanSnapshot) {
        originalAmount = snap.originalAmount
        totalMonths = snap.totalMonths
        currentMonth = snap.currentMonth
        monthlyAmount = snap.monthlyAmount
        ratePercent = snap.ratePercent
        firstChargeDate = snap.firstChargeDate
        merchantDescription = snap.merchantDescription
        lastModifiedAt = snap.lastModifiedAt
    }
}

extension InstallmentPlanSnapshot {
    init(_ plan: InstallmentPlan) {
        self.init(
            id: plan.id,
            accountId: plan.account?.id,
            originalPurchaseId: plan.originalPurchase?.id,
            installmentsIds: plan.installments.map(\.id),
            originalAmount: plan.originalAmount,
            totalMonths: plan.totalMonths,
            currentMonth: plan.currentMonth,
            monthlyAmount: plan.monthlyAmount,
            ratePercent: plan.ratePercent,
            firstChargeDate: plan.firstChargeDate,
            merchantDescription: plan.merchantDescription,
            lastModifiedAt: plan.lastModifiedAt
        )
    }
}

extension PendingImport {
    convenience init(_ snap: PendingImportSnapshot) {
        self.init(
            id: snap.id,
            rawText: snap.rawText,
            reason: snap.reason,
            parsedDate: snap.parsedDate,
            parsedAmount: snap.parsedAmount,
            parsedDescription: snap.parsedDescription,
            cardLast4: snap.cardLast4,
            createdAt: snap.createdAt,
            matchedDeletedTransactionId: snap.matchedDeletedTransactionId
        )
    }

    func apply(_ snap: PendingImportSnapshot) {
        rawText = snap.rawText
        reason = snap.reason
        parsedDate = snap.parsedDate
        parsedAmount = snap.parsedAmount
        parsedDescription = snap.parsedDescription
        cardLast4 = snap.cardLast4
        createdAt = snap.createdAt
        matchedDeletedTransactionId = snap.matchedDeletedTransactionId
        lastModifiedAt = snap.lastModifiedAt
    }
}

extension PendingImportSnapshot {
    init(_ pending: PendingImport) {
        self.init(
            id: pending.id,
            accountId: pending.account?.id,
            statementId: pending.statement?.id,
            rawText: pending.rawText,
            reason: pending.reason,
            parsedDate: pending.parsedDate,
            parsedAmount: pending.parsedAmount,
            parsedDescription: pending.parsedDescription,
            cardLast4: pending.cardLast4,
            resolvedTransactionId: pending.resolvedTransaction?.id,
            createdAt: pending.createdAt,
            lastModifiedAt: pending.lastModifiedAt,
            matchedDeletedTransactionId: pending.matchedDeletedTransactionId
        )
    }
}

extension SignRecoveryHint {
    convenience init(_ snap: SignRecoveryHintSnapshot) {
        self.init(
            id: snap.id,
            pattern: snap.pattern,
            implicitSign: snap.implicitSign,
            source: snap.source,
            createdFrom: snap.createdFrom,
            matchCount: snap.matchCount
        )
    }

    func apply(_ snap: SignRecoveryHintSnapshot) {
        pattern = snap.pattern
        implicitSign = snap.implicitSign
        source = snap.source
        createdFrom = snap.createdFrom
        matchCount = snap.matchCount
        lastModifiedAt = snap.lastModifiedAt
    }
}

extension SignRecoveryHintSnapshot {
    init(_ hint: SignRecoveryHint) {
        self.init(
            id: hint.id,
            pattern: hint.pattern,
            implicitSign: hint.implicitSign,
            source: hint.source,
            createdFrom: hint.createdFrom,
            matchCount: hint.matchCount,
            lastModifiedAt: hint.lastModifiedAt
        )
    }
}

#endif
