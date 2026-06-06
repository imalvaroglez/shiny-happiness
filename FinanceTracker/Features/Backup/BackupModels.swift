import Foundation

#if os(macOS)

struct BackupManifest: Codable {
    var schemaVersion: Int
    var createdAt: Date
    var appVersion: String
    var modelCounts: [String: Int]
    var contentHashes: [String: String]
}

struct AccountSnapshot: Codable {
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

struct AccountBalanceSnapshotSnapshot: Codable {
    var id: UUID
    var accountId: UUID?
    var date: Date
    var amount: Decimal
    var kind: String
    var note: String?
    var createdAt: Date
    var lastModifiedAt: Date
}

struct TransactionSnapshot: Codable {
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

struct StatementSnapshot: Codable {
    var id: UUID
    var accountId: UUID?
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
    var lastModifiedAt: Date
}

struct CategorySnapshot: Codable {
    var id: UUID
    var name: String
    var parentId: UUID?
    var kind: String
    var deletedAt: Date?
    var lastModifiedAt: Date
}

struct CategoryRuleSnapshot: Codable {
    var id: UUID
    var patternRegex: String
    var merchantMatch: String
    var categoryId: UUID?
    var priority: Int
    var source: String
    var matchCount: Int
    var createdFrom: String?
    var lastModifiedAt: Date
}

struct InstallmentPlanSnapshot: Codable {
    var id: UUID
    var accountId: UUID?
    var originalPurchaseId: UUID?
    var installmentsIds: [UUID]
    var originalAmount: Decimal
    var totalMonths: Int
    var currentMonth: Int
    var monthlyAmount: Decimal
    var ratePercent: Decimal
    var firstChargeDate: Date
    var merchantDescription: String
    var lastModifiedAt: Date
}

struct PendingImportSnapshot: Codable {
    var id: UUID
    var accountId: UUID?
    var statementId: UUID?
    var rawText: String
    var reason: String
    var parsedDate: Date?
    var parsedAmount: Decimal?
    var parsedDescription: String?
    var cardLast4: String?
    var resolvedTransactionId: UUID?
    var createdAt: Date
    var lastModifiedAt: Date
    var matchedDeletedTransactionId: UUID?
}

struct SignRecoveryHintSnapshot: Codable {
    var id: UUID
    var pattern: String
    var implicitSign: Int
    var source: String
    var createdFrom: String?
    var matchCount: Int
    var lastModifiedAt: Date
}

#endif
