import Foundation

/// Pure per-member settlement summary behind the collections UI. One snapshot
/// feeds the member table, the capture sheet suggestion, and the member detail
/// sheet, so those surfaces can never disagree about what a member owes.
///
/// The summary never invents money: any amount that depends on missing or
/// untrustworthy sources becomes `nil` (or a `.review` status) instead of
/// silently collapsing to `0.00`.
struct PropertyMemberSettlement: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        /// Debt exists and no valid collection covers any of it.
        case pending
        /// Valid collections cover part of what the member owes.
        case partial
        /// There was debt and the valid collections cover all of it.
        case paid
        /// No debt existed to collect in the first place (the exact-zero frontier).
        case nothingDue
        /// The month split cannot be calculated yet; prior debt stays visible.
        case toCalculate
        /// A historical estimated split that was never reconciled into debt.
        case toReconcile
        /// A source vanished or changed, or a receipt needs reconciliation.
        case review
    }

    /// The period facts `PropertiesView.monthlyDetail` and the capture sheet
    /// already compute. The summary itself stays free of UI concerns.
    struct Context: Sendable {
        var canCalculate: Bool
        var isClosed: Bool
        var historical: Bool
        var includeCurrent: Bool
    }

    var residentID: UUID
    var month: Date
    var asOf: Date
    var status: Status
    /// Rent + shared + individual + adjustments of the month; nil while the split is not calculable.
    var monthObligation: Decimal?
    /// The month's components minus the month's valid collections — computed
    /// under the shared validity rule, never inherited from the report's looser
    /// filter; nil while the split is not calculable.
    var monthBalance: Decimal?
    /// Debt carried from closed months, net of valid collections (the report's figure).
    var priorDebt: Decimal
    /// Valid collections applied to obligations of closed months.
    var priorPaid: Decimal
    /// Valid collections applied to this month's obligations under the shared
    /// validity rule (`isValidAppliedCollection`), plus any direct
    /// contribution the report already credits — a changed source never
    /// discounts here in silence.
    var monthPaid: Decimal
    /// `priorDebt + max(0, monthBalance)` while computable: the outstanding debt.
    var due: Decimal?
    /// `max(0, due - advanceAvailable)` whenever `due` is computable — review
    /// included: invalid money never entered `due` nor `advanceAvailable`, so
    /// the number counts valid data only and the review status accompanies it.
    /// Nil while the split is not calculable or awaits reconciliation.
    var payable: Decimal?
    /// Valid unapplied advances available for this member.
    var advanceAvailable: Decimal
    /// An advance of this member no longer matches its backing transaction.
    var advanceStale: Bool
    /// An application of this member lost its backing transaction, or the
    /// transaction changed or stopped being a valid collection receipt.
    var sourcesMissing: Bool
    /// A receipt of this member is overallocated or used as reimbursement and collection.
    var receiptsNeedReview: Bool
    /// Non-advance applications whose source transaction is gone from the
    /// inputs. Exposure only: this money never enters `due`, `payable`, or
    /// `advanceAvailable` — the review notes own it.
    var unbackedCollectedMissing: Decimal
    /// Non-advance applications whose source still exists but changed or
    /// stopped being a valid collection receipt. Exposure only, like
    /// `unbackedCollectedMissing`.
    var unbackedCollectedChanged: Decimal
    /// Advances whose source is missing, changed, or invalid — repair work,
    /// never spendable money. Exposure only.
    var unbackedAdvances: Decimal
    /// Source transactions of this member's unbacked advances that still
    /// exist (a vanished source has no movement to reopen), newest first.
    var unbackedAdvanceReceiptIDs: [UUID]
    /// This member's receipts flagged by reconciliation (overallocated or
    /// used as reimbursement and collection), newest first like
    /// `paymentTransactionIDs`.
    var overallocatedReceiptIDs: [UUID]
    /// Receipts backing the valid collections, newest first. Prior receipts can
    /// include overallocated or double-used ones, inherited from `priorBalances`.
    var paymentTransactionIDs: [UUID]
    /// The member no longer participates in the report month.
    var participationEnded: Bool

    /// Settlement of one member. Supports former members that only carry debt
    /// from closed months (they are absent from `report.residents`).
    static func summarize(propertyID: UUID, residentID: UUID, report: PropertyMonthlyReport,
                          ledger: PropertyLedger, inputs: [PropertyTransactionInput],
                          asOf: Date, context: Context) -> Self {
        let data = Precalculated(propertyID: propertyID, report: report, ledger: ledger,
                                 inputs: inputs, asOf: asOf)
        return build(residentID: residentID, member: report.residents.first { $0.id == residentID },
                     report: report, asOf: asOf, context: context, data: data)
    }

    /// Settlements for every report member in a single pass over the ledger:
    /// application totals, advance validity, and reconciliation review are
    /// precalculated once instead of rescanning the ledger per member.
    static func summarizeAll(propertyID: UUID, report: PropertyMonthlyReport, ledger: PropertyLedger,
                             inputs: [PropertyTransactionInput], asOf: Date, context: Context,
                             visibleIDs: Set<UUID>? = nil, additionalResidentIDs: Set<UUID> = []) -> [Self] {
        let data = Precalculated(propertyID: propertyID, report: report, ledger: ledger,
                                 inputs: inputs, asOf: asOf)
        let current = report.residents
            .filter { visibleIDs?.contains($0.id) ?? true }
            .map { build(residentID: $0.id, member: $0, report: report, asOf: asOf,
                         context: context, data: data) }
        let currentIDs = Set(current.map(\.residentID))
        let former = additionalResidentIDs.subtracting(currentIDs).sorted { $0.uuidString < $1.uuidString }
            .map { id in build(residentID: id, member: report.residents.first { $0.id == id },
                               report: report, asOf: asOf, context: context, data: data) }
            .filter { $0.priorDebt > 0 || $0.advanceAvailable > 0 || $0.advanceStale || $0.sourcesMissing
                || $0.receiptsNeedReview || !$0.paymentTransactionIDs.isEmpty }
        return current + former
    }

    // MARK: - Internals

    private static func build(residentID: UUID, member: PropertyResidentReport?,
                              report: PropertyMonthlyReport, asOf: Date,
                              context: Context, data: Precalculated) -> Self {
        let participationEnded = member == nil
            || (data.knownResidentIDs.contains(residentID) && !data.activeResidentIDs.contains(residentID))
        let computable = participationEnded || context.isClosed || context.canCalculate
        // Prior debt recomputed under the shared validity rule: an unbacked
        // application never discounts debt here, exactly as it never consumes
        // capacity in the posting walk, so balance and capacity cannot disagree.
        let priorDebt = ((data.priorObligationByResident[residentID] ?? 0)
            - (data.priorPaidByResident[residentID] ?? 0)).currencyRounded
        // The month slice obeys the same shared validity rule as the prior
        // slice: only applications whose source still exists, is still a valid
        // receipt, and still matches its snapshots count as collected, so a
        // changed source never discounts the month in silence while the review
        // notes say it did not. The member's direct contribution (money paid
        // when the expense was recorded) is not an application and keeps
        // counting, exactly as it does inside `PropertyResidentReport.paid`.
        let monthPaid = ((data.validMonthPaidByResident[residentID] ?? 0)
            + (member?.directContribution ?? 0)).currencyRounded
        var monthObligation: Decimal?
        var monthBalance: Decimal?
        if let member, computable {
            monthObligation = (member.rent + member.sharedExpenses + member.individualExpenses
                + member.adjustments).currencyRounded
            monthBalance = (monthObligation! - monthPaid).currencyRounded
        }
        let priorPaid = (data.priorPaidByResident[residentID] ?? 0).currencyRounded
        let advanceAvailable = (data.advanceByResident[residentID] ?? 0).currencyRounded
        let advanceStale = data.advanceStaleByResident.contains(residentID)
        let sourcesMissing = data.sourcesMissingByResident.contains(residentID)
        let receiptsNeedReview = data.receiptsNeedReviewByResident.contains(residentID)
        // `includeCurrent == false` keeps the open month out of the debt, mirroring
        // the capture sheet's suggestion gating.
        let current = context.includeCurrent && !participationEnded ? max(0, monthBalance ?? 0) : 0

        let status: Status
        var due: Decimal?
        var payable: Decimal?
        if sourcesMissing || advanceStale || receiptsNeedReview {
            // Show every amount that is still computable. The payable counts
            // valid data only — invalid money never entered `due` or
            // `advanceAvailable` by construction — and the review status keeps
            // owning the repair work; a review never claims paid.
            status = .review
            due = computable ? (priorDebt + current).currencyRounded : nil
            payable = due.map { max(0, $0 - advanceAvailable).currencyRounded }
        } else if context.historical && !participationEnded {
            // The estimated split never becomes debt on its own.
            status = .toReconcile
            due = nil
            payable = nil
        } else if !context.canCalculate && !context.isClosed && !participationEnded {
            status = .toCalculate
            due = nil
            payable = nil
        } else {
            let dueValue = (priorDebt + current).currencyRounded
            due = dueValue
            payable = max(0, dueValue - advanceAvailable).currencyRounded
            // Gross obligation behind the net figures: closed debt before its
            // collections plus this month's obligation.
            let grossObligation = (priorDebt + priorPaid + (monthObligation ?? 0)).currencyRounded
            let collected = (monthPaid + priorPaid).currencyRounded
            if dueValue <= 0 {
                // Exact frontier: nothing due only when no debt ever existed;
                // a covered debt stays paid even if over-application pushed
                // the net closed balances to zero or below.
                status = collected > 0 || grossObligation > 0 ? .paid : .nothingDue
            } else if collected >= grossObligation
                // Defensive against manual over-application, which can leave
                // the net `due` above the gross obligation.
                && collected >= dueValue {
                // Month collections were applied beyond the month obligation, so
                // they already cover debt the net `due` still carries.
                status = .paid
            } else if collected > 0 {
                status = .partial
            } else {
                status = .pending
            }
        }

        var receiptIDs = data.monthReceiptIDsByResident[residentID] ?? []
        receiptIDs.formUnion(data.priorReceiptIDsByResident[residentID] ?? [])
        let paymentTransactionIDs = Self.newestFirst(receiptIDs, inputsByID: data.inputsByID)
        let overallocatedReceiptIDs = Self.newestFirst(
            data.overallocatedReceiptIDsByResident[residentID] ?? [], inputsByID: data.inputsByID)
        let unbackedCollectedMissing = (data.unbackedCollectedMissingByResident[residentID] ?? 0).currencyRounded
        let unbackedCollectedChanged = (data.unbackedCollectedChangedByResident[residentID] ?? 0).currencyRounded
        let unbackedAdvances = (data.unbackedAdvancesByResident[residentID] ?? 0).currencyRounded
        let unbackedAdvanceReceiptIDs = Self.newestFirst(
            data.unbackedAdvanceReceiptIDsByResident[residentID] ?? [], inputsByID: data.inputsByID)

        return Self(residentID: residentID, month: report.monthStart, asOf: asOf, status: status,
                    monthObligation: monthObligation, monthBalance: monthBalance, priorDebt: priorDebt,
                    priorPaid: priorPaid, monthPaid: monthPaid, due: due, payable: payable,
                    advanceAvailable: advanceAvailable, advanceStale: advanceStale,
                    sourcesMissing: sourcesMissing, receiptsNeedReview: receiptsNeedReview,
                    unbackedCollectedMissing: unbackedCollectedMissing,
                    unbackedCollectedChanged: unbackedCollectedChanged,
                    unbackedAdvances: unbackedAdvances,
                    unbackedAdvanceReceiptIDs: unbackedAdvanceReceiptIDs,
                    overallocatedReceiptIDs: overallocatedReceiptIDs,
                    paymentTransactionIDs: paymentTransactionIDs,
                    participationEnded: participationEnded)
    }

    /// Receipt IDs newest first, then stable by UUID — the order the payment
    /// surfaces already publish.
    private static func newestFirst(_ ids: Set<UUID>,
                                    inputsByID: [UUID: PropertyTransactionInput]) -> [UUID] {
        ids.map { ($0, inputsByID[$0]?.postedAt ?? .distantPast) }
            .sorted {
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                return $0.0.uuidString < $1.0.uuidString
            }
            .map(\.0)
    }

    /// One pass over the ledger shared by every member of a report. Replicates
    /// the validity filters of the settlement report, `memberAdvances`, and
    /// `hasChangedAdvanceSource` exactly, so the summary can never drift from
    /// the numbers those entry points already publish.
    private struct Precalculated {
        var inputsByID: [UUID: PropertyTransactionInput] = [:]
        var activeResidentIDs: Set<UUID> = []
        var knownResidentIDs: Set<UUID> = []
        var monthReceiptIDsByResident: [UUID: Set<UUID>] = [:]
        var validMonthPaidByResident: [UUID: Decimal] = [:]
        var priorObligationByResident: [UUID: Decimal] = [:]
        var priorPaidByResident: [UUID: Decimal] = [:]
        var priorReceiptIDsByResident: [UUID: Set<UUID>] = [:]
        var advanceByResident: [UUID: Decimal] = [:]
        var advanceStaleByResident: Set<UUID> = []
        var sourcesMissingByResident: Set<UUID> = []
        var receiptsNeedReviewByResident: Set<UUID> = []
        var unbackedCollectedMissingByResident: [UUID: Decimal] = [:]
        var unbackedCollectedChangedByResident: [UUID: Decimal] = [:]
        var unbackedAdvancesByResident: [UUID: Decimal] = [:]
        var unbackedAdvanceReceiptIDsByResident: [UUID: Set<UUID>] = [:]
        var overallocatedReceiptIDsByResident: [UUID: Set<UUID>] = [:]

        /// The receipt gate `report()` warns about, applied to the money math:
        /// an application only counts as collected when its source is a valid
        /// collection payment as of `asOf` and still matches the snapshots
        /// captured at reconciliation time.
        static func countsAsCollected(_ application: PropertyPaymentApplication,
                                       inputsByID: [UUID: PropertyTransactionInput], asOf: Date) -> Bool {
            guard let source = inputsByID[application.paymentTransactionID],
                  PropertySettlementCalculator.isValidCollectionPayment(source, asOf: asOf),
                  !PropertySettlementCalculator.hasSourceChanged(
                    amount: application.sourceAmountSnapshot, postedAt: application.sourcePostedAtSnapshot,
                    currencyCode: application.sourceCurrencySnapshot,
                    description: application.sourceDescriptionSnapshot, versus: source)
            else { return false }
            return true
        }

        init(propertyID: UUID, report: PropertyMonthlyReport, ledger: PropertyLedger,
             inputs: [PropertyTransactionInput], asOf: Date) {
            for input in inputs { inputsByID[input.id] = input }
            activeResidentIDs = Set(ledger.residents(for: propertyID, month: report.monthStart).map(\.id))
            knownResidentIDs = Set(ledger.residents.filter { $0.propertyID == propertyID }.map(\.id))
            let propertyApplications = ledger.paymentApplications.filter {
                $0.propertyID == propertyID && $0.deletedAt == nil
            }
            let reconciliation = PropertySettlementCalculator.reconciliationReview(
                propertyID: propertyID, obligations: report.obligations,
                applications: propertyApplications, inputs: inputsByID)
            // Applied totals per receipt across every property: the same totals
            // `memberAdvances` and `hasChangedAdvanceSource` compare against.
            let appliedByPayment = Dictionary(
                grouping: ledger.paymentApplications.filter { $0.deletedAt == nil },
                by: \.paymentTransactionID
            ).mapValues { $0.reduce(Decimal.zero) { $0 + $1.amount } }

            // Valid collections of the report month, mirroring the report's own
            // application filter through the shared validity rule: receipt IDs
            // for the payment surfaces and the amounts the settlement counts as
            // `monthPaid`.
            let monthObligationIDs = Set(report.obligations.map(\.id))
            for application in propertyApplications
            where !PropertyPaymentAdvance.isAdvance(application)
                && monthObligationIDs.contains(application.obligationID)
                && PropertyCollectionPosting.isValidAppliedCollection(application,
                    inputsByID: inputsByID,
                    overallocatedPaymentIDs: reconciliation.overallocatedPaymentIDs,
                    doubleUsedReceipts: reconciliation.doubleUsedReceipts, asOf: asOf) {
                monthReceiptIDsByResident[application.residentID, default: []]
                    .insert(application.paymentTransactionID)
                validMonthPaidByResident[application.residentID, default: 0] += application.amount
            }

            // Prior debt pieces from closes, mirroring `priorBalances`.
            for close in ledger.closes
            where close.propertyID == propertyID && close.monthStart < report.monthStart {
                let obligationIDs = Set(close.obligations.map(\.id))
                let reimbursementTransactionIDs = Set(close.obligations.compactMap {
                    $0.kind == .reimbursement ? $0.transactionID : nil
                })
                for snapshot in close.residents {
                    priorObligationByResident[snapshot.id, default: 0]
                        += snapshot.obligation - (snapshot.directContribution ?? 0)
                }
                for application in propertyApplications
                where obligationIDs.contains(application.obligationID)
                    && !reimbursementTransactionIDs.contains(application.paymentTransactionID)
                    && PropertyCollectionPosting.isValidAppliedCollection(application,
                        inputsByID: inputsByID,
                        overallocatedPaymentIDs: reconciliation.overallocatedPaymentIDs,
                        doubleUsedReceipts: reconciliation.doubleUsedReceipts, asOf: asOf) {
                    priorPaidByResident[application.residentID, default: 0] += application.amount
                    priorReceiptIDsByResident[application.residentID, default: []]
                        .insert(application.paymentTransactionID)
                }
            }

            for application in propertyApplications {
                // The gate mirrors report()'s receipt warnings: an application
                // whose source is absent, stopped being a valid collection
                // receipt (deleted, duplicate, converted to a transfer,
                // accountless, household-assigned, non-MXN or non-positive), or
                // no longer matches its captured snapshots forces review
                // instead of silently counting as collected.
                if !Self.countsAsCollected(application, inputsByID: inputsByID, asOf: .distantFuture) {
                    sourcesMissingByResident.insert(application.residentID)
                }
                // Unbacked non-advance applications, split by reason for the
                // review notes: a source that vanished entirely versus one that
                // still exists but changed or stopped being a valid collection
                // receipt. Exposure only — these amounts never enter any
                // balance or availability figure.
                if !PropertyPaymentAdvance.isAdvance(application) {
                    if inputsByID[application.paymentTransactionID] == nil {
                        unbackedCollectedMissingByResident[application.residentID, default: 0]
                            += application.amount
                    } else if !Self.countsAsCollected(application, inputsByID: inputsByID,
                                                      asOf: .distantFuture) {
                        unbackedCollectedChangedByResident[application.residentID, default: 0]
                            += application.amount
                    }
                }
                if reconciliation.overallocatedPaymentIDs.contains(application.paymentTransactionID)
                    || reconciliation.doubleUsedReceipts.contains(application.paymentTransactionID) {
                    receiptsNeedReviewByResident.insert(application.residentID)
                    overallocatedReceiptIDsByResident[application.residentID, default: []]
                        .insert(application.paymentTransactionID)
                }
            }

            // Advance availability and staleness, mirroring `memberAdvances` and
            // `hasChangedAdvanceSource` member for member. An advance that
            // loses its backing is quantified for the notes; it is never
            // available money.
            for advance in propertyApplications where PropertyPaymentAdvance.isAdvance(advance) {
                guard let source = inputsByID[advance.paymentTransactionID] else {
                    advanceStaleByResident.insert(advance.residentID)
                    unbackedAdvancesByResident[advance.residentID, default: 0] += advance.amount
                    continue
                }
                let changed = PropertySettlementCalculator.hasSourceChanged(
                    amount: advance.sourceAmountSnapshot, postedAt: advance.sourcePostedAtSnapshot,
                    currencyCode: advance.sourceCurrencySnapshot,
                    description: advance.sourceDescriptionSnapshot, versus: source)
                guard !changed,
                      (appliedByPayment[source.id] ?? 0) <= source.amount,
                      PropertySettlementCalculator.isValidCollectionPayment(source, asOf: .distantFuture)
                else {
                    advanceStaleByResident.insert(advance.residentID)
                    unbackedAdvancesByResident[advance.residentID, default: 0] += advance.amount
                    unbackedAdvanceReceiptIDsByResident[advance.residentID, default: []]
                        .insert(source.id)
                    continue
                }
                if PropertySettlementCalculator.isValidCollectionPayment(source, asOf: asOf) {
                    advanceByResident[advance.residentID, default: 0] += advance.amount
                }
            }
        }
    }
}
