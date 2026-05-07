import SwiftUI
import SwiftData

enum CategoryFilter: Hashable {
    case all
    case uncategorized
    case specific(Category)
}

struct TransactionsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Transaction.postedAt, order: .reverse) private var allTransactions: [Transaction]
    @Query private var accounts: [Account]
    @Query private var categories: [Category]
    @State private var searchText = ""
    @State private var selectedTransaction: Transaction?
    @State private var showingCategoryPicker = false
    @State private var showingApplyToSimilar = false
    @State private var pendingCategory: Category?
    @State private var pendingKeyword: String?
    @State private var accountFilter: Account?
    @State private var categoryFilter: CategoryFilter = .all
    @State private var sortOrder = [KeyPathComparator(\Transaction.postedAt, order: .reverse)]

    private var sortedCategories: [Category] {
        categories.sorted { $0.name < $1.name }
    }

    private var filteredTransactions: [Transaction] {
        var result = allTransactions

        if let filter = accountFilter {
            result = result.filter { $0.account?.id == filter.id }
        }

        switch categoryFilter {
        case .all:
            break
        case .uncategorized:
            result = result.filter { $0.category == nil }
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

        return result
    }

    private var sortedTransactions: [Transaction] {
        filteredTransactions.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            tableContent
        }
        .searchable(text: $searchText, prompt: "Search transactions")
        .navigationTitle("Transactions")
        .sheet(isPresented: $showingCategoryPicker) {
            if let tx = selectedTransaction {
                CategoryPickerView(transaction: tx) { category, keyword in
                    tx.category = category
                    try? modelContext.save()
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
    }

    private var filterBar: some View {
        HStack {
            Picker(selection: $accountFilter) {
                Text("All Accounts").tag(nil as Account?)
                ForEach(accounts) { account in
                    Text(account.nickname).tag(account as Account?)
                }
            } label: { EmptyView() }
            .frame(width: 200)

            Picker(selection: $categoryFilter) {
                Text("All Categories").tag(CategoryFilter.all)
                Divider()
                Text("Uncategorized").tag(CategoryFilter.uncategorized)
                Divider()
                ForEach(sortedCategories) { cat in
                    Text(cat.name).tag(CategoryFilter.specific(cat))
                }
            } label: { EmptyView() }
            .frame(width: 220)

            Spacer()

            Text("\(filteredTransactions.count) transactions")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var tableContent: some View {
        Table(sortedTransactions, sortOrder: $sortOrder) {
            TableColumn("Date", value: \.postedAt) { tx in
                Text(tx.postedAt, format: .dateTime.day().month(.abbreviated).year())
                    .font(.system(.body, design: .monospaced))
            }
            .width(min: 110, ideal: 120)

            TableColumn("Description", value: \.descriptionRaw) { tx in
                VStack(alignment: .leading, spacing: 2) {
                    Text(tx.descriptionRaw)
                        .font(.body)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    if let nickname = tx.account?.nickname {
                        Text(nickname)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .width(min: 200, ideal: 350)

            TableColumn("Amount", value: \.amount) { tx in
                Text(formatMoney(tx.amount))
                    .font(.body.bold().monospacedDigit())
                    .foregroundStyle(tx.amount >= 0 ? .green : .red)
                    .frame(minWidth: 100, alignment: .trailing)
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
        if let cat = tx.category {
            Text(cat.name)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .glassEffect(.regular, in: .capsule)
        } else {
            Text("Uncategorized")
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .glassEffect(.regular, in: .capsule)
        }
    }

    private func formatMoney(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "MXN"
        return formatter.string(from: amount as NSDecimalNumber) ?? "$0.00"
    }
}
