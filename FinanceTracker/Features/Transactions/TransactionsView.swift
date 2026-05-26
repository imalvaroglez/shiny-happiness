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
    case parent(Category)
    case specific(Category)
}

struct TransactionsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Transaction> { $0.deletedAt == nil },
           sort: \Transaction.postedAt, order: .reverse) private var allTransactions: [Transaction]
    @Query(filter: #Predicate<Transaction> { $0.deletedAt != nil },
           sort: \Transaction.postedAt, order: .reverse) private var deletedTransactions: [Transaction]
    @Query private var accounts: [Account]
    @Query(filter: #Predicate<Category> { $0.deletedAt == nil }) private var categories: [Category]
    @Query(filter: #Predicate<PendingImport> { $0.resolvedTransaction == nil },
           sort: \PendingImport.createdAt, order: .reverse)
    private var pendingImports: [PendingImport]

    @State private var searchText = ""
    @State private var accountFilterID: UUID?
    @State private var categoryFilter: CategoryFilter = .all
    @State private var sortMode: TransactionSortMode = .dateDesc
    @State private var showingRecentlyDeleted = false

    @State private var dayGroups: [TransactionDayGroup] = []
    @State private var lastTxCount: Int = 0

    @State private var editingTransaction: Transaction?
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

    private func recomputeDisplay() {
        let active = showingRecentlyDeleted ? deletedTransactions : allTransactions
        var result = Array(active)

        if let filterID = accountFilterID {
            result = result.filter { $0.account?.id == filterID }
        }

        switch categoryFilter {
        case .all:
            break
        case .uncategorized:
            result = result.filter { $0.category == nil }
        case .parent(let cat):
            result = result.filter { tx in
                tx.category?.id == cat.id || tx.category?.parent?.id == cat.id
            }
        case .specific(let cat):
            result = result.filter { tx in
                tx.category?.id == cat.id || tx.category?.parent?.id == cat.id
            }
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
                }
            }
            groupedLedger
        }
        .searchable(text: $searchText, prompt: "Search transactions")
        .navigationTitle("Transactions")
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
        .onChange(of: allTransactions.count) { _, new in
            guard new != lastTxCount else { return }
            recomputeDisplay()
        }
        .onChange(of: deletedTransactions.count) { _, new in
            guard new != lastTxCount else { return }
            recomputeDisplay()
        }
        .onAppear { recomputeDisplay() }
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
        try? modelContext.save()
    }

    private func restore(_ tx: Transaction) {
        tx.deletedAt = nil
        tx.touch()
        try? modelContext.save()
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

