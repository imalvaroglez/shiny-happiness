import Foundation

/// Pure reconciliation of one real receipt and previously unspent member advances.
/// A plan never creates financial money: each application retains its source UUID.
enum PropertyCollectionPosting {
    struct Plan {
        var applications: [PropertyPaymentApplication]
        var updatedAdvances: [PropertyPaymentApplication]
    }

    // Thin wrappers over `MoneyEntry`, the canonical implementation. Kept
    // so Properties call sites and tests keep their existing seam.
    static func parseEntryAmount(_ text: String) -> Decimal? {
        MoneyEntry.parseEntryAmount(text)
    }

    /// Capture uses cents; the report retains its original Decimal obligation.
    static func suggestedEntryText(_ amount: Decimal) -> String {
        MoneyEntry.suggestedEntryText(amount)
    }

    /// The obligation set every advance route reconciles against: the current
    /// report's obligations plus every close of the property. A receipt used
    /// as reimbursement in any settled month is double-used money on every
    /// route alike — the settlement's precalculation, the posting walks, and
    /// `memberAdvances` all feed this same set to `reconciliationReview`, so
    /// their double-use flags can never disagree.
    static func reconciliationObligations(report: PropertyMonthlyReport,
                                          ledger: PropertyLedger) -> [PropertyObligationSnapshot] {
        report.obligations + ledger.closes.filter { $0.propertyID == report.propertyID }
            .flatMap(\.obligations)
    }

    /// The member's spendable advances under the one shared rule. The
    /// `obligations` are the caller's reconciliation scope — pass
    /// `reconciliationObligations(report:ledger:)`; an empty list is a real
    /// statement (nothing to reconcile against), never an omission.
    static func memberAdvances(propertyID: UUID, residentID: UUID, ledger: PropertyLedger,
                               obligations: [PropertyObligationSnapshot],
                               inputs: [PropertyTransactionInput], asOf: Date) -> Decimal {
        let byID = Dictionary(inputs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let appliedByPayment = Dictionary(grouping: ledger.paymentApplications.filter { $0.deletedAt == nil },
                                          by: \.paymentTransactionID).mapValues {
            $0.reduce(Decimal.zero) { $0 + $1.amount }
        }
        let reconciliation = PropertySettlementCalculator.reconciliationReview(
            propertyID: propertyID, obligations: obligations,
            applications: ledger.paymentApplications.filter {
                $0.propertyID == propertyID && $0.deletedAt == nil
            }, inputs: byID)
        return ledger.paymentApplications.filter { advance in
            advance.propertyID == propertyID && advance.residentID == residentID && advance.deletedAt == nil
                && PropertyPaymentAdvance.isAdvance(advance)
                && isSpendableAdvance(advance, inputsByID: byID, appliedByPayment: appliedByPayment,
                    overallocatedPaymentIDs: reconciliation.overallocatedPaymentIDs,
                    doubleUsedReceipts: reconciliation.doubleUsedReceipts, asOf: asOf)
        }.reduce(Decimal.zero) { $0 + $1.amount }
    }

    static func legacyAdvances(propertyID: UUID, ledger: PropertyLedger,
                               inputs: [PropertyTransactionInput], asOf: Date) -> Decimal {
        // A legacy advance predates member reports, so the property's closes
        // are its reconciliation scope — the same closes the shared set draws
        // from, derived here because no report month owns the placeholder.
        memberAdvances(propertyID: propertyID,
            residentID: PropertyPaymentAdvance.placeholderResidentID(propertyID: propertyID),
            ledger: ledger,
            obligations: ledger.closes.filter { $0.propertyID == propertyID }.flatMap(\.obligations),
            inputs: inputs, asOf: asOf)
    }

    static func suggestedAmount(propertyID: UUID, residentID: UUID, report: PropertyMonthlyReport,
                                ledger: PropertyLedger, inputs: [PropertyTransactionInput], asOf: Date,
                                includeCurrent: Bool = true) -> Decimal {
        // The capture sheet cannot see the period flags the member table knows,
        // so it asks for the calculable reading of the same settlement. A review
        // gate counts only valid data — invalid money never entered `due` or
        // `advanceAvailable` — and the review status accompanies the number.
        let settlement = PropertyMemberSettlement.summarize(propertyID: propertyID, residentID: residentID,
            report: report, ledger: ledger, inputs: inputs, asOf: asOf,
            context: .init(canCalculate: true, isClosed: true, historical: false, includeCurrent: includeCurrent))
        return settlement.payable ?? 0
    }

    /// The one validity rule balances and capacity share: an application counts
    /// (as collected money, as prior paid, or as spent capacity) only while its
    /// source still exists, is still a valid collection receipt as of `asOf`,
    /// still matches the snapshots captured at reconciliation time, and its
    /// receipt is neither overallocated nor used as reimbursement and collection
    /// at once. Over-allocation lives in the reconciliation sets every caller
    /// already computes alongside this rule.
    static func isValidAppliedCollection(_ application: PropertyPaymentApplication,
                                         inputsByID: [UUID: PropertyTransactionInput],
                                         overallocatedPaymentIDs: Set<UUID>,
                                         doubleUsedReceipts: Set<UUID>,
                                         asOf: Date) -> Bool {
        guard let source = inputsByID[application.paymentTransactionID],
              PropertySettlementCalculator.isValidCollectionPayment(source, asOf: asOf),
              !PropertySettlementCalculator.hasSourceChanged(
                  amount: application.sourceAmountSnapshot, postedAt: application.sourcePostedAtSnapshot,
                  currencyCode: application.sourceCurrencySnapshot,
                  description: application.sourceDescriptionSnapshot, versus: source),
              !overallocatedPaymentIDs.contains(application.paymentTransactionID),
              !doubleUsedReceipts.contains(application.paymentTransactionID)
        else { return false }
        return true
    }

    /// The one rule every advance-spending route applies — `plan`'s filter,
    /// `applyAdvances`' walk, the settlement's published availability, and
    /// `memberAdvances`: an advance is spendable only while its source still
    /// exists, still matches the snapshots captured at reconciliation time,
    /// has not been applied beyond its amount, is neither overallocated nor
    /// used as reimbursement and collection at once, and is still a valid
    /// collection receipt as of `asOf`. A broken advance never blocks a new
    /// collection; it only stops being spendable money.
    static func isSpendableAdvance(_ advance: PropertyPaymentApplication,
                                   inputsByID: [UUID: PropertyTransactionInput],
                                   appliedByPayment: [UUID: Decimal],
                                   overallocatedPaymentIDs: Set<UUID>,
                                   doubleUsedReceipts: Set<UUID>,
                                   asOf: Date) -> Bool {
        guard let source = inputsByID[advance.paymentTransactionID],
              !PropertySettlementCalculator.hasSourceChanged(
                  amount: advance.sourceAmountSnapshot, postedAt: advance.sourcePostedAtSnapshot,
                  currencyCode: advance.sourceCurrencySnapshot,
                  description: advance.sourceDescriptionSnapshot, versus: source),
              (appliedByPayment[source.id] ?? 0) <= source.amount,
              !overallocatedPaymentIDs.contains(advance.paymentTransactionID),
              !doubleUsedReceipts.contains(advance.paymentTransactionID),
              PropertySettlementCalculator.isValidCollectionPayment(source, asOf: asOf)
        else { return false }
        return true
    }

    /// The validity context `plan` and `applyAdvances` compute once per walk:
    /// the same reconciliation sets and applied totals the member settlement
    /// precalculates, so the walk's capacity can never disagree with the
    /// settlement's balance.
    private struct AppliedValidity {
        var inputsByID: [UUID: PropertyTransactionInput] = [:]
        var appliedByPayment: [UUID: Decimal] = [:]
        var overallocatedPaymentIDs: Set<UUID> = []
        var doubleUsedReceipts: Set<UUID> = []
        var validMonthPaidByResident: [UUID: Decimal] = [:]

        init(propertyID: UUID, report: PropertyMonthlyReport, ledger: PropertyLedger,
             inputs: [PropertyTransactionInput], asOf: Date) {
            for input in inputs { inputsByID[input.id] = input }
            appliedByPayment = Dictionary(
                grouping: ledger.paymentApplications.filter { $0.deletedAt == nil },
                by: \.paymentTransactionID
            ).mapValues { $0.reduce(Decimal.zero) { $0 + $1.amount } }
            let propertyApplications = ledger.paymentApplications.filter {
                $0.propertyID == propertyID && $0.deletedAt == nil
            }
            let reconciliation = PropertySettlementCalculator.reconciliationReview(
                propertyID: propertyID,
                obligations: reconciliationObligations(report: report, ledger: ledger),
                applications: propertyApplications, inputs: inputsByID)
            overallocatedPaymentIDs = reconciliation.overallocatedPaymentIDs
            doubleUsedReceipts = reconciliation.doubleUsedReceipts
            // The month's valid collections per resident — the same
            // accumulation the member settlement precalculates as
            // `validMonthPaidByResident`, so the walk's current-month cap and
            // the settlement's `monthBalance` are one figure, never two.
            let monthObligationIDs = Set(report.obligations.map(\.id))
            for application in propertyApplications
            where !PropertyPaymentAdvance.isAdvance(application)
                && monthObligationIDs.contains(application.obligationID)
                && isValidAppliedCollection(application, inputsByID: inputsByID,
                    overallocatedPaymentIDs: overallocatedPaymentIDs,
                    doubleUsedReceipts: doubleUsedReceipts, asOf: asOf) {
                validMonthPaidByResident[application.residentID, default: 0] += application.amount
            }
        }

        func includes(_ application: PropertyPaymentApplication, asOf: Date) -> Bool {
            isValidAppliedCollection(application, inputsByID: inputsByID,
                overallocatedPaymentIDs: overallocatedPaymentIDs,
                doubleUsedReceipts: doubleUsedReceipts, asOf: asOf)
        }
    }

    private static func monthOutstanding(close: PropertySettlementClose, residentID: UUID,
                                         ledger: PropertyLedger, validity: AppliedValidity,
                                         asOf: Date) -> Decimal {
        guard let member = close.residents.first(where: { $0.id == residentID }) else { return 0 }
        let ids = Set(close.obligations.map(\.id))
        let applied = ledger.paymentApplications.filter {
            $0.propertyID == close.propertyID && $0.residentID == residentID && $0.deletedAt == nil
                && ids.contains($0.obligationID)
                && validity.includes($0, asOf: asOf)
        }.reduce(Decimal.zero) { $0 + $1.amount }
        return max(0, member.obligation - (member.directContribution ?? 0) - applied)
    }

    /// The current month's net outstanding under the shared validity rule —
    /// never the report's `balance`, whose looser filter still counts
    /// collections whose source changed afterwards and would have the walk
    /// re-ask money the settlement already re-owed. Components are the
    /// resident's month slice, valid payments are the resident's non-advance
    /// applications against the report's obligations (`validity.includes`),
    /// and the direct contribution — money paid when the expense was
    /// recorded — counts exactly once. Same figure the member settlement
    /// publishes as `max(0, monthBalance)`.
    private static func currentMonthOutstanding(report: PropertyMonthlyReport, residentID: UUID,
                                                validity: AppliedValidity) -> Decimal {
        guard let resident = report.residents.first(where: { $0.id == residentID }) else { return 0 }
        let components = resident.rent + resident.sharedExpenses + resident.individualExpenses
            + resident.adjustments
        return max(0, components - (validity.validMonthPaidByResident[residentID] ?? 0)
            - resident.directContribution)
    }

    static func hasChangedAdvanceSource(propertyID: UUID, residentID: UUID,
                                        ledger: PropertyLedger, inputs: [PropertyTransactionInput]) -> Bool {
        let byID = Dictionary(inputs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let applicationsByPayment = Dictionary(grouping: ledger.paymentApplications.filter { $0.deletedAt == nil },
                                               by: \.paymentTransactionID)
        return ledger.paymentApplications.contains { advance in
            guard advance.propertyID == propertyID, advance.residentID == residentID,
                  advance.deletedAt == nil, PropertyPaymentAdvance.isAdvance(advance) else { return false }
            guard let source = byID[advance.paymentTransactionID] else { return true }
            let applied = applicationsByPayment[source.id, default: []]
                .reduce(Decimal.zero) { $0 + $1.amount }
            return PropertySettlementCalculator.hasSourceChanged(amount: advance.sourceAmountSnapshot,
                postedAt: advance.sourcePostedAtSnapshot, currencyCode: advance.sourceCurrencySnapshot,
                description: advance.sourceDescriptionSnapshot, versus: source)
                || applied > source.amount
                || !PropertySettlementCalculator.isValidCollectionPayment(source, asOf: .distantFuture)
        }
    }

    static func plan(propertyID: UUID, residentID: UUID, report: PropertyMonthlyReport,
                     ledger: PropertyLedger, inputs: [PropertyTransactionInput],
                     receipt: PropertyTransactionInput, asOf: Date, includeCurrent: Bool = true) -> Plan? {
        guard PropertySettlementCalculator.isValidCollectionPayment(receipt, asOf: asOf),
              ledger.residents.contains(where: { $0.id == residentID && $0.propertyID == propertyID }),
              !ledger.attributions.contains(where: { $0.transactionID == receipt.id && $0.deletedAt == nil })
        else { return nil }
        // A new collection is never blocked by a broken older reference: the
        // walk below simply refuses to spend unsound advances, and unbacked
        // applications stop consuming obligation capacity.
        let validity = AppliedValidity(propertyID: propertyID, report: report, ledger: ledger,
                                       inputs: inputs, asOf: asOf)
        let active = ledger.paymentApplications.filter { $0.deletedAt == nil && $0.paymentTransactionID == receipt.id }
        guard !active.contains(where: {
            PropertySettlementCalculator.hasSourceChanged(amount: $0.sourceAmountSnapshot,
                postedAt: $0.sourcePostedAtSnapshot, currencyCode: $0.sourceCurrencySnapshot,
                description: $0.sourceDescriptionSnapshot, versus: receipt)
        }) else { return nil }
        let placeholder = PropertyPaymentAdvance.placeholderResidentID(propertyID: propertyID)
        guard active.allSatisfy({ $0.propertyID == propertyID
            && ($0.residentID == residentID || (PropertyPaymentAdvance.isAdvance($0) && $0.residentID == placeholder)) })
        else { return nil }
        let available = receipt.amount - active.reduce(Decimal.zero) { $0 + $1.amount }
        guard available >= 0 else { return nil }
        var remaining = available
        let candidates = ledger.closes.filter { $0.propertyID == propertyID && $0.monthStart <= report.monthStart }
            .map { ($0.monthStart, $0.obligations,
                    monthOutstanding(close: $0, residentID: residentID, ledger: ledger,
                                     validity: validity, asOf: asOf)) }
            + (includeCurrent && !ledger.closes.contains { $0.propertyID == propertyID && $0.monthStart == report.monthStart }
                ? [(report.monthStart, report.obligations,
                    currentMonthOutstanding(report: report, residentID: residentID, validity: validity))] : [])
        let sorted = candidates.sorted { $0.0 < $1.0 }
        let byID = validity.inputsByID
        // The one spendable-advance rule, shared with `applyAdvances`,
        // `memberAdvances`, and the settlement's published availability: a
        // broken advance (source gone, changed, over-applied, overallocated,
        // double-used, or not yet a valid receipt) is never spent — but it no
        // longer blocks the receipt's own reconciliation either.
        var advances = ledger.paymentApplications.filter { advance in
            advance.propertyID == propertyID && (advance.residentID == residentID
                || (advance.paymentTransactionID == receipt.id && advance.residentID == placeholder))
                && advance.deletedAt == nil
                && PropertyPaymentAdvance.isAdvance(advance)
                && isSpendableAdvance(advance, inputsByID: byID,
                    appliedByPayment: validity.appliedByPayment,
                    overallocatedPaymentIDs: validity.overallocatedPaymentIDs,
                    doubleUsedReceipts: validity.doubleUsedReceipts, asOf: asOf)
        }.sorted {
            let first = byID[$0.paymentTransactionID]?.postedAt ?? .distantPast
            let second = byID[$1.paymentTransactionID]?.postedAt ?? .distantPast
            return first == second ? $0.id.uuidString < $1.id.uuidString : first < second
        }
        for index in advances.indices where advances[index].residentID == placeholder {
            advances[index].residentID = residentID
            advances[index].updatedAt = .now
        }
        var additions: [PropertyPaymentApplication] = []
        for (month, obligations, outstanding) in sorted {
            var monthRemaining = outstanding
            let ordered = obligations.sorted {
                if $0.isRent != $1.isRent { return $0.isRent }
                return $0.id.uuidString < $1.id.uuidString
            }
            for obligation in ordered where monthRemaining > 0 {
                let assigned = obligation.allocations[residentID] ?? 0
                let already = ledger.paymentApplications.filter {
                    $0.propertyID == propertyID && $0.residentID == residentID && $0.obligationID == obligation.id && $0.deletedAt == nil
                        && validity.includes($0, asOf: asOf)
                }.reduce(Decimal.zero) { $0 + $1.amount }
                var capacity = min(monthRemaining, max(0, assigned - already))
                guard capacity > 0 else { continue }
                // An advance never pays an obligation before its calendar month arrives.
                if month <= Calendar.current.propertyMonthStart(for: asOf) {
                    spendAdvances(advances: &advances, ledger: ledger, propertyID: propertyID,
                                  residentID: residentID, obligationID: obligation.id, byID: byID,
                                  capacity: &capacity, monthRemaining: &monthRemaining,
                                  additions: &additions)
                }
                if month <= Calendar.current.propertyMonthStart(for: receipt.postedAt), capacity > 0, remaining > 0 {
                    let used = min(capacity, remaining)
                    additions.append(PropertyPaymentApplication(propertyID: propertyID,
                        paymentTransactionID: receipt.id, obligationID: obligation.id,
                        residentID: residentID, amount: used, snapshots: PropertySourceSnapshots(capturing: receipt)))
                    capacity -= used; monthRemaining -= used; remaining -= used
                }
            }
        }
        if remaining > 0 {
            let advanceID = PropertyPaymentAdvance.obligationID(propertyID: propertyID, paymentTransactionID: receipt.id)
            additions.append(PropertyPaymentApplication(id: advanceID, propertyID: propertyID,
                paymentTransactionID: receipt.id, obligationID: advanceID, residentID: residentID,
                amount: remaining, snapshots: PropertySourceSnapshots(capturing: receipt)))
        }
        return Plan(applications: additions, updatedAdvances: advances.filter { previous in
            ledger.paymentApplications.first { $0.id == previous.id } != previous
        })
    }

    /// Explicit spending of a member's unspent advances against their outstanding
    /// months. An exact replica of `plan`'s advance walk without a new receipt:
    /// every application keeps the financial movement that already backs the
    /// advance, so this entry point never creates money or transactions. Only
    /// the member's own advances are spent — a placeholder advance adopts a
    /// member exclusively through receipt reconciliation in `plan`, so the
    /// amounts here can never exceed the member's published `advanceAvailable`.
    /// Receipt guards do not apply (no new receipt exists); the resident and
    /// stale-source guards are `plan`'s. Returns nil on a failed guard.
    static func applyAdvances(propertyID: UUID, residentID: UUID, report: PropertyMonthlyReport,
                              ledger: PropertyLedger, inputs: [PropertyTransactionInput],
                              asOf: Date, includeCurrent: Bool = true) -> Plan? {
        guard ledger.residents.contains(where: { $0.id == residentID && $0.propertyID == propertyID }),
              !hasChangedAdvanceSource(propertyID: propertyID, residentID: residentID,
                                       ledger: ledger, inputs: inputs) else { return nil }
        let validity = AppliedValidity(propertyID: propertyID, report: report, ledger: ledger,
                                       inputs: inputs, asOf: asOf)
        let candidates = ledger.closes.filter { $0.propertyID == propertyID && $0.monthStart <= report.monthStart }
            .map { ($0.monthStart, $0.obligations,
                    monthOutstanding(close: $0, residentID: residentID, ledger: ledger,
                                     validity: validity, asOf: asOf)) }
            + (includeCurrent && !ledger.closes.contains { $0.propertyID == propertyID && $0.monthStart == report.monthStart }
                ? [(report.monthStart, report.obligations,
                    currentMonthOutstanding(report: report, residentID: residentID, validity: validity))] : [])
        let sorted = candidates.sorted { $0.0 < $1.0 }
        let byID = validity.inputsByID
        var advances = ledger.paymentApplications.filter { advance in
            advance.propertyID == propertyID && advance.residentID == residentID && advance.deletedAt == nil
                && PropertyPaymentAdvance.isAdvance(advance)
                && isSpendableAdvance(advance, inputsByID: byID,
                    appliedByPayment: validity.appliedByPayment,
                    overallocatedPaymentIDs: validity.overallocatedPaymentIDs,
                    doubleUsedReceipts: validity.doubleUsedReceipts, asOf: asOf)
        }.sorted {
            let first = byID[$0.paymentTransactionID]?.postedAt ?? .distantPast
            let second = byID[$1.paymentTransactionID]?.postedAt ?? .distantPast
            return first == second ? $0.id.uuidString < $1.id.uuidString : first < second
        }
        var additions: [PropertyPaymentApplication] = []
        for (month, obligations, outstanding) in sorted {
            var monthRemaining = outstanding
            let ordered = obligations.sorted {
                if $0.isRent != $1.isRent { return $0.isRent }
                return $0.id.uuidString < $1.id.uuidString
            }
            for obligation in ordered where monthRemaining > 0 {
                let assigned = obligation.allocations[residentID] ?? 0
                let already = ledger.paymentApplications.filter {
                    $0.propertyID == propertyID && $0.residentID == residentID && $0.obligationID == obligation.id && $0.deletedAt == nil
                        && validity.includes($0, asOf: asOf)
                }.reduce(Decimal.zero) { $0 + $1.amount }
                var capacity = min(monthRemaining, max(0, assigned - already))
                guard capacity > 0 else { continue }
                // An advance never pays an obligation before its calendar month arrives.
                if month <= Calendar.current.propertyMonthStart(for: asOf) {
                    spendAdvances(advances: &advances, ledger: ledger, propertyID: propertyID,
                                  residentID: residentID, obligationID: obligation.id, byID: byID,
                                  capacity: &capacity, monthRemaining: &monthRemaining,
                                  additions: &additions)
                }
            }
        }
        return Plan(applications: additions, updatedAdvances: advances.filter { previous in
            ledger.paymentApplications.first { $0.id == previous.id } != previous
        })
    }

    /// The advance walk shared by `plan` and `applyAdvances`: spends the member's
    /// still-live advances against one obligation with capacity left. An advance
    /// that reaches zero is soft-deleted with its original ledger amount restored
    /// (the ledger rejects `amount <= 0`); requiring `deletedAt == nil` here keeps
    /// a later obligation in the same walk from respending that restored amount,
    /// which would count one real movement twice.
    private static func spendAdvances(advances: inout [PropertyPaymentApplication],
                                      ledger: PropertyLedger, propertyID: UUID, residentID: UUID,
                                      obligationID: UUID, byID: [UUID: PropertyTransactionInput],
                                      capacity: inout Decimal, monthRemaining: inout Decimal,
                                      additions: inout [PropertyPaymentApplication]) {
        for index in advances.indices
        where capacity > 0 && advances[index].amount > 0 && advances[index].deletedAt == nil {
            guard let source = byID[advances[index].paymentTransactionID] else { continue }
            let used = min(capacity, advances[index].amount)
            additions.append(PropertyPaymentApplication(propertyID: propertyID,
                paymentTransactionID: source.id, obligationID: obligationID,
                residentID: residentID, amount: used, snapshots: PropertySourceSnapshots(capturing: source)))
            advances[index].amount -= used
            advances[index].updatedAt = .now
            if advances[index].amount == 0 {
                advances[index].deletedAt = .now
                advances[index].amount = ledger.paymentApplications.first { $0.id == advances[index].id }?.amount ?? used
            }
            capacity -= used; monthRemaining -= used
        }
    }
}
