import SwiftUI
import SwiftData

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
    @Query private var categories: [Category]
    @Query(filter: #Predicate<PendingImport> { $0.resolvedTransaction == nil },
           sort: \PendingImport.createdAt, order: .reverse)
    private var pendingImports: [PendingImport]
    @State private var searchText = ""
    @State private var selectedTransaction: Transaction?
    @State private var showingCategoryPicker = false
    @State private var showingApplyToSimilar = false
    @State private var pendingCategory: Category?
    @State private var pendingKeyword: String?
    @State private var accountFilter: Account?
    @State private var categoryFilter: CategoryFilter = .all
    @State private var sortOrder = [KeyPathComparator(\Transaction.postedAt, order: .reverse)]
    @State private var showingRecentlyDeleted = false
    @State private var displayTransactions: [Transaction] = []
    @State private var lastTxCount: Int = 0

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
        var result = active

        if let filter = accountFilter {
            result = result.filter { $0.account?.id == filter.id }
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

        displayTransactions = result.sorted(using: sortOrder)
        lastTxCount = active.count
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            if !pendingImports.isEmpty {
                PendingReviewSection(pendings: pendingImports) { _ in
                    try? modelContext.save()
                }
            }
            tableContent
        }
        .searchable(text: $searchText, prompt: "Search transactions")
        .navigationTitle("Transactions")
        .sheet(isPresented: $showingCategoryPicker) {
            if let tx = selectedTransaction {
                CategoryPickerView(transaction: tx) { category, keyword in
                    tx.category = category
                    tx.touch()
                    LearningHooks.recordCategorization(
                        keyword: keyword,
                        category: category,
                        sourceDescription: tx.descriptionRaw,
                        in: modelContext
                    )
                    try? modelContext.save()
                    recomputeDisplay()
                    pendingCategory = category
                    pendingKeyword = keyword
                }
            }
        }
        .onChange(of: showingCategoryPicker) {
            if !showingCategoryPicker, pendingCategory != nil, pendingKeyword != nil {
                showingApplyToSimilar = true
            }
        }
        .sheet(isPresented: $showingApplyToSimilar) {
            if let tx = selectedTransaction, let cat = pendingCategory {
                ApplyToSimilarView(
                    transaction: tx,
                    category: cat,
                    keyword: pendingKeyword
                )
            }
        }
        .onChange(of: showingApplyToSimilar) {
            if !showingApplyToSimilar {
                pendingCategory = nil
                pendingKeyword = nil
            }
        }
        .onChange(of: accountFilter) { recomputeDisplay() }
        .onChange(of: categoryFilter) { recomputeDisplay() }
        .onChange(of: searchText) { recomputeDisplay() }
        .onChange(of: sortOrder) { recomputeDisplay() }
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

    private var filterBar: some View {
        HStack {
            Picker(selection: $accountFilter) {
                Text("All Accounts").tag(nil as Account?)
                ForEach(accounts) { account in
                    Text(account.displayName).tag(account as Account?)
                }
            } label: { EmptyView() }
            .frame(width: 200)

            Picker(selection: $categoryFilter) {
                Text("All Categories").tag(CategoryFilter.all)
                Text("Uncategorized").tag(CategoryFilter.uncategorized)
                Divider()
                ForEach(parentCategories) { parent in
                    Section(parent.name) {
                        Text("All \(parent.name)")
                            .tag(CategoryFilter.parent(parent))
                        ForEach(children(of: parent)) { sub in
                            Text(sub.name).tag(CategoryFilter.specific(sub))
                        }
                    }
                }
            } label: { EmptyView() }
            .frame(width: 240)

            Spacer()

            if !deletedTransactions.isEmpty {
                Toggle(isOn: $showingRecentlyDeleted) {
                    Text("Recently Deleted (\(deletedTransactions.count))")
                        .font(.caption)
                }
                .toggleStyle(.button)
                .tint(showingRecentlyDeleted ? .red : .secondary)
            }

            Text("\(displayTransactions.count) transactions")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var tableContent: some View {
        Table(displayTransactions, sortOrder: $sortOrder) {
            TableColumn("Date", value: \.postedAt) { tx in
                EditableDateCell(date: tx.postedAt) { newDate in
                    tx.postedAt = newDate
                    tx.touch()
                    try? modelContext.save()
                }
            }
            .width(min: 110, ideal: 120)

            TableColumn("Description", value: \.descriptionRaw) { tx in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        EditableTextCell(initialText: tx.descriptionRaw, placeholder: "Description") { newText in
                            tx.descriptionRaw = newText
                            tx.merchantNormalized = newText
                            tx.touch()
                            try? modelContext.save()
                        }
                        if let nickname = tx.account?.displayName {
                            Text(nickname)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    Menu {
                        if showingRecentlyDeleted {
                            Button("Restore") {
                                tx.deletedAt = nil
                                tx.touch()
                                try? modelContext.save()
                            }
                        } else {
                            Button("Delete", role: .destructive) {
                                tx.deletedAt = Date.now
                                tx.touch()
                                try? modelContext.save()
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundStyle(.tertiary)
                    }
                    .menuStyle(.borderlessButton)
                }
            }
            .width(min: 200, ideal: 350)

            TableColumn("Amount", value: \.amount) { tx in
                EditableAmountCell(amount: tx.amount, currencyCode: tx.currency) { newAmount in
                    tx.amount = newAmount
                    tx.touch()
                    try? modelContext.save()
                }
            }
            .width(min: 110, ideal: 130)

            TableColumn("Category", value: \.categoryName) { tx in
                Button {
                    selectedTransaction = tx
                    showingCategoryPicker = true
                } label: {
                    categoryBadge(for: tx)
                }
                .buttonStyle(.plain)
            }
            .width(min: 130, ideal: 160)
        }
    }

    @ViewBuilder
    private func categoryBadge(for tx: Transaction) -> some View {
        let label = tx.category?.name ?? "Uncategorized"
        let color: Color = tx.category.map { CategoryPalette.color(for: $0.name) } ?? .secondary
        Text(label)
            .font(.caption)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.12)))
            .overlay(Capsule().stroke(color.opacity(0.25), lineWidth: 0.5))
    }

    private static let _mxnFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "MXN"
        return f
    }()

    private func formatMoney(_ amount: Decimal) -> String {
        Self._mxnFormatter.string(from: amount as NSDecimalNumber) ?? "$0.00"
    }
}
