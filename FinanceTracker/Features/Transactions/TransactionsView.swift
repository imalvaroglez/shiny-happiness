import SwiftUI
import SwiftData

struct PendingApplyToSimilar: Identifiable {
    let id = UUID()
    let transaction: Transaction
    let category: Category
    let keyword: String?
}

enum CategoryFilter: Hashable {
    case all
    case uncategorized
    case parent(UUID)
    case specific(UUID)
}

enum AssignmentFilter: Hashable, CaseIterable {
    case all
    case user
    case shared
    case partner
    case custom

    var displayName: String {
        switch self {
        case .all: String(localized: "All Assignments")
        case .user: String(localized: "User")
        case .shared: String(localized: "Shared")
        case .partner: "Fer"
        case .custom: String(localized: "Custom split")
        }
    }

    var assignment: ExpenseAssignment? {
        switch self {
        case .all: nil
        case .user: .user
        case .shared: .shared
        case .partner: .partner
        case .custom: .custom
        }
    }
}

enum HouseholdInclusionFilter: Hashable, CaseIterable {
    case all
    case included
    case notIncluded

    var displayName: String {
        switch self {
        case .all: String(localized: "All Transactions")
        case .included: String(localized: "Included in Household")
        case .notIncluded: String(localized: "Not included in Household")
        }
    }
}

/// One-shot navigation intent for account history or household review.
/// Each preset carries a unique token so it is applied exactly once.
struct TransactionFilterPreset: Identifiable, Equatable {
    let id = UUID()
    let month: YearMonth?
    let inclusion: HouseholdInclusionFilter
    let accountID: UUID?

    init(
        month: YearMonth? = nil,
        inclusion: HouseholdInclusionFilter = .all,
        accountID: UUID? = nil
    ) {
        self.month = month
        self.inclusion = inclusion
        self.accountID = accountID
    }
}

struct TransactionSessionState {
    var searchText = ""
    var accountFilterID: UUID?
    var categoryFilter: CategoryFilter = .all
    var assignmentFilter: AssignmentFilter = .all
    var householdInclusionFilter: HouseholdInclusionFilter = .all
    var presetMonth: YearMonth?
    var sortMode: TransactionSortMode = .dateDesc
    var showingRecentlyDeleted = false

    mutating func reset() {
        self = Self()
    }

    mutating func apply(_ preset: TransactionFilterPreset) {
        if let accountID = preset.accountID {
            searchText = ""
            accountFilterID = accountID
            categoryFilter = .all
            assignmentFilter = .all
            householdInclusionFilter = .all
            presetMonth = nil
            sortMode = .dateDesc
            showingRecentlyDeleted = false
            return
        }

        if let month = preset.month { presetMonth = month }
        householdInclusionFilter = preset.inclusion
    }
}

struct TransactionsView: View {
    var resetSignal: Int = 0
    var preset: TransactionFilterPreset? = nil
    var onPresetConsumed: ((TransactionFilterPreset) -> Void)? = nil

    @Environment(\.modelContext) private var modelContext
    @Query private var accounts: [Account]
    @Query(filter: #Predicate<Category> { $0.deletedAt == nil }) private var categories: [Category]
    @Query(filter: #Predicate<PendingImport> { $0.resolvedTransaction == nil },
           sort: \PendingImport.createdAt, order: .reverse)
    private var pendingImports: [PendingImport]

    @Binding var sessionState: TransactionSessionState

    @State private var appliedResetSignal = 0
    @State private var promotionsModel = PromotionLedgerViewModel()

    /// Cuántas promos vivas tiene cada tx (badge discreto en la fila). Las
    /// adjudicaciones a promos eliminadas son huérfanas: no cuentan aquí
    /// (se retiran desde Settings → Adjudicaciones huérfanas).
    private var promotionCountsByTransaction: [UUID: Int] {
        let livePromotionIDs = Set(promotionsModel.ledger.promotions
            .filter { $0.deletedAt == nil }.map(\.id))
        var counts: [UUID: Int] = [:]
        for attribution in promotionsModel.ledger.attributions
        where attribution.deletedAt == nil && livePromotionIDs.contains(attribution.promotionID) {
            counts[attribution.transactionID, default: 0] += 1
        }
        return counts
    }

    private func ledgerRow(for tx: Transaction, wideLayout: Bool) -> some View {
        TransactionLedgerRow(
            transaction: tx,
            isDeletedMode: sessionState.showingRecentlyDeleted,
            isSelectionMode: selectionMode,
            isSelected: selectedIDs.contains(tx.id),
            onToggleSelection: { toggleSelection(tx) },
            wideLayout: wideLayout,
            showsAccount: sessionState.accountFilterID == nil,
            promotionCount: promotionCountsByTransaction[tx.id] ?? 0,
            onOpenDetail: { editingTransaction = tx },
            onOpenCategoryPicker: {
                editingTransaction = tx
            },
            onDelete: { softDelete(tx) },
            onRestore: { restore(tx) },
            onApplyToSimilar: { beginApplyToSimilar(tx) },
            onToggleHousehold: { toggleHouseholdInclusion(tx) }
        )
    }
    @State private var allTransactions: [Transaction] = []
    @State private var deletedTransactions: [Transaction] = []
    @State private var consumedPresetID: UUID?
    @State private var selectionMode = false
    @State private var selectedIDs: Set<UUID> = []

    @State private var dayGroups: [TransactionDayGroup] = []
    @State private var lastTxCount: Int = 0

    @State private var editingTransaction: Transaction?
    @State private var showingManualTransaction = false
    @State private var pendingApplyToSimilar: PendingApplyToSimilar?
    @State private var pendingApplyCandidate: PendingApplyToSimilar?

    private var parentCategories: [Category] {
        var seen = Set<String>()
        return categories
            .filter { $0.parent == nil }
            .sorted { $0.name < $1.name }
            .filter { seen.insert($0.name).inserted }
    }

    private func children(of parent: Category) -> [Category] {
        categories
            .filter { $0.parent?.id == parent.id }
            .sorted { $0.name < $1.name }
    }

    /// Applies a preset exactly once (token-guarded), then hands control back so
    /// the user can edit filters. Never reapplies on later appearances, reset
    /// signals, or direct sidebar navigation.
    private func consumePresetIfNeeded() {
        guard let preset, preset.id != consumedPresetID else { return }
        consumedPresetID = preset.id
        sessionState.apply(preset)
        onPresetConsumed?(preset)
    }

    private func fetchTransactions() {
        guard !accounts.isEmpty else {
            allTransactions = []
            deletedTransactions = []
            return
        }
        let activeDesc = FetchDescriptor<Transaction>(
            predicate: #Predicate<Transaction> { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.postedAt, order: .reverse)]
        )
        allTransactions = (try? modelContext.fetch(activeDesc)) ?? []

        let deletedDesc = FetchDescriptor<Transaction>(
            predicate: #Predicate<Transaction> { $0.deletedAt != nil },
            sortBy: [SortDescriptor(\.postedAt, order: .reverse)]
        )
        deletedTransactions = (try? modelContext.fetch(deletedDesc)) ?? []
    }

    private func recomputeDisplay() {
        let active = sessionState.showingRecentlyDeleted ? deletedTransactions : allTransactions

        if accounts.isEmpty {
            dayGroups = []
            lastTxCount = 0
            return
        }

        var result = Array(active)

        if let filterID = sessionState.accountFilterID {
            result = result.filter { $0.account?.id == filterID }
        }

        switch sessionState.categoryFilter {
        case .all:
            break
        case .uncategorized:
            result = result.filter { $0.category == nil }
        case .parent(let id):
            let childIDs = Set(categories.filter { $0.parent?.id == id }.map(\.id))
            result = result.filter { tx in
                tx.category?.id == id || childIDs.contains(tx.category?.id ?? UUID())
            }
        case .specific(let id):
            result = result.filter { tx in tx.category?.id == id }
        }

        if let assignment = sessionState.assignmentFilter.assignment {
            result = result.filter {
                HouseholdSettlementReportService.isSettlementEligible($0)
                    && $0.expenseAssignment == assignment
            }
        }

        switch sessionState.householdInclusionFilter {
        case .all:
            break
        case .included:
            result = result.filter {
                HouseholdSettlementReportService.isSettlementEligible($0)
                    && $0.isIncludedInHouseholdSettlement
            }
        case .notIncluded:
            result = result.filter {
                HouseholdSettlementReportService.isSettlementEligible($0)
                    && !$0.isIncludedInHouseholdSettlement
            }
        }

        if let month = sessionState.presetMonth {
            let calendar = Calendar(identifier: .gregorian)
            result = result.filter { calendar.isDate($0.postedAt, equalTo: month.startDate, toGranularity: .month) }
        }

        if !sessionState.searchText.isEmpty {
            result = result.filter {
                $0.descriptionRaw.localizedCaseInsensitiveContains(sessionState.searchText) ||
                $0.merchantNormalized.localizedCaseInsensitiveContains(sessionState.searchText)
            }
        }

        var groups = TransactionDayGroup.group(result)
        groups = groups.map { group in
            TransactionDayGroup(
                date: group.date,
                transactions: group.transactions.sorted(by: sessionState.sortMode.rowSort)
            )
        }
        if sessionState.sortMode.groupsReversed {
            groups.reverse()
        }

        dayGroups = groups
        lastTxCount = active.count
    }

    var body: some View {
        VStack(spacing: 0) {
            TransactionFilterBar(
                searchText: $sessionState.searchText,
                accountFilterID: $sessionState.accountFilterID,
                categoryFilter: $sessionState.categoryFilter,
                assignmentFilter: $sessionState.assignmentFilter,
                householdInclusionFilter: $sessionState.householdInclusionFilter,
                presetMonth: $sessionState.presetMonth,
                sortMode: $sessionState.sortMode,
                showingRecentlyDeleted: $sessionState.showingRecentlyDeleted,
                selectionMode: $selectionMode,
                hasSelection: !selectedIDs.isEmpty,
                onToggleSelection: {
                    selectionMode.toggle()
                    if !selectionMode { selectedIDs.removeAll() }
                },
                deletedCount: deletedTransactions.count,
                visibleCount: dayGroups.reduce(0) { $0 + $1.count },
                accounts: accounts,
                parentCategories: parentCategories,
                childrenOf: children(of:),
                onAssignSelected: applyAssignment,
                onAddTransaction: { showingManualTransaction = true }
            )
            if !pendingImports.isEmpty {
                PendingReviewSection(pendings: pendingImports) { _ in
                    try? modelContext.save()
                    fetchTransactions()
                    recomputeDisplay()
                }
            }
            groupedLedger
        }
        .background(.clear)
        .navigationTitle("Transactions")
        .sheet(isPresented: $showingManualTransaction) {
            ManualTransactionSheet(defaultAccountID: sessionState.accountFilterID) {
                fetchTransactions()
                recomputeDisplay()
            }
        }
        .sheet(item: $editingTransaction) { tx in
            TransactionDetailSheet(transaction: tx) { change in
                pendingApplyCandidate = PendingApplyToSimilar(
                    transaction: change.transaction,
                    category: change.category,
                    keyword: change.keyword
                )
            }
        }
        .sheet(item: $pendingApplyToSimilar) { pending in
            ApplyToSimilarView(
                transaction: pending.transaction,
                category: pending.category,
                keyword: pending.keyword
            )
        }
        .onChange(of: editingTransaction) {
            if editingTransaction == nil, let candidate = pendingApplyCandidate {
                let resolved = candidate
                pendingApplyCandidate = nil
                DispatchQueue.main.async {
                    pendingApplyToSimilar = resolved
                }
            }
        }
        .onChange(of: sessionState.accountFilterID) { recomputeDisplay() }
        .onChange(of: sessionState.categoryFilter) { recomputeDisplay() }
        .onChange(of: sessionState.assignmentFilter) { recomputeDisplay() }
        .onChange(of: sessionState.householdInclusionFilter) { recomputeDisplay() }
        .onChange(of: sessionState.presetMonth) { recomputeDisplay() }
        .onChange(of: sessionState.searchText) { recomputeDisplay() }
        .onChange(of: sessionState.sortMode) { recomputeDisplay() }
        .onChange(of: sessionState.showingRecentlyDeleted) {
            if sessionState.showingRecentlyDeleted {
                selectionMode = false
                selectedIDs.removeAll()
            }
            recomputeDisplay()
        }
        .onAppear {
            resetSessionIfNeeded()
            consumePresetIfNeeded()
            fetchTransactions()
            recomputeDisplay()
            promotionsModel.reload(context: modelContext)
        }
        .onReceive(NotificationCenter.default.publisher(for: PromotionLedgerStore.didChangeNotification)) { _ in
            promotionsModel.reload(context: modelContext)
        }
        .onChange(of: preset) {
            consumePresetIfNeeded()
            fetchTransactions()
            recomputeDisplay()
        }
        .onChange(of: accounts.count) {
            fetchTransactions()
            recomputeDisplay()
        }
        .onChange(of: resetSignal) {
            resetSessionIfNeeded()
            fetchTransactions()
        }
        .onChange(of: accounts.map(\.id)) {
            let activeAccountIDs = Set(accounts.map(\.id))
            if let id = sessionState.accountFilterID, !activeAccountIDs.contains(id) {
                sessionState.accountFilterID = nil
            }
        }
        .onChange(of: categories.map(\.id)) {
            let activeIDs = Set(categories.map(\.id))
            switch sessionState.categoryFilter {
            case .parent(let id), .specific(let id):
                if !activeIDs.contains(id) {
                    sessionState.categoryFilter = .all
                }
            default:
                break
            }
        }
    }

    private func resetSessionIfNeeded() {
        guard appliedResetSignal != resetSignal else { return }
        appliedResetSignal = resetSignal
        sessionState.reset()
        selectionMode = false
        selectedIDs.removeAll()
        editingTransaction = nil
        pendingApplyToSimilar = nil
        pendingApplyCandidate = nil
        showingManualTransaction = false
    }

    private var groupedLedger: some View {
        GeometryReader { geometry in
            if dayGroups.isEmpty {
                EmptyStateView(
                    icon: "list.bullet.rectangle",
                    title: sessionState.showingRecentlyDeleted ? "No deleted transactions" : "No transactions",
                    subtitle: sessionState.showingRecentlyDeleted ? nil : "Import a statement to get started"
                )
            } else {
                let wideLayout = geometry.size.width >= 900
                VStack(spacing: 0) {
                    if wideLayout {
                        TransactionLedgerColumnHeader(showsAccount: sessionState.accountFilterID == nil)
                            .padding(.horizontal, 12)
                    }
                    ScrollView {
                        LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                            ForEach(dayGroups) { group in
                                Section {
                                    ForEach(Array(group.transactions.enumerated()), id: \.element.id) { index, tx in
                                        ledgerRow(for: tx, wideLayout: wideLayout)
                                        if index < group.transactions.count - 1 {
                                            DashboardSeparator()
                                        }
                                    }
                                } header: {
                                    TransactionDateGroupHeader(group: group)
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                    .scrollContentBackground(.hidden)
                    .background(.clear)
                }
            }
        }
    }

    private func softDelete(_ tx: Transaction) {
        tx.deletedAt = Date.now
        tx.touch()
        try? modelContext.save()
        fetchTransactions()
        recomputeDisplay()
    }

    private func toggleSelection(_ tx: Transaction) {
        if selectedIDs.contains(tx.id) {
            selectedIDs.remove(tx.id)
        } else {
            selectedIDs.insert(tx.id)
        }
    }

    private func applyAssignment(_ assignment: ExpenseAssignment) {
        guard !selectedIDs.isEmpty else { return }
        var purgedDueDateIDs: Set<UUID> = []
        for tx in allTransactions where selectedIDs.contains(tx.id) && HouseholdSettlementReportService.isSettlementEligible(tx) {
            // Any explicit quick assignment (including Mine) proves Household intent:
            // include the transaction and set the assignment.
            tx.setHouseholdScope(.included)
            // Reassigning away from Fer clears any due-date override.
            if assignment != .partner, tx.resolvedHouseholdAllocation == .partner {
                purgedDueDateIDs.insert(tx.id)
            }
            tx.setExpenseAssignment(assignment)
            tx.touch()
        }
        try? modelContext.save()
        if !purgedDueDateIDs.isEmpty {
            try? SettlementDueDateService.purge(for: purgedDueDateIDs, context: modelContext)
        }
        selectedIDs.removeAll()
        fetchTransactions()
        recomputeDisplay()
    }

    private func toggleHouseholdInclusion(_ tx: Transaction) {
        tx.setHouseholdScope(tx.isIncludedInHouseholdSettlement ? .excluded : .included)
        tx.touch()
        try? modelContext.save()
        fetchTransactions()
        recomputeDisplay()
    }

    private func restore(_ tx: Transaction) {
        tx.deletedAt = nil
        tx.touch()
        try? modelContext.save()
        fetchTransactions()
        recomputeDisplay()
    }

    private func beginApplyToSimilar(_ tx: Transaction) {
        guard let category = tx.category else { return }
        let keyword = MerchantExtractor.extractMerchant(from: tx.descriptionRaw)
        pendingApplyToSimilar = PendingApplyToSimilar(
            transaction: tx,
            category: category,
            keyword: keyword
        )
    }
}
