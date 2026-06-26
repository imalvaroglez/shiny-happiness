import Foundation
import SwiftData

enum FinanceTrackerSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(0, 4, 0)
    static var models: [any PersistentModel.Type] {
        [
            Account.self,
            AccountBalanceSnapshot.self,
            Transaction.self,
            Statement.self,
            Category.self,
            CategoryRule.self,
            InstallmentPlan.self,
            PendingImport.self,
            SignRecoveryHint.self,
        ]
    }

    @Model final class Account {
        var id: UUID
        var institution: String
        var type: AccountType
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
        var lastModifiedAt: Date = Date.now

        init(id: UUID = UUID(), institution: String, type: AccountType, currency: String = "MXN", nickname: String? = nil, accountNumber: String? = nil, openedAt: Date = .now, closedAt: Date? = nil, creditLimit: Decimal? = nil, statementDayOfMonth: Int? = nil, paymentDayOfMonth: Int? = nil, tintHex: String? = nil, manuallyCreatedAt: Date? = nil) {
            self.id = id; self.institution = institution; self.type = type; self.currency = currency
            self.nickname = nickname ?? institution; self.accountNumber = accountNumber; self.openedAt = openedAt
            self.closedAt = closedAt; self.creditLimit = creditLimit; self.statementDayOfMonth = statementDayOfMonth
            self.paymentDayOfMonth = paymentDayOfMonth; self.tintHex = tintHex; self.manuallyCreatedAt = manuallyCreatedAt
        }
    }

    @Model final class AccountBalanceSnapshot {
        var id: UUID
        @Relationship(deleteRule: .nullify) var account: Account?
        var date: Date
        var amount: Decimal
        var kind: AccountBalanceSnapshotKind
        var note: String?
        var createdAt: Date
        var lastModifiedAt: Date = Date.now

        init(id: UUID = UUID(), account: Account? = nil, date: Date, amount: Decimal, kind: AccountBalanceSnapshotKind, note: String? = nil, createdAt: Date = .now) {
            self.id = id; self.account = account; self.date = date; self.amount = amount
            self.kind = kind; self.note = note; self.createdAt = createdAt
        }
    }

    @Model final class Transaction {
        var id: UUID
        @Relationship(deleteRule: .nullify) var account: Account?
        @Relationship(deleteRule: .nullify) var statement: Statement?
        var postedAt: Date
        var amount: Decimal
        var currency: String
        var descriptionRaw: String
        var merchantNormalized: String
        @Relationship(deleteRule: .nullify) var category: Category?
        var fxRateToBase: Decimal
        var isTransfer: Bool
        var isDuplicate: Bool
        var cardLast4: String?
        var source: TransactionSource
        var transferGroupID: UUID?
        @Relationship(deleteRule: .nullify, inverse: \InstallmentPlan.installments) var installmentPlan: InstallmentPlan?
        var flowKindRaw: String? = nil
        var lastModifiedAt: Date = Date.now
        var deletedAt: Date? = nil

        init(id: UUID = UUID(), account: Account? = nil, statement: Statement? = nil, postedAt: Date, amount: Decimal, currency: String = "MXN", descriptionRaw: String, merchantNormalized: String = "", category: Category? = nil, fxRateToBase: Decimal = 1, isTransfer: Bool = false, isDuplicate: Bool = false, cardLast4: String? = nil, source: TransactionSource = .imported, transferGroupID: UUID? = nil, installmentPlan: InstallmentPlan? = nil, flowKindRaw: String? = nil) {
            self.id = id; self.account = account; self.statement = statement; self.postedAt = postedAt
            self.amount = amount; self.currency = currency; self.descriptionRaw = descriptionRaw
            self.merchantNormalized = merchantNormalized; self.category = category; self.fxRateToBase = fxRateToBase
            self.isTransfer = isTransfer; self.isDuplicate = isDuplicate; self.cardLast4 = cardLast4
            self.source = source; self.transferGroupID = transferGroupID; self.installmentPlan = installmentPlan
            self.flowKindRaw = flowKindRaw
        }
    }

    @Model final class Statement {
        var id: UUID
        @Relationship(deleteRule: .nullify) var account: Account?
        var periodStart: Date
        var periodEnd: Date
        var sourceFileHash: String
        var sourceFileName: String?
        var sourceArchivedPath: String?
        var importedAt: Date
        var ocrUsed: Bool
        var openingBalance: Decimal?
        var closingBalance: Decimal?
        var minimumPayment: Decimal?
        var paymentForNoInterest: Decimal?
        var paymentDueDate: Date?
        var interestCharged: Decimal?
        var feesCharged: Decimal?
        var ivaCharged: Decimal?
        @Relationship(deleteRule: .cascade, inverse: \Transaction.statement) var transactions: [Transaction] = []
        var lastModifiedAt: Date = Date.now

        init(id: UUID = UUID(), account: Account? = nil, periodStart: Date, periodEnd: Date, sourceFileHash: String, sourceFileName: String? = nil, sourceArchivedPath: String? = nil, importedAt: Date = .now, ocrUsed: Bool = false, openingBalance: Decimal? = nil, closingBalance: Decimal? = nil, minimumPayment: Decimal? = nil, paymentForNoInterest: Decimal? = nil, paymentDueDate: Date? = nil, interestCharged: Decimal? = nil, feesCharged: Decimal? = nil, ivaCharged: Decimal? = nil) {
            self.id = id; self.account = account; self.periodStart = periodStart; self.periodEnd = periodEnd
            self.sourceFileHash = sourceFileHash; self.sourceFileName = sourceFileName; self.sourceArchivedPath = sourceArchivedPath
            self.importedAt = importedAt; self.ocrUsed = ocrUsed; self.openingBalance = openingBalance
            self.closingBalance = closingBalance; self.minimumPayment = minimumPayment; self.paymentForNoInterest = paymentForNoInterest
            self.paymentDueDate = paymentDueDate; self.interestCharged = interestCharged; self.feesCharged = feesCharged; self.ivaCharged = ivaCharged
        }
    }

    @Model final class Category {
        var id: UUID
        var name: String
        @Relationship(deleteRule: .nullify) var parent: Category?
        var kind: CategoryKind
        @Relationship(deleteRule: .cascade) var subcategories: [Category] = []
        var deletedAt: Date? = nil
        var lastModifiedAt: Date = Date.now

        init(id: UUID = UUID(), name: String, parent: Category? = nil, kind: CategoryKind = .expense) {
            self.id = id; self.name = name; self.parent = parent; self.kind = kind
        }
    }

    @Model final class CategoryRule {
        var id: UUID
        var patternRegex: String
        var merchantMatch: String
        @Relationship(deleteRule: .nullify) var category: Category?
        var priority: Int
        var source: String
        var matchCount: Int
        var createdFrom: String?
        var lastModifiedAt: Date = Date.now

        init(id: UUID = UUID(), patternRegex: String, merchantMatch: String = "", category: Category? = nil, priority: Int = 0, source: String = "seed", matchCount: Int = 0, createdFrom: String? = nil) {
            self.id = id; self.patternRegex = patternRegex; self.merchantMatch = merchantMatch
            self.category = category; self.priority = priority; self.source = source
            self.matchCount = matchCount; self.createdFrom = createdFrom
        }
    }

    @Model final class InstallmentPlan {
        var id: UUID
        @Relationship(deleteRule: .nullify) var account: Account?
        @Relationship(deleteRule: .nullify) var originalPurchase: Transaction?
        @Relationship(deleteRule: .nullify) var installments: [Transaction] = []
        var originalAmount: Decimal
        var totalMonths: Int
        var currentMonth: Int
        var monthlyAmount: Decimal
        var ratePercent: Decimal
        var firstChargeDate: Date
        var merchantDescription: String
        var lastModifiedAt: Date = Date.now

        init(id: UUID = UUID(), account: Account? = nil, originalPurchase: Transaction? = nil, installments: [Transaction] = [], originalAmount: Decimal, totalMonths: Int, currentMonth: Int, monthlyAmount: Decimal, ratePercent: Decimal = 0, firstChargeDate: Date, merchantDescription: String) {
            self.id = id; self.account = account; self.originalPurchase = originalPurchase; self.installments = installments
            self.originalAmount = originalAmount; self.totalMonths = totalMonths; self.currentMonth = currentMonth
            self.monthlyAmount = monthlyAmount; self.ratePercent = ratePercent; self.firstChargeDate = firstChargeDate
            self.merchantDescription = merchantDescription
        }
    }

    @Model final class PendingImport {
        var id: UUID
        @Relationship(deleteRule: .nullify) var account: Account?
        @Relationship(deleteRule: .nullify) var statement: Statement?
        var rawText: String
        var reason: String
        var parsedDate: Date?
        var parsedAmount: Decimal?
        var parsedDescription: String?
        var cardLast4: String?
        @Relationship(deleteRule: .nullify) var resolvedTransaction: Transaction?
        var createdAt: Date
        var lastModifiedAt: Date = Date.now
        var matchedDeletedTransactionId: UUID?

        init(id: UUID = UUID(), account: Account? = nil, statement: Statement? = nil, rawText: String, reason: String, parsedDate: Date? = nil, parsedAmount: Decimal? = nil, parsedDescription: String? = nil, cardLast4: String? = nil, resolvedTransaction: Transaction? = nil, createdAt: Date = .now, matchedDeletedTransactionId: UUID? = nil) {
            self.id = id; self.account = account; self.statement = statement; self.rawText = rawText; self.reason = reason
            self.parsedDate = parsedDate; self.parsedAmount = parsedAmount; self.parsedDescription = parsedDescription
            self.cardLast4 = cardLast4; self.resolvedTransaction = resolvedTransaction; self.createdAt = createdAt
            self.matchedDeletedTransactionId = matchedDeletedTransactionId
        }
    }

    @Model final class SignRecoveryHint {
        var id: UUID = UUID()
        var pattern: String = ""
        var implicitSign: Int = 0
        var source: String = "user_correction"
        var createdFrom: String?
        var matchCount: Int = 0
        var lastModifiedAt: Date = Date.now

        init(id: UUID = UUID(), pattern: String, implicitSign: Int, source: String = "user_correction", createdFrom: String? = nil, matchCount: Int = 0) {
            self.id = id; self.pattern = pattern; self.implicitSign = implicitSign
            self.source = source; self.createdFrom = createdFrom; self.matchCount = matchCount
        }
    }
}

enum FinanceTrackerSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(0, 5, 0)
    static var models: [any PersistentModel.Type] {
        [
            Account.self,
            AccountBalanceSnapshot.self,
            Transaction.self,
            Statement.self,
            Category.self,
            CategoryRule.self,
            InstallmentPlan.self,
            PendingImport.self,
            SignRecoveryHint.self,
        ]
    }

    @Model final class Account {
        var id: UUID
        var institution: String
        var type: AccountType
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
        var retirementKindRaw: String?
        var liquidityRaw: String?
        var includeInNetWorth: Bool?
        var includeInCashFlow: Bool?
        var includeInRegularIncome: Bool?
        var taxTrackingEnabled: Bool?
        var lastModifiedAt: Date = Date.now

        init(id: UUID = UUID(), institution: String, type: AccountType, currency: String = "MXN", nickname: String? = nil, accountNumber: String? = nil, openedAt: Date = .now, closedAt: Date? = nil, creditLimit: Decimal? = nil, statementDayOfMonth: Int? = nil, paymentDayOfMonth: Int? = nil, tintHex: String? = nil, manuallyCreatedAt: Date? = nil, retirementKindRaw: String? = nil, liquidityRaw: String? = nil, includeInNetWorth: Bool? = nil, includeInCashFlow: Bool? = nil, includeInRegularIncome: Bool? = nil, taxTrackingEnabled: Bool? = nil) {
            self.id = id; self.institution = institution; self.type = type; self.currency = currency
            self.nickname = nickname ?? institution; self.accountNumber = accountNumber; self.openedAt = openedAt
            self.closedAt = closedAt; self.creditLimit = creditLimit; self.statementDayOfMonth = statementDayOfMonth
            self.paymentDayOfMonth = paymentDayOfMonth; self.tintHex = tintHex; self.manuallyCreatedAt = manuallyCreatedAt
            self.retirementKindRaw = retirementKindRaw; self.liquidityRaw = liquidityRaw
            self.includeInNetWorth = includeInNetWorth; self.includeInCashFlow = includeInCashFlow
            self.includeInRegularIncome = includeInRegularIncome; self.taxTrackingEnabled = taxTrackingEnabled
        }
    }

    @Model final class AccountBalanceSnapshot {
        var id: UUID
        @Relationship(deleteRule: .nullify) var account: Account?
        var date: Date
        var amount: Decimal
        var kind: AccountBalanceSnapshotKind
        var note: String?
        var createdAt: Date
        var lastModifiedAt: Date = Date.now

        init(id: UUID = UUID(), account: Account? = nil, date: Date, amount: Decimal, kind: AccountBalanceSnapshotKind, note: String? = nil, createdAt: Date = .now) {
            self.id = id; self.account = account; self.date = date; self.amount = amount
            self.kind = kind; self.note = note; self.createdAt = createdAt
        }
    }

    @Model final class Transaction {
        var id: UUID
        @Relationship(deleteRule: .nullify) var account: Account?
        @Relationship(deleteRule: .nullify) var statement: Statement?
        var postedAt: Date
        var amount: Decimal
        var currency: String
        var descriptionRaw: String
        var merchantNormalized: String
        @Relationship(deleteRule: .nullify) var category: Category?
        var fxRateToBase: Decimal
        var isTransfer: Bool
        var isDuplicate: Bool
        var cardLast4: String?
        var source: TransactionSource
        var transferGroupID: UUID?
        @Relationship(deleteRule: .nullify, inverse: \InstallmentPlan.installments) var installmentPlan: InstallmentPlan?
        var flowKindRaw: String? = nil
        var movementKindRaw: String?
        var treatmentKindRaw: String?
        var lastModifiedAt: Date = Date.now
        var deletedAt: Date? = nil

        init(id: UUID = UUID(), account: Account? = nil, statement: Statement? = nil, postedAt: Date, amount: Decimal, currency: String = "MXN", descriptionRaw: String, merchantNormalized: String = "", category: Category? = nil, fxRateToBase: Decimal = 1, isTransfer: Bool = false, isDuplicate: Bool = false, cardLast4: String? = nil, source: TransactionSource = .imported, transferGroupID: UUID? = nil, installmentPlan: InstallmentPlan? = nil, flowKindRaw: String? = nil, movementKindRaw: String? = nil, treatmentKindRaw: String? = nil) {
            self.id = id; self.account = account; self.statement = statement; self.postedAt = postedAt
            self.amount = amount; self.currency = currency; self.descriptionRaw = descriptionRaw
            self.merchantNormalized = merchantNormalized; self.category = category; self.fxRateToBase = fxRateToBase
            self.isTransfer = isTransfer; self.isDuplicate = isDuplicate; self.cardLast4 = cardLast4
            self.source = source; self.transferGroupID = transferGroupID; self.installmentPlan = installmentPlan
            self.flowKindRaw = flowKindRaw; self.movementKindRaw = movementKindRaw; self.treatmentKindRaw = treatmentKindRaw
        }
    }

    @Model final class Statement {
        var id: UUID
        @Relationship(deleteRule: .nullify) var account: Account?
        var periodStart: Date
        var periodEnd: Date
        var sourceFileHash: String
        var sourceFileName: String?
        var sourceArchivedPath: String?
        var importedAt: Date
        var ocrUsed: Bool
        var openingBalance: Decimal?
        var closingBalance: Decimal?
        var minimumPayment: Decimal?
        var paymentForNoInterest: Decimal?
        var paymentDueDate: Date?
        var interestCharged: Decimal?
        var feesCharged: Decimal?
        var ivaCharged: Decimal?
        @Relationship(deleteRule: .cascade, inverse: \Transaction.statement) var transactions: [Transaction] = []
        var lastModifiedAt: Date = Date.now

        init(id: UUID = UUID(), account: Account? = nil, periodStart: Date, periodEnd: Date, sourceFileHash: String, sourceFileName: String? = nil, sourceArchivedPath: String? = nil, importedAt: Date = .now, ocrUsed: Bool = false, openingBalance: Decimal? = nil, closingBalance: Decimal? = nil, minimumPayment: Decimal? = nil, paymentForNoInterest: Decimal? = nil, paymentDueDate: Date? = nil, interestCharged: Decimal? = nil, feesCharged: Decimal? = nil, ivaCharged: Decimal? = nil) {
            self.id = id; self.account = account; self.periodStart = periodStart; self.periodEnd = periodEnd
            self.sourceFileHash = sourceFileHash; self.sourceFileName = sourceFileName; self.sourceArchivedPath = sourceArchivedPath
            self.importedAt = importedAt; self.ocrUsed = ocrUsed; self.openingBalance = openingBalance
            self.closingBalance = closingBalance; self.minimumPayment = minimumPayment; self.paymentForNoInterest = paymentForNoInterest
            self.paymentDueDate = paymentDueDate; self.interestCharged = interestCharged; self.feesCharged = feesCharged; self.ivaCharged = ivaCharged
        }
    }

    @Model final class Category {
        var id: UUID
        var name: String
        @Relationship(deleteRule: .nullify) var parent: Category?
        var kind: CategoryKind
        @Relationship(deleteRule: .cascade) var subcategories: [Category] = []
        var deletedAt: Date? = nil
        var lastModifiedAt: Date = Date.now

        init(id: UUID = UUID(), name: String, parent: Category? = nil, kind: CategoryKind = .expense) {
            self.id = id; self.name = name; self.parent = parent; self.kind = kind
        }
    }

    @Model final class CategoryRule {
        var id: UUID
        var patternRegex: String
        var merchantMatch: String
        @Relationship(deleteRule: .nullify) var category: Category?
        var priority: Int
        var source: String
        var matchCount: Int
        var createdFrom: String?
        var lastModifiedAt: Date = Date.now

        init(id: UUID = UUID(), patternRegex: String, merchantMatch: String = "", category: Category? = nil, priority: Int = 0, source: String = "seed", matchCount: Int = 0, createdFrom: String? = nil) {
            self.id = id; self.patternRegex = patternRegex; self.merchantMatch = merchantMatch
            self.category = category; self.priority = priority; self.source = source
            self.matchCount = matchCount; self.createdFrom = createdFrom
        }
    }

    @Model final class InstallmentPlan {
        var id: UUID
        @Relationship(deleteRule: .nullify) var account: Account?
        @Relationship(deleteRule: .nullify) var originalPurchase: Transaction?
        @Relationship(deleteRule: .nullify) var installments: [Transaction] = []
        var originalAmount: Decimal
        var totalMonths: Int
        var currentMonth: Int
        var monthlyAmount: Decimal
        var ratePercent: Decimal
        var firstChargeDate: Date
        var merchantDescription: String
        var lastModifiedAt: Date = Date.now

        init(id: UUID = UUID(), account: Account? = nil, originalPurchase: Transaction? = nil, installments: [Transaction] = [], originalAmount: Decimal, totalMonths: Int, currentMonth: Int, monthlyAmount: Decimal, ratePercent: Decimal = 0, firstChargeDate: Date, merchantDescription: String) {
            self.id = id; self.account = account; self.originalPurchase = originalPurchase; self.installments = installments
            self.originalAmount = originalAmount; self.totalMonths = totalMonths; self.currentMonth = currentMonth
            self.monthlyAmount = monthlyAmount; self.ratePercent = ratePercent; self.firstChargeDate = firstChargeDate
            self.merchantDescription = merchantDescription
        }
    }

    @Model final class PendingImport {
        var id: UUID
        @Relationship(deleteRule: .nullify) var account: Account?
        @Relationship(deleteRule: .nullify) var statement: Statement?
        var rawText: String
        var reason: String
        var parsedDate: Date?
        var parsedAmount: Decimal?
        var parsedDescription: String?
        var cardLast4: String?
        @Relationship(deleteRule: .nullify) var resolvedTransaction: Transaction?
        var createdAt: Date
        var lastModifiedAt: Date = Date.now
        var matchedDeletedTransactionId: UUID?

        init(id: UUID = UUID(), account: Account? = nil, statement: Statement? = nil, rawText: String, reason: String, parsedDate: Date? = nil, parsedAmount: Decimal? = nil, parsedDescription: String? = nil, cardLast4: String? = nil, resolvedTransaction: Transaction? = nil, createdAt: Date = .now, matchedDeletedTransactionId: UUID? = nil) {
            self.id = id; self.account = account; self.statement = statement; self.rawText = rawText; self.reason = reason
            self.parsedDate = parsedDate; self.parsedAmount = parsedAmount; self.parsedDescription = parsedDescription
            self.cardLast4 = cardLast4; self.resolvedTransaction = resolvedTransaction; self.createdAt = createdAt
            self.matchedDeletedTransactionId = matchedDeletedTransactionId
        }
    }

    @Model final class SignRecoveryHint {
        var id: UUID = UUID()
        var pattern: String = ""
        var implicitSign: Int = 0
        var source: String = "user_correction"
        var createdFrom: String?
        var matchCount: Int = 0
        var lastModifiedAt: Date = Date.now

        init(id: UUID = UUID(), pattern: String, implicitSign: Int, source: String = "user_correction", createdFrom: String? = nil, matchCount: Int = 0) {
            self.id = id; self.pattern = pattern; self.implicitSign = implicitSign
            self.source = source; self.createdFrom = createdFrom; self.matchCount = matchCount
        }
    }
}

enum FinanceTrackerSchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(0, 6, 0)
    static var models: [any PersistentModel.Type] {
        [
            Account.self,
            AccountBalanceSnapshot.self,
            Transaction.self,
            Statement.self,
            Category.self,
            CategoryRule.self,
            InstallmentPlan.self,
            PendingImport.self,
            SignRecoveryHint.self,
            StockPosition.self,
        ]
    }
}

enum FinanceTrackerMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [FinanceTrackerSchemaV1.self, FinanceTrackerSchemaV2.self, FinanceTrackerSchemaV3.self]
    }

    static var stages: [MigrationStage] {
        [migrateV1toV2, migrateV2toV3]
    }

    private static let migrateV2toV3 = MigrationStage.custom(
        fromVersion: FinanceTrackerSchemaV2.self,
        toVersion: FinanceTrackerSchemaV3.self,
        willMigrate: nil,
        didMigrate: { context in
            let accounts = try context.fetch(FetchDescriptor<Account>())
            for account in accounts {
                backfillAccountMetadata(account)
            }

            let transactions = try context.fetch(FetchDescriptor<Transaction>())
            for transaction in transactions {
                backfillTransactionSemantics(transaction)
            }
            try context.save()
        }
    )

    private static let migrateV1toV2 = MigrationStage.custom(
        fromVersion: FinanceTrackerSchemaV1.self,
        toVersion: FinanceTrackerSchemaV2.self,
        willMigrate: nil,
        didMigrate: nil
    )

    private static func backfillAccountMetadata(_ account: Account) {
        let kind = account.retirementKind ?? inferredRetirementKind(account)
        if account.retirementKindRaw == nil {
            account.retirementKindRaw = kind?.rawValue
        }
        if account.liquidityRaw == nil {
            account.liquidityRaw = Account.defaultLiquidity(type: account.type, retirementKind: kind).rawValue
        }
        if account.includeInNetWorth == nil {
            account.includeInNetWorth = account.type == .other ? true : true
        }
        if account.includeInCashFlow == nil {
            account.includeInCashFlow = account.type == .retirement ? false : true
        }
        if account.includeInRegularIncome == nil {
            account.includeInRegularIncome = account.type == .retirement ? false : true
        }
        if account.taxTrackingEnabled == nil {
            account.taxTrackingEnabled = kind == .ppr
        }
    }

    private static func backfillTransactionSemantics(_ transaction: Transaction) {
        if transaction.movementKindRaw == nil {
            transaction.movementKindRaw = Transaction.movementKind(
                from: transaction.flowKind,
                amount: transaction.amount,
                isTransfer: transaction.isTransfer
            ).rawValue
        }
        if transaction.treatmentKindRaw == nil {
            transaction.treatmentKindRaw = inferredTreatmentKind(transaction).rawValue
        }
    }

    private static func inferredRetirementKind(_ account: Account) -> RetirementKind? {
        guard account.type == .retirement else { return nil }
        let text = "\(account.institution) \(account.nickname) \(account.accountNumber ?? "")".lowercased()
        if text.contains("ppr") { return .ppr }
        if text.contains("afore") { return .afore }
        if text.contains("employer") || text.contains("empresa") || text.contains("plan") {
            return .employerRetirementPlan
        }
        return .other
    }

    private static func inferredTreatmentKind(_ transaction: Transaction) -> TransactionTreatmentKind {
        guard transaction.account?.type == .retirement else {
            return clearlyValuationAdjustment(transaction) ? .valuationAdjustment : .regular
        }
        if clearlyInvestmentReturn(transaction) { return .investmentReturn }
        switch transaction.account?.retirementKind ?? inferredRetirementKind(transaction.account!) ?? .other {
        case .ppr:
            return .retirementContributionUserFunded
        case .afore:
            return .statutoryRetirementContribution
        case .employerRetirementPlan:
            return .retirementContributionEmployerFunded
        case .other:
            return clearlyValuationAdjustment(transaction) ? .valuationAdjustment : .retirementContributionUserFunded
        }
    }

    private static func clearlyInvestmentReturn(_ transaction: Transaction) -> Bool {
        let text = "\(transaction.descriptionRaw) \(transaction.category?.name ?? "")".lowercased()
        return ["interest", "return", "yield", "gain", "rendimiento", "interes"].contains { text.contains($0) }
    }

    private static func clearlyValuationAdjustment(_ transaction: Transaction) -> Bool {
        let text = "\(transaction.descriptionRaw) \(transaction.category?.name ?? "")".lowercased()
        return ["balance adjustment", "manual correction", "statement reconciliation", "valuation", "ajuste", "correccion"].contains { text.contains($0) }
    }
}

enum AppSchema {
    static var modelTypes: [any PersistentModel.Type] {
        [
            Account.self,
            AccountBalanceSnapshot.self,
            Transaction.self,
            Statement.self,
            Category.self,
            CategoryRule.self,
            InstallmentPlan.self,
            PendingImport.self,
            SignRecoveryHint.self,
            StockPosition.self,
        ]
    }

    static var schema: Schema {
        Schema(versionedSchema: FinanceTrackerSchemaV3.self)
    }

    static func makeContainer(isStoredInMemoryOnly: Bool = false) throws -> ModelContainer {
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: isStoredInMemoryOnly,
            groupContainer: .none,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: schema,
            migrationPlan: FinanceTrackerMigrationPlan.self,
            configurations: [config]
        )
    }
}
