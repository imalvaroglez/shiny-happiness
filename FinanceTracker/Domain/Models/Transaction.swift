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
    var flowKindRaw: String? = nil
    var movementKindRaw: String?
    var treatmentKindRaw: String?
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
        installmentPlan: InstallmentPlan? = nil,
        flowKindRaw: String? = nil,
        movementKindRaw: String? = nil,
        treatmentKindRaw: String? = nil
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
        self.flowKindRaw = flowKindRaw
        self.movementKindRaw = movementKindRaw
        self.treatmentKindRaw = treatmentKindRaw
    }

    var categoryName: String {
        category?.name ?? ""
    }

    var flowKind: TransactionFlowKind {
        if let raw = flowKindRaw, let kind = TransactionFlowKind(rawValue: raw) {
            return kind
        }
        if isTransfer { return .transfer }
        let isLiability = account?.type.isLiability == true
        if isLiability {
            if amount > 0 {
                if category?.kind == .creditCardPayment { return .payment }
                return .cardCredit
            }
            return .charge
        }
        return amount >= 0 ? .income : .expense
    }

    var movementKind: TransactionMovementKind {
        if let raw = movementKindRaw, let kind = TransactionMovementKind(rawValue: raw) {
            return kind
        }
        return Self.movementKind(from: flowKind, amount: amount, isTransfer: isTransfer)
    }

    var treatmentKind: TransactionTreatmentKind {
        if let raw = treatmentKindRaw, let kind = TransactionTreatmentKind(rawValue: raw) {
            return kind
        }
        return .regular
    }

    /// Reporting-only treatment assignment. Stores `.regular` as `nil` to keep
    /// persisted data quiet, and never touches flow/movement/transfer — those
    /// are orthogonal to how a transaction is *reported* on the dashboard. The
    /// detail sheet and any test go through here so the contract can't drift.
    func setReportingTreatment(_ kind: TransactionTreatmentKind) {
        treatmentKindRaw = kind == .regular ? nil : kind.rawValue
    }

    static func movementKind(from flowKind: TransactionFlowKind, amount: Decimal, isTransfer: Bool) -> TransactionMovementKind {
        if isTransfer { return .transfer }
        switch flowKind {
        case .income: return .income
        case .expense, .charge: return .expense
        case .transfer, .payment: return .transfer
        case .cardCredit: return .adjustment
        }
    }
}
