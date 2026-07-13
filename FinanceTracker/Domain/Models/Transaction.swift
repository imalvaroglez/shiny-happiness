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
    var expenseAssignmentRaw: String?
    /// Household inclusion scope, persisted via this legacy column. Repurposed
    /// from the original (never-used) SettlementPaidBy to AVOID a SwiftData
    /// schema-version change: additive-optional properties are not inferable
    /// across an explicit migration plan, and a v5→v6 stage collides by
    /// checksum, while redefining v5 in place fails to reopen existing stores.
    /// Verified empty (all NULL) in production before repurpose. nil = legacy.
    var settlementPaidByRaw: String?
    var splitMethodOverrideRaw: String?
    var customUserPercent: Decimal?
    var customPartnerPercent: Decimal?
    var settlementNotes: String?
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
        treatmentKindRaw: String? = nil,
        expenseAssignmentRaw: String? = nil,
        settlementPaidByRaw: String? = nil,
        splitMethodOverrideRaw: String? = nil,
        customUserPercent: Decimal? = nil,
        customPartnerPercent: Decimal? = nil,
        settlementNotes: String? = nil,
        householdScopeRaw: String? = nil
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
        self.expenseAssignmentRaw = expenseAssignmentRaw
        // householdScopeRaw (scope) is persisted in this column; explicit scope
        // param wins over a raw settlementPaidByRaw param.
        self.settlementPaidByRaw = householdScopeRaw ?? settlementPaidByRaw
        self.splitMethodOverrideRaw = splitMethodOverrideRaw
        self.customUserPercent = customUserPercent
        self.customPartnerPercent = customPartnerPercent
        self.settlementNotes = settlementNotes
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

    var expenseAssignment: ExpenseAssignment {
        if let raw = expenseAssignmentRaw, let assignment = ExpenseAssignment(rawValue: raw) {
            return assignment
        }
        return .user
    }

    /// Household inclusion scope (backed by the repurposed settlementPaidByRaw
    /// column). Unknown/nil decode as `.excluded` (never `.included`); nil means
    /// legacy/unmigrated only.
    var householdScope: HouseholdScope {
        HouseholdScope(rawValue: settlementPaidByRaw ?? "") ?? .excluded
    }

    /// Alias over the persisted scope raw (stored in settlementPaidByRaw).
    var householdScopeRaw: String? {
        get { settlementPaidByRaw }
        set { settlementPaidByRaw = newValue }
    }

    var isIncludedInHouseholdSettlement: Bool { householdScope == .included }

    /// Sets scope, **always persisting an explicit raw value** so an excluded
    /// transaction (even one with a latent Shared/Fer/Custom assignment) is not
    /// re-included by a later migration pass. Does not touch assignment or
    /// custom allocation — exclusion preserves them as inactive metadata.
    func setHouseholdScope(_ scope: HouseholdScope) {
        householdScopeRaw = scope.rawValue
    }

    /// Exact Fer responsibility for a Custom split. The existing Decimal
    /// storage column is intentionally reused to avoid changing the SwiftData
    /// schema checksum; `.custom` distinguishes amounts from legacy percents.
    var customFerAmount: Decimal? {
        expenseAssignment == .custom ? customPartnerPercent : nil
    }

    var resolvedHouseholdAllocation: HouseholdExpenseAllocation {
        let eligibleAmount = abs(amount)
        switch expenseAssignmentRaw {
        case nil, ExpenseAssignment.user.rawValue, "unassigned":
            return .user
        case ExpenseAssignment.partner.rawValue:
            return .partner
        case ExpenseAssignment.custom.rawValue:
            guard let ferAmount = customPartnerPercent,
                  ferAmount >= 0,
                  ferAmount <= eligibleAmount,
                  ferAmount == ferAmount.currencyRounded else { return .user }
            return Self.normalizedAllocation(ferAmount: ferAmount, eligibleAmount: eligibleAmount)
        case ExpenseAssignment.shared.rawValue:
            switch splitMethodOverride {
            case .monthlyDefault:
                return .shared
            case .fiftyFifty:
                return Self.normalizedAllocation(
                    ferAmount: (eligibleAmount / 2).currencyRounded,
                    eligibleAmount: eligibleAmount
                )
            case .customPercent:
                guard let userPercent = customUserPercent,
                      let partnerPercent = customPartnerPercent,
                      userPercent >= 0,
                      partnerPercent >= 0,
                      userPercent + partnerPercent == 100 else { return .shared }
                return Self.normalizedAllocation(
                    ferAmount: (eligibleAmount * partnerPercent / 100).currencyRounded,
                    eligibleAmount: eligibleAmount
                )
            }
        default:
            return .user
        }
    }

    var settlementPaidBy: SettlementPaidBy {
        if let raw = settlementPaidByRaw, let paidBy = SettlementPaidBy(rawValue: raw) {
            return paidBy
        }
        return .user
    }

    var splitMethodOverride: HouseholdSplitMethod {
        if let raw = splitMethodOverrideRaw, let method = HouseholdSplitMethod(rawValue: raw) {
            return method
        }
        return .monthlyDefault
    }

    /// Reporting-only treatment assignment. Stores `.regular` as `nil` to keep
    /// persisted data quiet, and never touches flow/movement/transfer — those
    /// are orthogonal to how a transaction is *reported* on the dashboard. The
    /// detail sheet and any test go through here so the contract can't drift.
    func setReportingTreatment(_ kind: TransactionTreatmentKind) {
        treatmentKindRaw = kind == .regular ? nil : kind.rawValue
    }

    func setExpenseAssignment(_ assignment: ExpenseAssignment) {
        expenseAssignmentRaw = assignment == .user ? nil : assignment.rawValue
        splitMethodOverrideRaw = nil
        customUserPercent = nil
        if assignment != .custom {
            customPartnerPercent = nil
        }
    }

    func setCustomFerAmount(_ amount: Decimal) throws {
        let eligibleAmount = abs(self.amount)
        guard amount >= 0 else { throw HouseholdAllocationError.negativeAmount }
        guard amount <= eligibleAmount else { throw HouseholdAllocationError.exceedsExpense }
        guard amount == amount.currencyRounded else { throw HouseholdAllocationError.requiresCurrencyPrecision }

        if amount == 0 {
            setExpenseAssignment(.user)
        } else if amount == eligibleAmount {
            setExpenseAssignment(.partner)
        } else {
            expenseAssignmentRaw = ExpenseAssignment.custom.rawValue
            splitMethodOverrideRaw = nil
            customUserPercent = nil
            customPartnerPercent = amount
        }
    }

    func setHouseholdAllocation(_ allocation: HouseholdExpenseAllocation) throws {
        switch allocation {
        case .user:
            setExpenseAssignment(.user)
        case .shared:
            setExpenseAssignment(.shared)
        case .partner:
            setExpenseAssignment(.partner)
        case .custom(let ferAmount):
            try setCustomFerAmount(ferAmount)
        }
    }

    func setSettlementPaidBy(_ paidBy: SettlementPaidBy) {
        settlementPaidByRaw = paidBy == .user ? nil : paidBy.rawValue
    }

    func setSplitMethodOverride(_ method: HouseholdSplitMethod) {
        splitMethodOverrideRaw = method == .monthlyDefault ? nil : method.rawValue
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
    private static func normalizedAllocation(
        ferAmount: Decimal,
        eligibleAmount: Decimal
    ) -> HouseholdExpenseAllocation {
        if ferAmount == 0 { return .user }
        if ferAmount == eligibleAmount { return .partner }
        return .custom(ferAmount: ferAmount)
    }
}
