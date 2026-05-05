import Foundation

struct Money: Hashable, Comparable, Sendable {
    var amount: Decimal
    var currency: String

    static let zero = Money(amount: 0, currency: "MXN")

    init(amount: Decimal, currency: String = "MXN") {
        self.amount = amount
        self.currency = currency
    }

    static func < (lhs: Money, rhs: Money) -> Bool {
        lhs.amount < rhs.amount
    }

    static func + (lhs: Money, rhs: Money) -> Money {
        Money(amount: lhs.amount + rhs.amount, currency: lhs.currency)
    }

    static func - (lhs: Money, rhs: Money) -> Money {
        Money(amount: lhs.amount - rhs.amount, currency: lhs.currency)
    }

    var isNegative: Bool { amount < 0 }
    var isZero: Bool { amount == 0 }
    var absoluteValue: Money { Money(amount: abs(amount), currency: currency) }
}
