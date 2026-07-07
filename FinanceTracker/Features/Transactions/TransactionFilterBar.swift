import SwiftUI

struct TransactionFilterBar: View {
    @State private var showingFilters = false

    @Binding var accountFilterID: UUID?
    @Binding var categoryFilter: CategoryFilter
    @Binding var assignmentFilter: AssignmentFilter
    @Binding var sortMode: TransactionSortMode
    @Binding var showingRecentlyDeleted: Bool
    let deletedCount: Int
    let visibleCount: Int
    let accounts: [Account]
    let parentCategories: [Category]
    let childrenOf: (Category) -> [Category]

    var body: some View {
        HStack {
            Button {
                showingFilters.toggle()
            } label: {
                Label(filterButtonTitle, systemImage: "line.3.horizontal.decrease.circle")
                    .labelStyle(.titleAndIcon)
            }
            .popover(isPresented: $showingFilters, arrowEdge: .bottom) {
                filterPopover
                    .frame(width: 360)
                    .padding(16)
            }

            activeFilterChips

            Menu {
                Picker("Sort order", selection: $sortMode) {
                    ForEach(TransactionSortMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
            } label: {
                Label(sortMode.rawValue, systemImage: "arrow.up.arrow.down")
                    .labelStyle(.titleAndIcon)
            }
            .menuStyle(.button)

            if activeFilterCount > 0 {
                Button("Clear") {
                    clearFilters()
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Text("\(visibleCount) transactions")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var filterPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Filters")
                    .font(.headline)
                Spacer()
                if activeFilterCount > 0 {
                    Button("Clear") {
                        clearFilters()
                    }
                    .font(.caption)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Account")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Account", selection: $accountFilterID) {
                    Text("All Accounts").tag(nil as UUID?)
                    ForEach(accounts, id: \.id) { account in
                        Text(account.displayName).tag(account.id as UUID?)
                    }
                }
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Category")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker(selection: $categoryFilter) {
                    Text("All Categories").tag(CategoryFilter.all)
                    Text("Uncategorized").tag(CategoryFilter.uncategorized)
                    Divider()
                    ForEach(parentCategories, id: \.id) { parent in
                        Section(parent.name) {
                            Text("All \(parent.name)")
                                .tag(CategoryFilter.parent(parent.id))
                            ForEach(childrenOf(parent), id: \.id) { sub in
                                Text(sub.name).tag(CategoryFilter.specific(sub.id))
                            }
                        }
                    }
                } label: {
                    EmptyView()
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Assignment")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Assignment", selection: $assignmentFilter) {
                    ForEach(AssignmentFilter.allCases, id: \.self) { filter in
                        Text(filter.displayName).tag(filter)
                    }
                }
                .labelsHidden()
            }

            if deletedCount > 0 {
                Toggle(isOn: $showingRecentlyDeleted) {
                    Label("Recently Deleted (\(deletedCount))", systemImage: "trash")
                }
                .toggleStyle(.switch)
            }
        }
    }

    @ViewBuilder
    private var activeFilterChips: some View {
        if let selectedAccountName {
            filterChip(selectedAccountName)
        }
        if let selectedCategoryName {
            filterChip(selectedCategoryName)
        }
        if let selectedAssignmentName {
            filterChip(selectedAssignmentName)
        }
        if showingRecentlyDeleted {
            filterChip("Deleted")
        }
    }

    private func filterChip(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.thinMaterial, in: Capsule())
    }

    private var activeFilterCount: Int {
        var count = 0
        if accountFilterID != nil { count += 1 }
        if categoryFilter != .all { count += 1 }
        if assignmentFilter != .all { count += 1 }
        if showingRecentlyDeleted { count += 1 }
        return count
    }

    private var filterButtonTitle: String {
        activeFilterCount == 0 ? "Filters" : "Filters (\(activeFilterCount))"
    }

    private var selectedAccountName: String? {
        guard let accountFilterID else { return nil }
        return accounts.first { $0.id == accountFilterID }?.displayName
    }

    private var selectedCategoryName: String? {
        switch categoryFilter {
        case .all:
            return nil
        case .uncategorized:
            return "Uncategorized"
        case .parent(let id):
            if let parent = parentCategories.first(where: { $0.id == id }) {
                return "All \(parent.name)"
            } else {
                return nil
            }
        case .specific(let id):
            let allSubs = parentCategories.flatMap { childrenOf($0) }
            return allSubs.first(where: { $0.id == id })?.name
        }
    }

    private var selectedAssignmentName: String? {
        assignmentFilter == .all ? nil : assignmentFilter.displayName
    }

    private func clearFilters() {
        accountFilterID = nil
        categoryFilter = .all
        assignmentFilter = .all
        showingRecentlyDeleted = false
    }
}
