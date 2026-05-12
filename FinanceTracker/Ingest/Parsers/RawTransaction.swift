import Foundation

struct RawInstallmentHint: Sendable {
    var originalAmount: Decimal
    var totalMonths: Int
    var currentMonth: Int
    var monthlyAmount: Decimal
    var ratePercent: Decimal
    var firstChargeDate: Date
    var merchantDescription: String
}

struct RawTransaction: Identifiable, Sendable {
    var id: UUID
    var postedAt: Date
    var amount: Decimal
    var currency: String
    var descriptionRaw: String
    var merchantNormalized: String
    var fxRateToBase: Decimal
    var isTransfer: Bool
    var cardLast4: String?
    var installmentHint: RawInstallmentHint?

    init(
        id: UUID = UUID(),
        postedAt: Date,
        amount: Decimal,
        currency: String = "MXN",
        descriptionRaw: String,
        merchantNormalized: String = "",
        fxRateToBase: Decimal = 1,
        isTransfer: Bool = false,
        cardLast4: String? = nil,
        installmentHint: RawInstallmentHint? = nil
    ) {
        self.id = id
        self.postedAt = postedAt
        self.amount = amount
        self.currency = currency
        self.descriptionRaw = descriptionRaw
        self.merchantNormalized = merchantNormalized
        self.fxRateToBase = fxRateToBase
        self.isTransfer = isTransfer
        self.cardLast4 = cardLast4
        self.installmentHint = installmentHint
    }
}
