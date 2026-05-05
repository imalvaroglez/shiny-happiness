import Foundation

struct RawTransaction: Identifiable, Sendable {
    var id: UUID
    var postedAt: Date
    var amount: Decimal
    var currency: String
    var descriptionRaw: String
    var merchantNormalized: String
    var fxRateToBase: Decimal
    var isTransfer: Bool

    init(
        id: UUID = UUID(),
        postedAt: Date,
        amount: Decimal,
        currency: String = "MXN",
        descriptionRaw: String,
        merchantNormalized: String = "",
        fxRateToBase: Decimal = 1,
        isTransfer: Bool = false
    ) {
        self.id = id
        self.postedAt = postedAt
        self.amount = amount
        self.currency = currency
        self.descriptionRaw = descriptionRaw
        self.merchantNormalized = merchantNormalized
        self.fxRateToBase = fxRateToBase
        self.isTransfer = isTransfer
    }
}
