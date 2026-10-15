import SwiftUI

struct TransactionFilterBar: View {
    @State private var showingFilters = false

    @Binding var searchText: String
    @Binding var accountFilterID: UUID?
    @Binding var categoryFilter: CategoryFilter
    @Binding var assignmentFilter: AssignmentFilter
    @Binding var householdInclusionFilter: HouseholdInclusionFilter
    @Binding var presetMonth: YearMonth?
    @Binding var sortMode: TransactionSortMode
    @Binding var showingRecentlyDeleted: Bool
    @Binding var selectionMode: Bool

    let hasSelection: Bool
    let onToggleSelection: () -> Void
    let deletedCount: Int
    let visibleCount: Int
    let accounts: [Account]
    let parentCategories: [Category]
    let childrenOf: (Category) -> [Category]
    let onAssignSelected: (ExpenseAssignment) -> Void
    let onAddTransaction: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button {
                showingFilters.toggle()
            } label: {
                Label(filterButtonTitle, systemImage: "line.3.horizontal.decrease.circle")
                    .labelStyle(.titleAndIcon)
            }
            .popover(isPresented: $showingFilters, arrowEdge: .bottom) {
                filterPopover
                    .frame(width: 390)
                    .padding(14)
            }

            sortMenu

            TextField("Search transactions", text: $searchText)
                .textFieldStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
                .frame(minWidth: 90, maxWidth: 260)
                .layoutPriority(1)

            Spacer(minLength: 4)

            if selectionMode {
                Menu {
                    Button("Mark User") { onAssignSelected(.user) }
                    Button("Mark Shared") { onAssignSelected(.shared) }
                    Button("Mark Partner") { onAssignSelected(.partner) }
                } label: {
                    Label("Assign", systemImage: "person.2")
                }
                .disabled(!hasSelection)
            }

            if !showingRecentlyDeleted {
                Button(selectionMode ? "Done" : "Select", action: onToggleSelection)
            }

            Button(action: onAddTransaction) {
                Label("Add", systemImage: "plus")
            }
            .accessibilityLabel("Add Transaction")
            .help("Add Transaction")

            Spacer(minLength: 4)

            HStack(spacing: 5) {
                Text(visibleCount == 1 ? "1 movimiento" : "\(visibleCount) movimientos")
                    .foregroundStyle(.secondary)
                if let filteredAccountName {
                    Text("· \(filteredAccountName)")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .font(.caption)
            .lineLimit(1)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 190, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var sortMenu: some View {
        Menu {
            ForEach(TransactionSortMode.allCases, id: \.self) { mode in
                Button {
                    sortMode = mode
                } label: {
                    if sortMode == mode {
                        Label(mode.displayName, systemImage: "checkmark")
                    } else {
                        Text(mode.displayName)
                    }
                }
            }
        } label: {
            Label(sortMode.displayName, systemImage: "arrow.up.arrow.down")
                .labelStyle(.titleAndIcon)
        }
        .menuStyle(.button)
    }

    private var filterPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Filters")
                    .font(.headline)
                Spacer()
                if hasClearableCriteria {
                    Button("Clear Filters", action: clearFilters)
                        .font(.caption)
                }
            }

            filterRow("Account") {
                Picker("Account", selection: $accountFilterID) {
                    Text("All Accounts").tag(nil as UUID?)
                    ForEach(accounts, id: \.id) { account in
                        Text(account.displayName).tag(account.id as UUID?)
                    }
                }
            }

            filterRow("Category") {
                Picker(selection: $categoryFilter) {
                    Text("All Categories").tag(CategoryFilter.all)
                    Text("Uncategorized").tag(CategoryFilter.uncategorized)
                    Divider()
                    ForEach(parentCategories, id: \.id) { parent in
                        Section(parent.localizedName) {
                            Text("Todas las de \(parent.localizedName)")
                                .tag(CategoryFilter.parent(parent.id))
                            ForEach(childrenOf(parent), id: \.id) { subcategory in
                                Text(subcategory.localizedName).tag(CategoryFilter.specific(subcategory.id))
                            }
                        }
                    }
                } label: {
                    Text("Category")
                }
            }

            filterRow("Assignment") {
                Picker("Assignment", selection: $assignmentFilter) {
                    ForEach(AssignmentFilter.allCases, id: \.self) { filter in
                        Text(filter.displayName).tag(filter)
                    }
                }
            }

            filterRow("Household") {
                Picker("Household", selection: $householdInclusionFilter) {
                    ForEach(HouseholdInclusionFilter.allCases, id: \.self) { filter in
                        Text(filter.displayName).tag(filter)
                    }
                }
            }

            if deletedCount > 0 {
                filterRow("Recently deleted (\(deletedCount))") {
                    Toggle("Recently deleted", isOn: $showingRecentlyDeleted)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }
        }
    }

    private func filterRow<Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 124, alignment: .leading)
                .lineLimit(2)
            content()
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 254, alignment: .leading)
        }
    }

    private var activeFilterCount: Int {
        var count = 0
        if presetMonth != nil { count += 1 }
        if accountFilterID != nil { count += 1 }
        if categoryFilter != .all { count += 1 }
        if assignmentFilter != .all { count += 1 }
        if householdInclusionFilter != .all { count += 1 }
        if showingRecentlyDeleted { count += 1 }
        return count
    }

    private var filterButtonTitle: String {
        activeFilterCount == 0 ? String(localized: "Filters") : String(localized: "Filters (\(activeFilterCount))")
    }

    private var filteredAccountName: String? {
        guard let accountFilterID else { return nil }
        return accounts.first { $0.id == accountFilterID }?.displayName
    }

    private var hasClearableCriteria: Bool {
        activeFilterCount > 0 || !searchText.isEmpty || sortMode != .dateDesc
    }

    private func clearFilters() {
        searchText = ""
        presetMonth = nil
        accountFilterID = nil
        categoryFilter = .all
        assignmentFilter = .all
        householdInclusionFilter = .all
        showingRecentlyDeleted = false
        sortMode = .dateDesc
    }
}
