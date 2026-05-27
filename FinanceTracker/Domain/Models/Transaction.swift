import Foundation
import SwiftData

@Model
final class Transaction: LastModifiedTracking {
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
    var lastModifiedAt: Date = Date.now
    var deletedAt: Date? = nil

    init(
        id: UUID = UUID(),
        account: Account? = nil,
        statement: Statement? = nil,
        postedAt: Date,
        amount: Decimal,
        currency: String = "MXN",
        descriptionRaw: String,
        merchantNormalized: String = "",
        category: Category? = nil,
        fxRateToBase: Decimal = 1,
        isTransfer: Bool = false,
        isDuplicate: Bool = false,
        cardLast4: String? = nil,
        source: TransactionSource = .imported,
        transferGroupID: UUID? = nil,
        installmentPlan: InstallmentPlan? = nil
    ) {
        self.id = id
        self.account = account
        self.statement = statement
        self.postedAt = postedAt
        self.amount = amount
        self.currency = currency
        self.descriptionRaw = descriptionRaw
        self.merchantNormalized = merchantNormalized
        self.category = category
        self.fxRateToBase = fxRateToBase
        self.isTransfer = isTransfer
        self.isDuplicate = isDuplicate
        self.cardLast4 = cardLast4
        self.source = source
        self.transferGroupID = transferGroupID
        self.installmentPlan = installmentPlan
    }

    var categoryName: String {
        category?.name ?? ""
    }
}
