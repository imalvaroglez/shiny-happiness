import Foundation
import SwiftData

@Model
final class Account {
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
    /// Optional user-chosen identity color stored as `#RRGGBB`. When nil,
    /// `AccountIdentity.color(for:)` falls back to the institution default map.
    var tintHex: String?

    init(
        id: UUID = UUID(),
        institution: String,
        type: AccountType,
        currency: String = "MXN",
        nickname: String? = nil,
        accountNumber: String? = nil,
        openedAt: Date = .now,
        closedAt: Date? = nil,
        creditLimit: Decimal? = nil,
        statementDayOfMonth: Int? = nil,
        paymentDayOfMonth: Int? = nil,
        tintHex: String? = nil
    ) {
        self.id = id
        self.institution = institution
        self.type = type
        self.currency = currency
        self.nickname = nickname ?? institution
        self.accountNumber = accountNumber
        self.openedAt = openedAt
        self.closedAt = closedAt
        self.creditLimit = creditLimit
        self.statementDayOfMonth = statementDayOfMonth
        self.paymentDayOfMonth = paymentDayOfMonth
        self.tintHex = tintHex
    }
}
