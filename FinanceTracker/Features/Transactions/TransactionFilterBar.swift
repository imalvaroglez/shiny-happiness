import SwiftUI

struct TransactionFilterBar: View {
    @Binding var accountFilterID: UUID?
    @Binding var categoryFilter: CategoryFilter
    @Binding var sortMode: TransactionSortMode
    @Binding var showingRecentlyDeleted: Bool
    let deletedCount: Int
    let visibleCount: Int
    let accounts: [Account]
    let parentCategories: [Category]
    let childrenOf: (Category) -> [Category]

    var body: some View {
        HStack {
            Picker(selection: $accountFilterID) {
                Text("All Accounts").tag(nil as UUID?)
                ForEach(accounts, id: \.id) { account in
                    Text(account.displayName).tag(account.id as UUID?)
                }
            } label: { EmptyView() }
            .frame(width: 200)

            Picker(selection: $categoryFilter) {
                Text("All Categories").tag(CategoryFilter.all)
                Text("Uncategorized").tag(CategoryFilter.uncategorized)
                Divider()
                ForEach(parentCategories, id: \.id) { parent in
                    Section(parent.name) {
                        Text("All \(parent.name)")
                            .tag(CategoryFilter.parent(parent))
                        ForEach(childrenOf(parent), id: \.id) { sub in
                            Text(sub.name).tag(CategoryFilter.specific(sub))
                        }
                    }
                }
            } label: { EmptyView() }
            .frame(width: 240)

            Picker("Sort", selection: $sortMode) {
                ForEach(TransactionSortMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .frame(width: 140)

            Spacer()

            if deletedCount > 0 {
                Toggle(isOn: $showingRecentlyDeleted) {
                    Text("Deleted (\(deletedCount))")
                        .font(.caption)
                }
                .toggleStyle(.button)
                .tint(showingRecentlyDeleted ? .red : .secondary)
            }

            Text("\(visibleCount) transactions")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
