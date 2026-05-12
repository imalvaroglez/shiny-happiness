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
        paymentDayOfMonth: Int? = nil
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
    }
}
