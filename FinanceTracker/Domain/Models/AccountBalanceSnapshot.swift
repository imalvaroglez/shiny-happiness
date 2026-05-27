import Foundation
import SwiftData

@Model
final class AccountBalanceSnapshot: LastModifiedTracking {
    var id: UUID
    @Relationship(deleteRule: .nullify) var account: Account?
    var date: Date
    var amount: Decimal
    var kind: AccountBalanceSnapshotKind
    var note: String?
    var createdAt: Date
    var lastModifiedAt: Date = Date.now

    init(
        id: UUID = UUID(),
        account: Account? = nil,
        date: Date,
        amount: Decimal,
        kind: AccountBalanceSnapshotKind,
        note: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.account = account
        self.date = date
        self.amount = amount
        self.kind = kind
        self.note = note
        self.createdAt = createdAt
    }
}
