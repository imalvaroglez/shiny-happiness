import Foundation
import SwiftData

@Model
final class InstallmentPlan {
    var id: UUID
    @Relationship(deleteRule: .nullify) var account: Account?
    @Relationship(deleteRule: .nullify) var originalPurchase: Transaction?
    @Relationship(deleteRule: .nullify) var installments: [Transaction] = []
    var originalAmount: Decimal
    var totalMonths: Int
    var currentMonth: Int
    var monthlyAmount: Decimal
    var ratePercent: Decimal
    var firstChargeDate: Date
    var merchantDescription: String

    init(
        id: UUID = UUID(),
        account: Account? = nil,
        originalPurchase: Transaction? = nil,
        installments: [Transaction] = [],
        originalAmount: Decimal,
        totalMonths: Int,
        currentMonth: Int,
        monthlyAmount: Decimal,
        ratePercent: Decimal = 0,
        firstChargeDate: Date,
        merchantDescription: String
    ) {
        self.id = id
        self.account = account
        self.originalPurchase = originalPurchase
        self.installments = installments
        self.originalAmount = originalAmount
        self.totalMonths = totalMonths
        self.currentMonth = currentMonth
        self.monthlyAmount = monthlyAmount
        self.ratePercent = ratePercent
        self.firstChargeDate = firstChargeDate
        self.merchantDescription = merchantDescription
    }
}
