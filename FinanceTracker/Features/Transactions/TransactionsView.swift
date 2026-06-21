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

struct TransactionsView: View {
    var resetSignal: Int = 0

    @Environment(\.modelContext) private var modelContext
    @Query private var accounts: [Account]
    @Query(filter: #Predicate<Category> { $0.deletedAt == nil }) private var categories: [Category]
    @Query(filter: #Predicate<PendingImport> { $0.resolvedTransaction == nil },
           sort: \PendingImport.createdAt, order: .reverse)
    private var pendingImports: [PendingImport]

    @State private var allTransactions: [Transaction] = []
    @State private var deletedTransactions: [Transaction] = []
    @State private var searchText = ""
    @State private var accountFilterID: UUID?
    @State private var categoryFilter: CategoryFilter = .all
    @State private var sortMode: TransactionSortMode = .dateDesc
    @State private var showingRecentlyDeleted = false

    @State private var dayGroups: [TransactionDayGroup] = []
    @State private var lastTxCount: Int = 0

    @State private var editingTransaction: Transaction?
    @State private var showingManualTransaction = false
    @State private var pendingApplyToSimilar: PendingApplyToSimilar?
    @State private var pendingApplyCandidate: PendingApplyToSimilar?
    @State private var actionError: String?

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
        actionError = nil
        let active = showingRecentlyDeleted ? deletedTransactions : allTransactions

        if accounts.isEmpty {
            dayGroups = []
            lastTxCount = 0
            return
        }

        var result = Array(active)

        if let filterID = accountFilterID {
            result = result.filter { $0.account?.id == filterID }
        }

        switch categoryFilter {
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

        if !searchText.isEmpty {
            result = result.filter {
                $0.descriptionRaw.localizedCaseInsensitiveContains(searchText) ||
                $0.merchantNormalized.localizedCaseInsensitiveContains(searchText)
            }
        }

        var groups = TransactionDayGroup.group(result)
        groups = groups.map { group in
            TransactionDayGroup(
                date: group.date,
                transactions: group.transactions.sorted(by: sortMode.rowSort)
            )
        }
        if sortMode.groupsReversed {
            groups.reverse()
        }

        dayGroups = groups
        lastTxCount = active.count
    }

    var body: some View {
        VStack(spacing: 0) {
            if let actionError {
                Text(actionError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
            }
            TransactionFilterBar(
                accountFilterID: $accountFilterID,
                categoryFilter: $categoryFilter,
                sortMode: $sortMode,
                showingRecentlyDeleted: $showingRecentlyDeleted,
                deletedCount: deletedTransactions.count,
                visibleCount: dayGroups.reduce(0) { $0 + $1.count },
                accounts: accounts,
                parentCategories: parentCategories,
                childrenOf: children(of:)
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
        .searchable(text: $searchText, prompt: "Search transactions")
        .navigationTitle("Transactions")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingManualTransaction = true
                } label: {
                    Label("Add Transaction", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingManualTransaction) {
            ManualTransactionSheet(defaultAccountID: accountFilterID) {
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
        .onChange(of: accountFilterID) { recomputeDisplay() }
        .onChange(of: categoryFilter) { recomputeDisplay() }
        .onChange(of: searchText) { recomputeDisplay() }
        .onChange(of: sortMode) { recomputeDisplay() }
        .onChange(of: showingRecentlyDeleted) { recomputeDisplay() }
        .onAppear {
            fetchTransactions()
            recomputeDisplay()
        }
        .onChange(of: accounts.count) {
            fetchTransactions()
            recomputeDisplay()
        }
        .onChange(of: resetSignal) {
            accountFilterID = nil
            categoryFilter = .all
            editingTransaction = nil
            pendingApplyToSimilar = nil
            pendingApplyCandidate = nil
            showingManualTransaction = false
            showingRecentlyDeleted = false
            searchText = ""
            fetchTransactions()
        }
        .onChange(of: accounts.map(\.id)) {
            let activeAccountIDs = Set(accounts.map(\.id))
            if let id = accountFilterID, !activeAccountIDs.contains(id) {
                accountFilterID = nil
            }
        }
        .onChange(of: categories.map(\.id)) {
            let activeIDs = Set(categories.map(\.id))
            switch categoryFilter {
            case .parent(let id), .specific(let id):
                if !activeIDs.contains(id) {
                    categoryFilter = .all
                }
            default:
                break
            }
        }
    }

    private var groupedLedger: some View {
        Group {
            if dayGroups.isEmpty {
                EmptyStateView(
                    icon: "list.bullet.rectangle",
                    title: showingRecentlyDeleted ? "No deleted transactions" : "No transactions",
                    subtitle: showingRecentlyDeleted ? nil : "Import a statement to get started"
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                        ForEach(dayGroups) { group in
                            Section {
                                ForEach(Array(group.transactions.enumerated()), id: \.element.id) { index, tx in
                                    TransactionLedgerRow(
                                        transaction: tx,
                                        isDeletedMode: showingRecentlyDeleted,
                                        onOpenDetail: { editingTransaction = tx },
                                        onOpenCategoryPicker: {
                                            editingTransaction = tx
                                        },
                                        onDelete: { softDelete(tx) },
                                        onRestore: { restore(tx) },
                                        onApplyToSimilar: { beginApplyToSimilar(tx) }
                                    )
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
            }
        }
    }

    private func softDelete(_ tx: Transaction) {
        tx.deletedAt = Date.now
        tx.touch()
        do {
            try Persistence.save(modelContext)
        } catch {
            actionError = "Couldn't delete transaction: \(error.localizedDescription)"
            return
        }
        fetchTransactions()
        recomputeDisplay()
    }

    private func restore(_ tx: Transaction) {
        tx.deletedAt = nil
        tx.touch()
        do {
            try Persistence.save(modelContext)
        } catch {
            actionError = "Couldn't restore transaction: \(error.localizedDescription)"
            return
        }
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
