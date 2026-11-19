import SwiftData
import SwiftUI

/// What the picker is selecting. `.purchaseForNewRefund` serves the capture
/// form: the refund doesn't exist yet, so eligibility runs against draft values.
enum TransactionLinkPickerMode: Identifiable {
    case purchaseForNewRefund(currency: String, postedAt: Date)
    case purchaseForRefund(refund: Transaction)
    case refundForPurchase(purchase: Transaction)

    var id: String {
        switch self {
        case .purchaseForNewRefund: "purchase-for-new-refund"
        case .purchaseForRefund(let refund): "purchase-for-\(refund.id)"
        case .refundForPurchase(let purchase): "refund-for-\(purchase.id)"
        }
    }

    var title: String {
        switch self {
        case .purchaseForNewRefund, .purchaseForRefund: return String(localized: "Link purchase")
        case .refundForPurchase: return String(localized: "Link refund")
        }
    }
}

/// Sort keys for the link picker. Amount compares absolute magnitude so
/// purchases (negative) and refunds (positive) order consistently.
enum TransactionLinkSortMode: String, CaseIterable {
    case dateDesc
    case dateAsc
    case amountDesc
    case amountAsc
    case conceptAsc

    var displayName: String {
        switch self {
        case .dateDesc: return String(localized: "Newest First")
        case .dateAsc: return String(localized: "Oldest First")
        case .amountDesc: return String(localized: "Amount ↓")
        case .amountAsc: return String(localized: "Amount ↑")
        case .conceptAsc: return String(localized: "Concept A-Z")
        }
    }

    func sorted(_ movements: [Transaction]) -> [Transaction] {
        movements.sorted(by: comparator)
    }

    /// Comparador con desempate determinista por id (estable en tests).
    private var comparator: (Transaction, Transaction) -> Bool {
        switch self {
        case .dateDesc:
            return { lhs, rhs in
                if lhs.postedAt != rhs.postedAt { return lhs.postedAt > rhs.postedAt }
                return lhs.id.uuidString > rhs.id.uuidString
            }
        case .dateAsc:
            return { lhs, rhs in
                if lhs.postedAt != rhs.postedAt { return lhs.postedAt < rhs.postedAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        case .amountDesc:
            return { lhs, rhs in
                if abs(lhs.amount) != abs(rhs.amount) { return abs(lhs.amount) > abs(rhs.amount) }
                return lhs.id.uuidString > rhs.id.uuidString
            }
        case .amountAsc:
            return { lhs, rhs in
                if abs(lhs.amount) != abs(rhs.amount) { return abs(lhs.amount) < abs(rhs.amount) }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        case .conceptAsc:
            return { lhs, rhs in
                let order = lhs.merchantNormalized.localizedCaseInsensitiveCompare(rhs.merchantNormalized)
                if order != .orderedSame { return order == .orderedAscending }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        }
    }
}

/// Pure candidate pipeline for the link picker, free of SwiftUI state so the
/// filter/sort semantics stay unit-testable.
@MainActor
enum TransactionLinkCandidates {
    struct PurchaseDraftContext {
        var currency: String
        var postedAt: Date
        var remainingByPurchaseID: [UUID: Decimal]
    }

    /// Draft refund (capture form): purchases the new refund may link to.
    static func purchaseDraftCandidates(from movements: [Transaction], context: PurchaseDraftContext) -> [Transaction] {
        movements.filter { movement in
            TransactionLinkService.isEligiblePurchaseCandidate(movement)
                && movement.currency == context.currency
                && movement.postedAt <= context.postedAt
                && remainingAmount(for: movement, remainingByPurchaseID: context.remainingByPurchaseID) > 0
        }
    }

    /// Existing refund: purchases it may (re)link to. The refund's current
    /// target is always listed (even fully refunded) so a reassignment keeps
    /// the preselection visible; everything else needs remaining capacity.
    static func purchases(
        forRefund refund: Transaction,
        from movements: [Transaction],
        remainingByPurchaseID: [UUID: Decimal],
        alwaysIncludedIDs: Set<UUID> = []
    ) -> [Transaction] {
        movements.filter { movement in
            TransactionLinkService.isEligiblePurchaseCandidate(movement)
                && TransactionLinkService.isEligibleRefundCandidate(refund, for: movement)
                && (alwaysIncludedIDs.contains(movement.id)
                    || remainingAmount(for: movement, remainingByPurchaseID: remainingByPurchaseID) > 0)
        }
    }

    /// Existing purchase: refunds that may link to it, skipping refunds already
    /// linked elsewhere (reassignment happens from the refund's side).
    static func refunds(forPurchase purchase: Transaction, from movements: [Transaction], excludingRefundIDs: Set<UUID>) -> [Transaction] {
        movements.filter { movement in
            !excludingRefundIDs.contains(movement.id)
                && TransactionLinkService.isEligibleRefundCandidate(movement, for: purchase)
        }
    }

    static func apply(searchText: String, accountFilterID: UUID?, sort: TransactionLinkSortMode, to candidates: [Transaction]) -> [Transaction] {
        let search = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = candidates.filter { movement in
            (accountFilterID == nil || movement.account?.id == accountFilterID)
                && (search.isEmpty
                    || movement.descriptionRaw.localizedCaseInsensitiveContains(search)
                    || movement.merchantNormalized.localizedCaseInsensitiveContains(search)
                    || movement.account?.displayName.localizedCaseInsensitiveContains(search) == true)
        }
        return sort.sorted(filtered)
    }

    /// Purchases without active links keep their full amount refundable.
    private static func remainingAmount(for purchase: Transaction, remainingByPurchaseID: [UUID: Decimal]) -> Decimal {
        remainingByPurchaseID[purchase.id] ?? abs(purchase.amount)
    }
}

/// Draft-based picker: tapping a row only selects. Accept returns the choice to
/// the caller (capture form or detail sheet), which owns the actual linking —
/// this sheet never persists anything.
struct TransactionLinkPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let mode: TransactionLinkPickerMode
    let onAccept: (Transaction) -> Void

    @State private var baseCandidates: [Transaction] = []
    @State private var accounts: [Account] = []
    @State private var refundLinkSummary = RefundLinkSummary()
    @State private var searchText = ""
    @State private var accountFilterID: UUID?
    @State private var sortMode: TransactionLinkSortMode = .dateDesc
    @State private var selectedMovement: Transaction?
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                filters
                if let loadError {
                    Text(loadError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                }
                List(filteredMovements) { movement in
                    Button {
                        selectedMovement = movement
                    } label: {
                        movementRow(movement)
                    }
                    .buttonStyle(.plain)
                }
                .overlay {
                    if filteredMovements.isEmpty {
                        ContentUnavailableView("No matching movements", systemImage: "magnifyingglass")
                    }
                }
            }
            .navigationTitle(mode.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Accept") {
                        if let selectedMovement {
                            onAccept(selectedMovement)
                        }
                        dismiss()
                    }
                    .disabled(selectedMovement == nil)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .searchable(text: $searchText, prompt: "Search description or account")
            .task { load() }
        }
        .frame(minWidth: 560, minHeight: 440)
    }

    private var filters: some View {
        HStack(spacing: 12) {
            Picker("Account", selection: $accountFilterID) {
                Text("All accounts").tag(UUID?.none)
                ForEach(accounts) { account in
                    Text(account.displayName).tag(UUID?.some(account.id))
                }
            }
            .labelsHidden()
            Spacer()
            Menu {
                ForEach(TransactionLinkSortMode.allCases, id: \.self) { candidate in
                    Button {
                        sortMode = candidate
                    } label: {
                        if candidate == sortMode {
                            Label(candidate.displayName, systemImage: "checkmark")
                        } else {
                            Text(candidate.displayName)
                        }
                    }
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .menuStyle(.button)
            .fixedSize()
        }
        .padding(.horizontal)
        .padding(.top, 12)
    }

    private var filteredMovements: [Transaction] {
        TransactionLinkCandidates.apply(
            searchText: searchText,
            accountFilterID: accountFilterID,
            sort: sortMode,
            to: baseCandidates
        )
    }

    private func movementRow(_ movement: Transaction) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(movement.descriptionRaw)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                Text("\(movement.account?.displayName ?? String(localized: "Unknown account")) · \(movement.postedAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(MoneyFormat.string(movement.amount, code: movement.currency))
                .font(.callout.monospacedDigit())
                .foregroundStyle(movement.amount >= 0 ? .green : .red)
            if selectedMovement?.id == movement.id {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func load() {
        do {
            let movements = try modelContext.fetch(FetchDescriptor<Transaction>(
                predicate: #Predicate { $0.deletedAt == nil && $0.account != nil },
                sortBy: [SortDescriptor(\.postedAt, order: .reverse)]
            ))
            accounts = try modelContext.fetch(FetchDescriptor<Account>())
                .sorted { $0.displayName < $1.displayName }
            refundLinkSummary = try TransactionLinkService.refundLinkSummary(context: modelContext)
            // Candidatos y elegibilidad se calculan UNA vez al abrir; filtrar
            // por texto/cuenta u ordenar no re-clasifica el ledger entero.
            switch mode {
            case .purchaseForNewRefund(let currency, let postedAt):
                baseCandidates = TransactionLinkCandidates.purchaseDraftCandidates(
                    from: movements,
                    context: TransactionLinkCandidates.PurchaseDraftContext(
                        currency: currency,
                        postedAt: postedAt,
                        remainingByPurchaseID: refundLinkSummary.remainingByPurchaseID
                    )
                )
            case .purchaseForRefund(let refund):
                let currentTarget = refundLinkSummary.activeTargetByRefundID[refund.id]
                baseCandidates = TransactionLinkCandidates.purchases(
                    forRefund: refund,
                    from: movements,
                    remainingByPurchaseID: refundLinkSummary.remainingByPurchaseID,
                    alwaysIncludedIDs: currentTarget.map { [$0] } ?? []
                )
            case .refundForPurchase(let purchase):
                baseCandidates = TransactionLinkCandidates.refunds(
                    forPurchase: purchase,
                    from: movements,
                    excludingRefundIDs: refundLinkSummary.linkedRefundIDs
                )
            }
            preselectCurrentLink(in: baseCandidates)
        } catch {
            loadError = String(localized: "Could not load movements: \(error.localizedDescription)")
        }
    }

    /// Re-linking from the refund side: preselect the current purchase so
    /// Accept without changes keeps it, and picking another reassigns.
    private func preselectCurrentLink(in candidates: [Transaction]) {
        guard case .purchaseForRefund(let refund) = mode,
              let targetID = refundLinkSummary.activeTargetByRefundID[refund.id] else { return }
        selectedMovement = candidates.first { $0.id == targetID }
    }
}
