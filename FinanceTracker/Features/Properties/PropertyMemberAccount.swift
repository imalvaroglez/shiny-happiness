import Foundation

/// Pure per-member account summary for the collections surfaces: the facts
/// `PropertyMemberSettlement` already publishes, decomposed into the month
/// components a collection detail explains money with — the house's shared
/// pot, the member's slice of it, individual charges, rent, and adjustments.
///
/// The account is a read-only projection over the same inputs: every figure
/// comes from the `PropertyMonthlyReport` rows and a settlement built from the
/// exact same arguments, so it can never disagree with the member table or the
/// capture suggestion. It never invents money: a figure whose sources are
/// missing, untrustworthy, or not yet a calendar fact stays `nil` instead of
/// collapsing to `0.00`.
///
/// Nil-ability mirrors the settlement's own computability (`canCalculate`,
/// `isClosed`, or ended participation): the month components exist exactly
/// when the settlement exposes its month figures. A projection month — one
/// strictly after the `asOf` calendar month — additionally hides every month
/// component: its split is an estimate of the future, not a settled fact.
///
/// Conservation invariant: whenever every month component and `balanceDue`
/// are non-nil (a calculable month that counts toward the debt), the visible
/// rows sum by hand:
///
///     balanceDue == priorDebt
///         + max(0, rent + memberSharedShare + individualCharges + adjustments - appliedPayments)
///
/// `appliedPayments` is the month slice only — the valid collections applied
/// to this month's obligations. The slice that covered closed months travels
/// separately as `priorPaid`, and that money is already net inside
/// `priorDebt`, so adding it back into the sum would double-count it.
struct PropertyMemberAccount: Equatable, Sendable {
    var residentID: UUID
    /// The report month this account summarizes (`report.monthStart`).
    var month: Date
    var asOf: Date
    /// True while the month is strictly after the `asOf` calendar month: the
    /// breakdown is a projection, so month components stay nil.
    var isProjection: Bool
    var status: PropertyMemberSettlement.Status
    /// Total of the month's obligations with a linked transaction, a
    /// non-reimbursement kind, and shared responsibility (`.shared` /
    /// `.selected`). Individual charges and reimbursements stay out; nil when
    /// the split is not calculable or the month is a projection.
    var houseSharedTotal: Decimal?
    /// The member's share of the shared pot under the split in force,
    /// including custom and per-row allocations (`resident.sharedExpenses`).
    /// nil exactly like `houseSharedTotal`.
    var memberSharedShare: Decimal?
    var individualCharges: Decimal?
    var rent: Decimal?
    var adjustments: Decimal?
    /// Valid collections applied to this month's obligations
    /// (`settlement.monthPaid`). The slice that covered closed months is
    /// `priorPaid`, already net inside `priorDebt`.
    var appliedPayments: Decimal
    /// Valid collections applied to obligations of closed months
    /// (`settlement.priorPaid`); already net inside `priorDebt`.
    var priorPaid: Decimal
    var priorDebt: Decimal
    /// Valid unapplied advances available for this member.
    var advanceAvailable: Decimal
    /// An advance of this member lost its source, or the source changed or
    /// stopped being a valid collection receipt: repair work, not spendable money.
    var advancesNeedRepair: Bool
    var receiptsNeedReview: Bool
    /// This member's receipts flagged by reconciliation (overallocated or used
    /// as reimbursement and collection), newest first.
    var overallocatedReceiptIDs: [UUID]
    /// The settlement's outstanding debt. Numeric in `.review` while the month
    /// is computable — unbacked records are exposed separately instead of
    /// being silently discounted from the balance. Nil in `.toCalculate` and
    /// `.toReconcile`, and always nil in a projection month: the future is
    /// never presented as debt.
    var balanceDue: Decimal?
    /// The amount that opens the capture: `max(0, balanceDue -
    /// advanceAvailable)`, nil exactly when `balanceDue` is nil. Never
    /// negative: an advance larger than the balance suggests `0` and keeps its
    /// remainder — the surplus is not lost and not an error.
    var suggestedPayment: Decimal?

    /// Account of one member. Pure: computes from the report, the ledger, and
    /// the transaction inputs without writing anywhere.
    static func account(propertyID: UUID, residentID: UUID, report: PropertyMonthlyReport,
                        ledger: PropertyLedger, inputs: [PropertyTransactionInput],
                        asOf: Date, context: PropertyMemberSettlement.Context) -> Self {
        let settlement = PropertyMemberSettlement.summarize(propertyID: propertyID,
            residentID: residentID, report: report, ledger: ledger, inputs: inputs,
            asOf: asOf, context: context)
        let calendar = Calendar.current
        let isProjection = calendar.propertyMonthStart(for: report.monthStart)
            > calendar.propertyMonthStart(for: asOf)
        var houseSharedTotal: Decimal?
        var memberSharedShare: Decimal?
        var individualCharges: Decimal?
        var rent: Decimal?
        var adjustments: Decimal?
        // The settlement exposes the month only when the member is present and
        // the split is computable; a projection additionally hides figures
        // that are not calendar facts yet.
        if settlement.monthObligation != nil, !isProjection,
           let member = report.residents.first(where: { $0.id == residentID }) {
            houseSharedTotal = report.obligations
                .filter { obligation in
                    obligation.transactionID != nil
                        && obligation.kind != .reimbursement
                        && isSharedResponsibility(obligation.responsibility)
                }
                .reduce(Decimal.zero) { $0 + $1.amount }
                .currencyRounded
            memberSharedShare = member.sharedExpenses.currencyRounded
            individualCharges = member.individualExpenses.currencyRounded
            rent = member.rent.currencyRounded
            adjustments = member.adjustments.currencyRounded
        }
        // `settlement.due` stays non-nil in `.review` while the month is still
        // computable — review shows a numeric balance and owns the unbacked
        // records separately instead of hiding the debt behind them.
        var balanceDue: Decimal?
        switch settlement.status {
        case .pending, .partial, .paid, .nothingDue, .review: balanceDue = settlement.due
        case .toCalculate, .toReconcile: balanceDue = nil
        }
        // A projection month never presents the future as debt, even when its
        // estimate computes a due.
        if isProjection { balanceDue = nil }
        // The capture opener: never negative — an advance larger than the
        // balance suggests 0 and keeps its remainder available.
        let suggestedPayment = balanceDue
            .map { max(0, $0 - settlement.advanceAvailable).currencyRounded }
        return Self(residentID: residentID, month: report.monthStart, asOf: asOf,
                    isProjection: isProjection, status: settlement.status,
                    houseSharedTotal: houseSharedTotal, memberSharedShare: memberSharedShare,
                    individualCharges: individualCharges, rent: rent, adjustments: adjustments,
                    appliedPayments: settlement.monthPaid,
                    priorPaid: settlement.priorPaid,
                    priorDebt: settlement.priorDebt,
                    advanceAvailable: settlement.advanceAvailable,
                    advancesNeedRepair: settlement.advanceStale || settlement.sourcesMissing,
                    receiptsNeedReview: settlement.receiptsNeedReview,
                    overallocatedReceiptIDs: settlement.overallocatedReceiptIDs,
                    balanceDue: balanceDue,
                    suggestedPayment: suggestedPayment)
    }

    private static func isSharedResponsibility(_ responsibility: PropertyResponsibility) -> Bool {
        switch responsibility {
        case .shared, .selected: return true
        case .individual, .owner: return false
        }
    }
}
