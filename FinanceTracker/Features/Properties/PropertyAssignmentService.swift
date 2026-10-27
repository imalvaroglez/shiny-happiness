import Foundation
import SwiftData

/// One assignment boundary, with independent adapters for JSON rental metadata and Household.
@MainActor
enum PropertyAssignmentService {
    enum AssignmentError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self { case .invalid(let key): String(localized: String.LocalizationValue(key)) }
        }
    }

    static func isLocked(_ transactionID: UUID, ledger: PropertyLedger) -> Bool {
        ledger.closes.contains { $0.obligations.contains { $0.transactionID == transactionID } }
    }

    struct Availability {
        var propertyID: UUID?
        var blocked: Set<UUID>
        func allows(_ input: PropertyTransactionInput) -> Bool {
            input.deletedAt == nil && !input.isDuplicate && !input.isTransfer && input.currencyCode == "MXN"
                && !blocked.contains(input.id)
                && (propertyID == nil ? input.isHouseholdEligible : !input.isHouseholdAssigned)
        }
    }

    static func availability(propertyID: UUID?, ledger: PropertyLedger) -> Availability {
        let blocked = ledger.attributions.filter { $0.deletedAt == nil && $0.propertyID != propertyID }.map(\.transactionID)
            + ledger.paymentApplications.filter { $0.deletedAt == nil && $0.propertyID != propertyID }.map(\.paymentTransactionID)
        return Availability(propertyID: propertyID, blocked: Set(blocked))
    }

    static func isAvailable(_ input: PropertyTransactionInput, propertyID: UUID?, ledger: PropertyLedger) -> Bool {
        availability(propertyID: propertyID, ledger: ledger).allows(input)
    }

    static func validate(_ responsibility: PropertyResponsibility, propertyID: UUID, month: Date, ledger: PropertyLedger) throws {
        let active = Set(ledger.residents(for: propertyID, month: month).map(\.id))
        switch responsibility {
        case .individual(let id):
            guard active.contains(id) else { throw AssignmentError.invalid("Choose an active member for this period.") }
        case .selected(let ids):
            guard !ids.isEmpty, Set(ids).count == ids.count, Set(ids).isSubset(of: active) else {
                throw AssignmentError.invalid("Choose active members for this period.")
            }
        case .shared, .owner: break
        }
    }

    /// Preserve attribution identity: payment applications and snapshots can reference it.
    static func upsert(_ proposed: PropertyTransactionAttribution, source: PropertyTransactionInput,
                       ledger: inout PropertyLedger, responsibilityOnly: Bool = false) throws {
        guard isAvailable(source, propertyID: proposed.propertyID, ledger: ledger) else {
            throw AssignmentError.invalid("This transaction has another destination or is not eligible.")
        }
        guard !isLocked(source.id, ledger: ledger) else {
            throw AssignmentError.invalid("This transaction belongs to a closed calculation. Record an adjustment in an open period.")
        }
        try validate(proposed.responsibility, propertyID: proposed.propertyID, month: source.postedAt, ledger: ledger)
        if let index = ledger.attributions.firstIndex(where: { $0.deletedAt == nil && $0.transactionID == source.id }) {
            if responsibilityOnly {
                ledger.attributions[index].responsibility = proposed.responsibility
                ledger.attributions[index].updatedAt = PersistedMutationClock.next(after: ledger.attributions[index].updatedAt)
            } else {
                var updated = proposed
                updated.id = ledger.attributions[index].id
                updated.createdAt = ledger.attributions[index].createdAt
                updated.sourceSnapshots = PropertySourceSnapshots(capturing: source)
                updated.updatedAt = PersistedMutationClock.next(after: ledger.attributions[index].updatedAt)
                ledger.attributions[index] = updated
            }
        } else {
            var created = proposed
            created.sourceSnapshots = PropertySourceSnapshots(capturing: source)
            ledger.attributions.append(created)
        }
    }

    static func assigning(_ responsibility: PropertyResponsibility, to ids: Set<UUID>, propertyID: UUID,
                          ledger: PropertyLedger, inputs: [PropertyTransactionInput]) throws -> PropertyLedger {
        guard !ids.isEmpty else { return ledger }
        var result = ledger
        let sources = Dictionary(inputs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let source = sources[id], source.amount < 0 else { throw AssignmentError.invalid("Choose eligible expenses to assign.") }
            let original = ledger.attributions.first { $0.transactionID == id && $0.deletedAt == nil }
            let proposal = PropertyTransactionAttribution(propertyID: propertyID, transactionID: id,
                kind: original?.kind ?? .operation, responsibility: responsibility)
            try upsert(proposal, source: source, ledger: &result, responsibilityOnly: true)
        }
        let errors = PropertyLedgerStore.validate(result)
        guard errors.isEmpty else { throw AssignmentError.invalid("The assignment could not be validated. Review the selected transactions.") }
        return result
    }

    /// One validation fetch per save batch, never one per displayed row or report recalculation.
    static func validateRentalSources(ids: Set<UUID>, inputs: [PropertyTransactionInput], container: ModelContainer) throws {
        let isolated = ModelContext(container)
        isolated.autosaveEnabled = false
        let identifiers = Array(ids)
        let live = try isolated.fetch(FetchDescriptor<Transaction>(predicate: #Predicate { identifiers.contains($0.id) }))
        let expected = Dictionary(inputs.filter { ids.contains($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard live.count == ids.count, live.allSatisfy({ tx in
            matchesFinancialSource(expected[tx.id], transaction: tx)
        }) else { throw AssignmentError.invalid("The transactions changed. Reload the period and try again.") }
    }

    private static func matchesFinancialSource(_ expected: PropertyTransactionInput?, transaction: Transaction) -> Bool {
        guard let expected else { return false }
        var current = PropertyTransactionInput(capturing: transaction)
        // Assignments never write category metadata. Eligibility remains part of
        // equality, so category changes that affect financial treatment still fail.
        current.categoryID = expected.categoryID
        current.categoryName = expected.categoryName
        current.categoryHierarchy = expected.categoryHierarchy
        return expected == current
    }

    struct HouseholdEdit {
        let context: ModelContext // retain isolated objects until the next period load
        let transactions: [Transaction]
        let clearedDueDates: Set<UUID>
        let overrides: [SettlementDueDateOverride]
    }

    static func assignHousehold(_ allocation: HouseholdExpenseAllocation, ids: Set<UUID>,
                               expected: [UUID: HouseholdAssignmentSnapshot], inputs: [PropertyTransactionInput],
                               ledger: PropertyLedger, container: ModelContainer,
                               editingContext: ModelContext? = nil, registered: [Transaction] = [],
                               commit: (ModelContext) throws -> Void = { try $0.save() }) throws -> HouseholdEdit {
        let staged = ModelContext(container)
        staged.autosaveEnabled = false
        let identifiers = Array(ids)
        let live = try staged.fetch(FetchDescriptor<Transaction>(predicate: #Predicate { identifiers.contains($0.id) }))
        guard live.count == ids.count else { throw AssignmentError.invalid("The transactions changed. Reload the period and try again.") }
        let sources = Dictionary(inputs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let availability = availability(propertyID: nil, ledger: ledger)
        var cleared: Set<UUID> = []
        // Validate the complete batch on isolated objects, including exact custom amounts,
        // before changing any registered UI identity or persisting anything.
        for tx in live {
            guard let source = sources[tx.id], source.amount == tx.amount, source.postedAt == tx.postedAt,
                  source.description == tx.descriptionRaw, tx.deletedAt == nil, !tx.isDuplicate, !tx.isTransfer,
                  tx.currency == "MXN", tx.amount < 0, HouseholdSettlementReportService.isSettlementEligible(tx),
                  expected[tx.id] == HouseholdAssignmentSnapshot(tx), availability.allows(source),
                  !isLocked(tx.id, ledger: ledger) else {
                throw AssignmentError.invalid("The transactions changed or belong to a closed calculation. Reload the period.")
            }
            let previous = tx.resolvedHouseholdAllocation
            let keepsSharedOverride = allocation == .shared && tx.expenseAssignmentRaw == ExpenseAssignment.shared.rawValue
            let explicitCustom: Bool
            if case .custom = allocation { explicitCustom = true } else { explicitCustom = false }
            if explicitCustom || (!keepsSharedOverride && previous != allocation) { try tx.setHouseholdAllocation(allocation) }
            tx.setHouseholdScope(.included)
            tx.touch()
            if previous == .partner && tx.resolvedHouseholdAllocation != .partner { cleared.insert(tx.id) }
        }
        let context = editingContext ?? staged
        let transactions = editingContext == nil ? live : registered.filter { ids.contains($0.id) }
        guard transactions.count == ids.count else { throw AssignmentError.invalid("The transactions changed. Reload the period and try again.") }
        if editingContext != nil {
            guard transactions.allSatisfy({ expected[$0.id] == HouseholdAssignmentSnapshot($0)
                && matchesFinancialSource(sources[$0.id], transaction: $0) }) else {
                throw AssignmentError.invalid("The transactions changed. Reload the period and try again.")
            }
        }
        let originals = Dictionary(transactions.map { ($0.id, (HouseholdAssignmentSnapshot($0), $0.lastModifiedAt)) }, uniquingKeysWith: { first, _ in first })
        let overrides = try context.fetch(FetchDescriptor<SettlementDueDateOverride>()).filter { cleared.contains($0.transactionID) }
        let originalOverrides = Dictionary(overrides.map { ($0.id, ($0.dueDate, $0.lastModifiedAt)) }, uniquingKeysWith: { first, _ in first })
        let prepared = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        do {
            if editingContext != nil {
                for tx in transactions {
                    guard let proposal = prepared[tx.id] else { continue }
                    HouseholdAssignmentSnapshot(proposal).apply(to: tx)
                    tx.lastModifiedAt = proposal.lastModifiedAt
                }
            }
            for row in overrides { row.dueDate = nil; row.lastModifiedAt = .now }
            try commit(context)
        } catch {
            if editingContext == nil { context.rollback() }
            else {
                // Restore only owned metadata; a global rollback could discard unrelated work.
                for tx in transactions {
                    if let before = originals[tx.id] { before.0.apply(to: tx); tx.lastModifiedAt = before.1 }
                }
                for row in overrides {
                    if let before = originalOverrides[row.id] { row.dueDate = before.0; row.lastModifiedAt = before.1 }
                }
            }
            throw error
        }
        return HouseholdEdit(context: context, transactions: transactions, clearedDueDates: cleared, overrides: overrides)
    }

}

struct HouseholdAssignmentSnapshot: Equatable {
    var assignment: String?
    var scope: String?
    var split: String?
    var userPercent: Decimal?
    var partnerPercent: Decimal?

    @MainActor init(_ transaction: Transaction) {
        assignment = transaction.expenseAssignmentRaw; scope = transaction.householdScopeRaw
        split = transaction.splitMethodOverrideRaw; userPercent = transaction.customUserPercent
        partnerPercent = transaction.customPartnerPercent
    }
    @MainActor func apply(to transaction: Transaction) {
        transaction.expenseAssignmentRaw = assignment; transaction.householdScopeRaw = scope
        transaction.splitMethodOverrideRaw = split; transaction.customUserPercent = userPercent
        transaction.customPartnerPercent = partnerPercent
    }

}

extension PropertyTransactionInput {
    @MainActor init(capturing tx: Transaction) {
        self.init(id: tx.id, amount: tx.amount, postedAt: tx.postedAt, description: tx.descriptionRaw,
            deletedAt: tx.deletedAt, isDuplicate: tx.isDuplicate, isTransfer: tx.isTransfer,
            isCashAccount: tx.account.map { [.checking, .savings, .wallet].contains($0.type) } ?? false,
            hasAccount: tx.account != nil,
            isHouseholdAssigned: tx.isIncludedInHouseholdSettlement, currencyCode: tx.currency,
            accountName: tx.account?.displayName, isHouseholdEligible: HouseholdSettlementReportService.isSettlementEligible(tx),
            categoryID: tx.category?.id, categoryName: tx.category?.localizedName ?? String(localized: "Uncategorized"),
            categoryHierarchy: Self.hierarchy(of: tx.category))
    }

    @MainActor private static func hierarchy(of category: Category?) -> PropertyCategoryHierarchy {
        guard let category else { return .uncategorized }
        var path: [PropertyCategoryComponent] = []
        var visited = Set<UUID>()
        var current: Category? = category
        while let node = current {
            guard visited.insert(node.id).inserted else { return .unavailable }
            path.append(PropertyCategoryComponent(id: node.id, name: node.localizedName))
            current = node.parent
        }
        return .path(path.reversed())
    }

}
