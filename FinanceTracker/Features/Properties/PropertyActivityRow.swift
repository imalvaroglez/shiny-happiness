import Foundation

/// Attribution identity behind a row, independent of the responsibility label
/// it renders. Detail scopes ("View detail" in the member account sheet)
/// filter by this identity instead of by label text: closed months render the
/// concatenated split («Tú: $X · Fer: $Y»), `.selected` groups render member
/// names, and household custom splits render «Custom · Fer $X», so labels can
/// never reliably identify the rows a scope's figure was built from.
enum PropertyActivityIdentity: Hashable, Sendable {
    case shared
    case individual(UUID)
}

struct PropertyActivityRow: Identifiable, Equatable {
    enum Kind: String, CaseIterable { case expense = "Expense", collection = "Collection", reimbursement = "Reimbursement" }
    var id: UUID
    var date: Date?
    var concept: String
    var account: String?
    var kind: Kind
    var amount: Decimal?
    var currency: String
    var responsibility: String
    var issue: String?
    var canAssign: Bool
    var isClosed: Bool
    var categoryID: UUID? = nil
    var categoryName: String? = nil
    var categoryHierarchy: PropertyCategoryHierarchy? = nil
    var identity: PropertyActivityIdentity? = nil
}

enum PropertyActivitySortColumn: String, CaseIterable, Identifiable {
    case date = "Date"
    case concept = "Concept"
    case account = "Source account"
    case type = "Type"
    case responsibility = "Responsibility"
    case amount = "Amount"

    var id: String { rawValue }
}

enum PropertyActivitySortDirection: String {
    case ascending = "Ascending"
    case descending = "Descending"

    var symbolName: String { self == .ascending ? "arrow.up" : "arrow.down" }
}

enum PropertyActivitySorter {
    static func sorted(_ rows: [PropertyActivityRow], by column: PropertyActivitySortColumn,
                       direction: PropertyActivitySortDirection) -> [PropertyActivityRow] {
        let kindLabels = Dictionary(uniqueKeysWithValues: PropertyActivityRow.Kind.allCases.map {
            ($0, String(localized: String.LocalizationValue($0.rawValue)))
        })

        switch column {
        case .date:
            return rows.sorted {
                precedes($0.date, $1.date, lhs: $0, rhs: $1, direction: direction, usesDateTieBreak: false) { $0.compare($1) }
            }
        case .concept:
            return rows.sorted {
                precedes($0.concept, $1.concept, lhs: $0, rhs: $1, direction: direction, usesDateTieBreak: true) {
                    $0.localizedStandardCompare($1)
                }
            }
        case .account:
            return rows.sorted {
                precedes($0.account, $1.account, lhs: $0, rhs: $1, direction: direction, usesDateTieBreak: true) {
                    $0.localizedStandardCompare($1)
                }
            }
        case .type:
            return rows.sorted {
                precedes(kindLabels[$0.kind], kindLabels[$1.kind], lhs: $0, rhs: $1, direction: direction, usesDateTieBreak: true) {
                    $0.localizedStandardCompare($1)
                }
            }
        case .responsibility:
            return rows.sorted {
                precedes($0.responsibility, $1.responsibility, lhs: $0, rhs: $1, direction: direction, usesDateTieBreak: true) {
                    $0.localizedStandardCompare($1)
                }
            }
        case .amount:
            return rows.sorted {
                precedes($0.amount, $1.amount, lhs: $0, rhs: $1, direction: direction, usesDateTieBreak: true) {
                    if $0 == $1 { .orderedSame } else if $0 < $1 { .orderedAscending } else { .orderedDescending }
                }
            }
        }
    }

    private static func precedes<Value>(_ leftValue: Value?, _ rightValue: Value?,
                                       lhs: PropertyActivityRow, rhs: PropertyActivityRow,
                                       direction: PropertyActivitySortDirection,
                                       usesDateTieBreak: Bool,
                                       compare: (Value, Value) -> ComparisonResult) -> Bool {
        switch (leftValue, rightValue) {
        case (.none, .none):
            return stablePrecedes(lhs, rhs, usesDateTieBreak: usesDateTieBreak)
        case (.none, .some):
            return false // Missing values remain last in either direction.
        case (.some, .none):
            return true
        case (.some(let left), .some(let right)):
            let result = compare(left, right)
            if result == .orderedSame { return stablePrecedes(lhs, rhs, usesDateTieBreak: usesDateTieBreak) }
            return direction == .ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    private static func stablePrecedes(_ lhs: PropertyActivityRow, _ rhs: PropertyActivityRow,
                                       usesDateTieBreak: Bool) -> Bool {
        if usesDateTieBreak {
            switch (lhs.date, rhs.date) {
            case (.some(let left), .some(let right)) where left != right:
                return left < right
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                break
            }
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

enum PropertyActivityFilter: String, CaseIterable, Identifiable {
    case linked = "Linked"
    case unassigned = "To assign"
    var id: String { rawValue }
}

enum PropertyAssignmentChoice {
    case owner, shared, member(UUID), group, partner, custom
}

@MainActor
enum PropertyActivityPresenter {
    static func rows(propertyID: UUID, month: Date, asOf: Date, filter: PropertyActivityFilter,
                     ledger: PropertyLedger, report: PropertyMonthlyReport, inputs: [PropertyTransactionInput],
                     household: [UUID: HouseholdExpenseAllocation]? = nil,
                     deferredHouseholdIDs: Set<UUID> = []) -> [PropertyActivityRow] {
        let availability = PropertyAssignmentService.availability(propertyID: household == nil ? propertyID : nil, ledger: ledger)
        let sources = Dictionary(inputs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let obligations = Dictionary(report.obligations.compactMap { obligation in
            obligation.transactionID.map { ($0, obligation) }
        }, uniquingKeysWith: { first, _ in first })
        let attributions = ledger.attributions.filter { $0.propertyID == propertyID && $0.deletedAt == nil }
        let applications = ledger.paymentApplications.filter { $0.propertyID == propertyID && $0.deletedAt == nil }
        let attributionsByID = Dictionary(attributions.map { ($0.transactionID, $0) }, uniquingKeysWith: { first, _ in first })
        let applicationsByID = Dictionary(applications.map { ($0.paymentTransactionID, $0) }, uniquingKeysWith: { first, _ in first })
        let closedIDs = Set(ledger.closes.flatMap { $0.obligations.compactMap(\.transactionID) })
        let activeResidents = household == nil ? Set(ledger.residents(for: propertyID, month: month).map(\.id))
            : PropertyHouseholdAdapter.activeMemberIDs(ledger: ledger, month: month)
        let obligationIDs = Set(report.obligations.map(\.id))
        var linked = Set(obligations.keys)
        if household != nil {
            for input in inputs where input.isHouseholdAssigned && input.isHouseholdEligible
                && input.amount < 0 && input.deletedAt == nil && !input.isDuplicate && !input.isTransfer
                && Calendar.current.isDate(input.postedAt, equalTo: month, toGranularity: .month) {
                linked.insert(input.id)
            }
        }
        for attribution in attributions {
            if let date = sources[attribution.transactionID]?.postedAt ?? attribution.sourcePostedAtSnapshot,
               Calendar.current.isDate(date, equalTo: month, toGranularity: .month) { linked.insert(attribution.transactionID) }
        }
        for application in applications {
            let date = sources[application.paymentTransactionID]?.postedAt ?? application.sourcePostedAtSnapshot
            if obligationIDs.contains(application.obligationID)
                || date.map({ Calendar.current.isDate($0, equalTo: month, toGranularity: .month) }) == true {
                linked.insert(application.paymentTransactionID)
            }
        }
        let ids: Set<UUID>
        if filter == .linked { ids = linked }
        else {
            ids = Set(inputs.filter {
                $0.amount < 0 && $0.postedAt <= asOf
                    && Calendar.current.isDate($0.postedAt, equalTo: month, toGranularity: .month)
                    && !linked.contains($0.id) && !$0.isHouseholdAssigned
                    && availability.allows($0)
            }.map(\.id))
        }
        return ids.compactMap { id in
            let input = sources[id]
            let attribution = attributionsByID[id]
            let application = applicationsByID[id]
            let obligation = obligations[id]
            let snapshot = attribution?.sourceSnapshots ?? application?.sourceSnapshots
            let referenceDate = snapshot?.postedAt ?? obligation?.sourcePostedAt
            let unavailable = input == nil || input?.deletedAt != nil || input?.isDuplicate == true
            let futureSource = (input?.postedAt ?? .distantPast) > asOf
            if futureSource && (referenceDate == nil || referenceDate! > asOf) { return nil }
            let historical = unavailable || futureSource
            let date = historical ? referenceDate ?? input?.postedAt : input?.postedAt ?? referenceDate
            if let date, date > asOf { return nil }
            let changed = input.map { source in
                if let snapshot {
                    return PropertySettlementCalculator.hasSourceChanged(amount: snapshot.amount, postedAt: snapshot.postedAt,
                        currencyCode: snapshot.currencyCode, description: snapshot.description, versus: source)
                }
                if let obligation {
                    return abs(source.amount) != obligation.amount || source.description != obligation.title
                        || (obligation.sourcePostedAt != nil
                            && !PropertySettlementCalculator.isSameWholeSecond(source.postedAt, obligation.sourcePostedAt!))
                        || (obligation.sourceCurrencyCode != nil && source.currencyCode != obligation.sourceCurrencyCode)
                }
                return false
            } ?? false
            let closed = closedIDs.contains(id)
            let unresolved: Bool
            switch attribution?.responsibility {
            case .individual(let member): unresolved = !activeResidents.contains(member)
            case .selected(let members): unresolved = !Set(members).isSubset(of: activeResidents)
            default:
                let hasInactiveAllocation = obligation?.allocations.contains(where: {
                    !activeResidents.contains($0.key) && $0.value > 0
                }) == true
                let roles = ledger.householdLink ?? PropertyHouseholdAdapter.link
                let inactiveDeferredPartner: Bool
                if case .partner? = household?[id] {
                    inactiveDeferredPartner = !activeResidents.contains(roles.partnerID)
                } else { inactiveDeferredPartner = false }
                unresolved = household != nil && !closed && (hasInactiveAllocation || inactiveDeferredPartner)
            }
            let signedAmount = historical ? snapshot?.amount : input?.amount
            let kind: PropertyActivityRow.Kind = attribution?.kind == .reimbursement || obligation?.kind == .reimbursement ? .reimbursement
                : application != nil || (signedAmount ?? -1) > 0 ? .collection : .expense
            // Attribution identity comes from the same source that feeds the
            // breakdown figures, not from the label the row renders: the
            // household allocation when present, else the responsibility
            // behind the row — the close's obligation for closed rows, the
            // attribution otherwise. Collections, reimbursements, and owner
            // rows never match a scope, mirroring what
            // `PropertyMemberAccount.houseSharedTotal` and `individualCharges`
            // exclude. A deferred household row is visible in the month it was
            // paid but belongs to a later month's charges, so it also stays
            // outside every scope — its subtotal must never claim it.
            let identity: PropertyActivityIdentity?
            if kind == .collection || kind == .reimbursement {
                identity = nil
            } else if deferredHouseholdIDs.contains(id) {
                identity = nil
            } else if let allocation = household?[id] {
                let roles = ledger.householdLink ?? PropertyHouseholdAdapter.link
                switch allocation {
                case .user: identity = .individual(roles.userID)
                case .partner: identity = .individual(roles.partnerID)
                case .shared, .custom: identity = .shared
                }
            } else {
                let responsibility = closed
                    ? obligation?.responsibility ?? attribution?.responsibility
                    : attribution?.responsibility ?? obligation?.responsibility
                switch responsibility {
                case .shared, .selected: identity = .shared
                case .individual(let memberID): identity = .individual(memberID)
                case .owner, nil: identity = nil
                }
            }
            let incompatible = kind == .expense && input.map { !availability.allows($0) } == true
            let assignment: String
            if closed, let obligation {
                assignment = obligation.allocations.sorted { $0.key.uuidString < $1.key.uuidString }.map { key, value in
                    let name = ledger.residents.first { $0.id == key }?.name
                        ?? report.residents.first { $0.id == key }?.name ?? String(localized: "Former member")
                    return "\(name): \(propertyMoneyText(value))"
                }.joined(separator: " · ")
            } else if let allocation = household?[id] {
                switch allocation {
                case .user: assignment = String(localized: "At my expense")
                case .partner: assignment = "Fer"
                case .shared: assignment = String(localized: "Shared")
                case .custom(let amount): assignment = String(format: String(localized: "Custom · Fer %@"), propertyMoneyText(amount))
                }
            } else if let responsibility = attribution?.responsibility ?? obligation?.responsibility {
                assignment = label(responsibility, residents: ledger.residents)
            } else { assignment = kind == .expense ? String(localized: "To assign") : String(localized: "Reconciliation") }
            let issue = unavailable ? String(localized: "Source unavailable · historical reference")
                : changed || incompatible ? String(localized: "Source changed · review required")
                : unresolved ? String(localized: "Assignment needs review")
                : closed ? String(localized: "Closed split · corrections require an adjustment") : nil
            return PropertyActivityRow(id: id, date: date,
                concept: (historical ? snapshot?.description ?? obligation?.title : input?.description) ?? String(localized: "Transaction unavailable"),
                account: historical ? nil : input?.accountName, kind: kind,
                amount: (historical ? snapshot?.amount ?? obligation?.amount : input?.amount).map { abs($0) },
                currency: (historical ? snapshot?.currencyCode ?? obligation?.sourceCurrencyCode : input?.currencyCode) ?? "MXN",
                responsibility: assignment.isEmpty ? String(localized: "At my expense") : assignment,
                issue: issue, canAssign: kind == .expense && !historical && !closed
                    && input.map { availability.allows($0) } == true,
                isClosed: closed, categoryID: historical ? nil : input?.categoryID,
                categoryName: historical ? nil : input?.categoryName,
                categoryHierarchy: historical ? .unavailable : input?.categoryHierarchy, identity: identity)
        }.sorted {
            if $0.date != $1.date { return ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    static func label(_ responsibility: PropertyResponsibility, residents: [PropertyResident]) -> String {
        switch responsibility {
        case .owner: String(localized: "At my expense")
        case .shared: String(localized: "Shared")
        case .individual(let id): residents.first { $0.id == id }?.name ?? String(localized: "Former member")
        case .selected(let ids): ids.sorted { $0.uuidString < $1.uuidString }.map { id in
            residents.first { $0.id == id }?.name ?? String(localized: "Former member")
        }.joined(separator: ", ")
        }
    }
}
