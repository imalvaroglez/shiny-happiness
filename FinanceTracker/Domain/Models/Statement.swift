import Foundation
import SwiftData

@Model
final class Statement {
    var id: UUID
    @Relationship(deleteRule: .nullify) var account: Account?
    var periodStart: Date
    var periodEnd: Date
    var sourceFileHash: String
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

    init(
        id: UUID = UUID(),
        account: Account? = nil,
        periodStart: Date,
        periodEnd: Date,
        sourceFileHash: String,
        importedAt: Date = .now,
        ocrUsed: Bool = false,
        openingBalance: Decimal? = nil,
        closingBalance: Decimal? = nil,
        minimumPayment: Decimal? = nil,
        paymentForNoInterest: Decimal? = nil,
        paymentDueDate: Date? = nil,
        interestCharged: Decimal? = nil,
        feesCharged: Decimal? = nil,
        ivaCharged: Decimal? = nil
    ) {
        self.id = id
        self.account = account
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.sourceFileHash = sourceFileHash
        self.importedAt = importedAt
        self.ocrUsed = ocrUsed
        self.openingBalance = openingBalance
        self.closingBalance = closingBalance
        self.minimumPayment = minimumPayment
        self.paymentForNoInterest = paymentForNoInterest
        self.paymentDueDate = paymentDueDate
        self.interestCharged = interestCharged
        self.feesCharged = feesCharged
        self.ivaCharged = ivaCharged
    }
}
