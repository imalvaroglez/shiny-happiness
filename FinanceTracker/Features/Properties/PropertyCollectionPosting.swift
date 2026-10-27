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

    static func memberAdvances(propertyID: UUID, residentID: UUID, ledger: PropertyLedger,
                               inputs: [PropertyTransactionInput], asOf: Date) -> Decimal {
        let byID = Dictionary(inputs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let appliedByPayment = Dictionary(grouping: ledger.paymentApplications.filter { $0.deletedAt == nil },
                                          by: \.paymentTransactionID).mapValues {
            $0.reduce(Decimal.zero) { $0 + $1.amount }
        }
        return ledger.paymentApplications.filter { advance in
            advance.propertyID == propertyID && advance.residentID == residentID && advance.deletedAt == nil
                && PropertyPaymentAdvance.isAdvance(advance)
                && PropertySettlementCalculator.isValidCollectionPayment(byID[advance.paymentTransactionID], asOf: asOf)
                && (byID[advance.paymentTransactionID].map { source in
                    !PropertySettlementCalculator.hasSourceChanged(amount: advance.sourceAmountSnapshot,
                        postedAt: advance.sourcePostedAtSnapshot, currencyCode: advance.sourceCurrencySnapshot,
                        description: advance.sourceDescriptionSnapshot, versus: source)
                        && (appliedByPayment[source.id] ?? 0) <= source.amount
                } ?? false)
        }.reduce(Decimal.zero) { $0 + $1.amount }
    }

    static func legacyAdvances(propertyID: UUID, ledger: PropertyLedger,
                               inputs: [PropertyTransactionInput], asOf: Date) -> Decimal {
        memberAdvances(propertyID: propertyID,
            residentID: PropertyPaymentAdvance.placeholderResidentID(propertyID: propertyID),
            ledger: ledger, inputs: inputs, asOf: asOf)
    }

    static func suggestedAmount(propertyID: UUID, residentID: UUID, report: PropertyMonthlyReport,
                                ledger: PropertyLedger, inputs: [PropertyTransactionInput], asOf: Date,
                                includeCurrent: Bool = true) -> Decimal {
        // The capture sheet cannot see the period flags the member table knows,
        // so it asks for the calculable reading of the same settlement; a review
        // gate collapses to zero instead of suggesting an untrustworthy amount.
        let settlement = PropertyMemberSettlement.summarize(propertyID: propertyID, residentID: residentID,
            report: report, ledger: ledger, inputs: inputs, asOf: asOf,
            context: .init(canCalculate: true, isClosed: true, historical: false, includeCurrent: includeCurrent))
        return settlement.payable ?? 0
    }

    private static func monthOutstanding(close: PropertySettlementClose, residentID: UUID,
                                         ledger: PropertyLedger) -> Decimal {
        guard let member = close.residents.first(where: { $0.id == residentID }) else { return 0 }
        let ids = Set(close.obligations.map(\.id))
        let applied = ledger.paymentApplications.filter {
            $0.propertyID == close.propertyID && $0.residentID == residentID && $0.deletedAt == nil
                && ids.contains($0.obligationID)
        }.reduce(Decimal.zero) { $0 + $1.amount }
        return max(0, member.obligation - (member.directContribution ?? 0) - applied)
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
              !ledger.attributions.contains(where: { $0.transactionID == receipt.id && $0.deletedAt == nil }),
              !hasChangedAdvanceSource(propertyID: propertyID, residentID: residentID,
                                       ledger: ledger, inputs: inputs) else { return nil }
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
                    monthOutstanding(close: $0, residentID: residentID, ledger: ledger)) }
            + (includeCurrent && !ledger.closes.contains { $0.propertyID == propertyID && $0.monthStart == report.monthStart }
                ? [(report.monthStart, report.obligations,
                    max(0, report.residents.first { $0.id == residentID }?.balance ?? 0))] : [])
        let sorted = candidates.sorted { $0.0 < $1.0 }
        let byID = Dictionary(inputs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var advances = ledger.paymentApplications.filter {
            $0.propertyID == propertyID && ($0.residentID == residentID
                || ($0.paymentTransactionID == receipt.id && $0.residentID == placeholder)) && $0.deletedAt == nil
                && PropertyPaymentAdvance.isAdvance($0)
                && PropertySettlementCalculator.isValidCollectionPayment(byID[$0.paymentTransactionID], asOf: asOf)
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
                }.reduce(Decimal.zero) { $0 + $1.amount }
                var capacity = min(monthRemaining, max(0, assigned - already))
                guard capacity > 0 else { continue }
                // An advance never pays an obligation before its calendar month arrives.
                if month <= Calendar.current.propertyMonthStart(for: asOf) {
                    for index in advances.indices where capacity > 0 && advances[index].amount > 0 {
                        guard let source = byID[advances[index].paymentTransactionID] else { continue }
                        let used = min(capacity, advances[index].amount)
                        additions.append(PropertyPaymentApplication(propertyID: propertyID,
                            paymentTransactionID: source.id, obligationID: obligation.id,
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
        let candidates = ledger.closes.filter { $0.propertyID == propertyID && $0.monthStart <= report.monthStart }
            .map { ($0.monthStart, $0.obligations,
                    monthOutstanding(close: $0, residentID: residentID, ledger: ledger)) }
            + (includeCurrent && !ledger.closes.contains { $0.propertyID == propertyID && $0.monthStart == report.monthStart }
                ? [(report.monthStart, report.obligations,
                    max(0, report.residents.first { $0.id == residentID }?.balance ?? 0))] : [])
        let sorted = candidates.sorted { $0.0 < $1.0 }
        let byID = Dictionary(inputs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var advances = ledger.paymentApplications.filter {
            $0.propertyID == propertyID && $0.residentID == residentID && $0.deletedAt == nil
                && PropertyPaymentAdvance.isAdvance($0)
                && PropertySettlementCalculator.isValidCollectionPayment(byID[$0.paymentTransactionID], asOf: asOf)
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
                }.reduce(Decimal.zero) { $0 + $1.amount }
                var capacity = min(monthRemaining, max(0, assigned - already))
                guard capacity > 0 else { continue }
                // An advance never pays an obligation before its calendar month arrives.
                if month <= Calendar.current.propertyMonthStart(for: asOf) {
                    for index in advances.indices where capacity > 0 && advances[index].amount > 0 {
                        guard let source = byID[advances[index].paymentTransactionID] else { continue }
                        let used = min(capacity, advances[index].amount)
                        additions.append(PropertyPaymentApplication(propertyID: propertyID,
                            paymentTransactionID: source.id, obligationID: obligation.id,
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
        }
        return Plan(applications: additions, updatedAdvances: advances.filter { previous in
            ledger.paymentApplications.first { $0.id == previous.id } != previous
        })
    }
}
