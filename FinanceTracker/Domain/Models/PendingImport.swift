import Foundation
import SwiftData

@Model
final class PendingImport: LastModifiedTracking {
    var id: UUID
    @Relationship(deleteRule: .nullify) var account: Account?
    @Relationship(deleteRule: .nullify) var statement: Statement?
    /// Raw text of the unparseable line, preserved exactly as the user pasted it.
    var rawText: String
    /// Short reason from the parser explaining what could not be determined.
    var reason: String
    /// Best-effort partial parse: any of these may be nil.
    var parsedDate: Date?
    var parsedAmount: Decimal?
    var parsedDescription: String?
    var cardLast4: String?
    /// Set when the user resolves the row; the resolved Transaction lives in the regular tables.
    @Relationship(deleteRule: .nullify) var resolvedTransaction: Transaction?
    var createdAt: Date
    var lastModifiedAt: Date = Date.now
    var matchedDeletedTransactionId: UUID?

    init(
        id: UUID = UUID(),
        account: Account? = nil,
        statement: Statement? = nil,
        rawText: String,
        reason: String,
        parsedDate: Date? = nil,
        parsedAmount: Decimal? = nil,
        parsedDescription: String? = nil,
        cardLast4: String? = nil,
        resolvedTransaction: Transaction? = nil,
        createdAt: Date = .now,
        matchedDeletedTransactionId: UUID? = nil
    ) {
        self.id = id
        self.account = account
        self.statement = statement
        self.rawText = rawText
        self.reason = reason
        self.parsedDate = parsedDate
        self.parsedAmount = parsedAmount
        self.parsedDescription = parsedDescription
        self.cardLast4 = cardLast4
        self.resolvedTransaction = resolvedTransaction
        self.createdAt = createdAt
        self.matchedDeletedTransactionId = matchedDeletedTransactionId
    }
}
