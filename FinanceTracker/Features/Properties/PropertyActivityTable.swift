import SwiftUI

enum PropertyActivityLayout {
    static let spacing: CGFloat = 10
    static let selection: CGFloat = 22
    static let date: CGFloat = 54
    static let concept: CGFloat = 120
    static let account: CGFloat = 160
    static let type: CGFloat = 120
    static let responsibility: CGFloat = 172
    static let amount: CGFloat = 142
    static var minimumWidth: CGFloat { selection + date + concept + account + type + responsibility + amount + spacing * 6 }
}

struct PropertyActivityTable: View {
    let rows: [PropertyActivityRow]
    let household: Bool
    let residents: [PropertyResident]
    @Binding var filter: PropertyActivityFilter
    @Binding var selection: Set<UUID>
    @Binding var accountFilters: Set<String>
    @Binding var responsibilityFilters: Set<String>
    @Binding var identityFilters: Set<PropertyActivityIdentity>
    var assign: (Set<UUID>, PropertyAssignmentChoice) -> Void
    var adjustment: () -> Void
    var allowsUserAssignment = true
    var allowsPartnerAssignment = true
    @State private var sortColumn = PropertyActivitySortColumn.date
    @State private var sortDirection = PropertyActivitySortDirection.descending

    private var columnFilters: PropertyActivityColumnFilters {
        PropertyActivityColumnFilters(accounts: accountFilters, responsibilities: responsibilityFilters,
            identities: identityFilters)
    }

    private var filteredRows: [PropertyActivityRow] {
        PropertyActivitySorter.sorted(columnFilters.apply(to: rows), by: sortColumn, direction: sortDirection)
    }

    private var accountFilterOptions: [String] {
        let unavailableAccount = String(localized: "Account unavailable")
        return Set(rows.map { $0.account ?? unavailableAccount }).union(accountFilters)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var responsibilityFilterOptions: [String] {
        Set(rows.map(\.responsibility)).union(responsibilityFilters)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DashboardCardTokens.sectionSpacing) {
            PropertySectionHeading(title: "Linked transactions")
            activityControls
            PropertyTableCard {
                // One choice for header and all rows prevents mixed column/compact layouts.
                ViewThatFits(in: .horizontal) {
                    table(compact: false).frame(minWidth: PropertyActivityLayout.minimumWidth)
                    table(compact: true)
                }
            }
        }

        .onChange(of: filter) { selection = [] }
        .onChange(of: rows) { updateSelectionForVisibleRows() }
        .onChange(of: accountFilters) { updateSelectionForVisibleRows() }
        .onChange(of: responsibilityFilters) { updateSelectionForVisibleRows() }
        .onChange(of: identityFilters) { updateSelectionForVisibleRows() }
    }

    private var activityControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                activityFilterPicker
                Spacer(minLength: 8)
                selectionActions
            }
            VStack(alignment: .leading, spacing: 8) {
                activityFilterPicker
                selectionActions
            }
        }
    }

    private var activityFilterPicker: some View {
        Picker("", selection: $filter) {
            ForEach(PropertyActivityFilter.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
        }
        .labelsHidden()
        .accessibilityLabel(Text("Transactions shown"))
        .pickerStyle(.segmented)
        .frame(width: 260)
    }

    private var accountFilterMenu: some View {
        filterMenu(column: .account, clearTitle: "All source accounts", options: accountFilterOptions,
                   selection: $accountFilters)
    }

    private var responsibilityFilterMenu: some View {
        // The identity scopes deep links install ride the responsibility menu:
        // its badge and clear action cover both, while the label options stay
        // exactly the user-facing text filters.
        filterMenu(column: .responsibility, clearTitle: "All responsibilities", options: responsibilityFilterOptions,
                   selection: $responsibilityFilters, extraCount: identityFilters.count,
                   clear: { identityFilters.removeAll() })
    }

    private func filterMenu(column: PropertyActivitySortColumn, clearTitle: String, options: [String],
                            selection: Binding<Set<String>>, extraCount: Int = 0,
                            clear: (() -> Void)? = nil) -> some View {
        let selectedCount = selection.wrappedValue.count + extraCount
        return Menu {
            Button("Ascending") { sortColumn = column; sortDirection = .ascending }
            Button("Descending") { sortColumn = column; sortDirection = .descending }
            Divider()
            Button(LocalizedStringKey(clearTitle)) {
                selection.wrappedValue.removeAll()
                clear?()
            }
            .disabled(selectedCount == 0)
            if !options.isEmpty { Divider() }
            ForEach(options, id: \.self) { option in
                Button {
                    if selection.wrappedValue.contains(option) {
                        selection.wrappedValue.remove(option)
                    } else {
                        selection.wrappedValue.insert(option)
                    }
                } label: {
                    if selection.wrappedValue.contains(option) {
                        Label { Text(option) } icon: { Image(systemName: "checkmark") }
                    } else {
                        Text(option)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(LocalizedStringKey(column.rawValue))
                if sortColumn == column { Image(systemName: sortDirection.symbolName) }
                if selectedCount > 0 {
                    Text(verbatim: "\(selectedCount)").monospacedDigit()
                }
            }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel(Text(LocalizedStringKey(column.rawValue)))
        .accessibilityValue(Text("\(selectedCount) filters selected"))
        .accessibilityHint(Text("Select one or more values to filter the table."))
        .help(filterAccessibilityName(column.rawValue))
        .fixedSize(horizontal: true, vertical: false)
    }

    private func filterAccessibilityName(_ title: String) -> String {
        String(format: String(localized: "Filter by %@"), String(localized: String.LocalizationValue(title)))
    }

    @ViewBuilder private var selectionActions: some View {
        if !selection.isEmpty {
            HStack(spacing: 10) {
                Menu("Assign selected…") { choices(selection) }.fixedSize()
                InlineRowAction(title: String(localized: "Clear selection"), symbol: "xmark.circle") { selection = [] }
            }
        }
    }

    private func updateSelectionForVisibleRows() {
        selection.formIntersection(Set(filteredRows.filter(\.canAssign).map(\.id)))
    }

    private func table(compact: Bool) -> some View {
        let visibleRows = filteredRows
        return LazyVStack(alignment: .leading, spacing: 10) {
            Group {
                if compact { compactHeader }
                else { header }
            }.font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            if rows.isEmpty {
                Text(LocalizedStringKey(filter == .linked ? "No linked financial transactions." : "No eligible expenses to assign."))
                    .foregroundStyle(.secondary)
            } else if visibleRows.isEmpty {
                Text("No activity matches these filters.").foregroundStyle(.secondary)
            } else {
                ForEach(visibleRows) { row in
                    Divider()
                    if compact { compactRow(row) } else { wideRow(row) }
                    if let issue = row.issue {
                        HStack {
                            Label(issue, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.secondary)
                            if row.isClosed { Button("Record adjustment…", action: adjustment).buttonStyle(.link).font(.caption) }
                        }
                    }
                }
            }
            Divider()
            footer(summary: PropertyActivitySummary(rows: visibleRows))
        }
    }

    private func footer(summary: PropertyActivitySummary) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(columnFilters.isActive ? "Subtotal" : "Total"))
                    .font(.callout.weight(.semibold))
                Text("\(summary.count) transactions").font(.caption).foregroundStyle(.secondary)
                if summary.missingAmountCount > 0 {
                    Text("\(summary.missingAmountCount) amounts unavailable").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                if summary.totals.isEmpty { Text("—") }
                ForEach(summary.totals) { total in
                    HStack(spacing: 6) {
                        if summary.totals.count > 1 { Text(LocalizedStringKey(total.kind.rawValue)).foregroundStyle(.secondary) }
                        Text(total.currency).font(.caption).foregroundStyle(.secondary)
                        if let amount = total.amount {
                            Text(propertyMoneyText(amount, code: total.currency)).fontWeight(.semibold).monospacedDigit()
                        } else { Text("Amount unavailable").foregroundStyle(.secondary) }
                    }
                    .font(.callout).accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: PropertyActivityLayout.spacing) {
            Text("").frame(width: PropertyActivityLayout.selection)
            sortHeader(.date).frame(width: PropertyActivityLayout.date, alignment: .leading)
            sortHeader(.concept).frame(minWidth: PropertyActivityLayout.concept, maxWidth: .infinity, alignment: .leading)
            accountFilterMenu
                .frame(width: PropertyActivityLayout.account, alignment: .leading)
            sortHeader(.type).frame(width: PropertyActivityLayout.type, alignment: .leading)
            responsibilityFilterMenu
                .frame(width: PropertyActivityLayout.responsibility, alignment: .leading)
            sortHeader(.amount, alignment: .trailing).frame(width: PropertyActivityLayout.amount, alignment: .trailing)
        }
    }

    private var compactHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Transactions")
                Spacer()
                compactSortMenu
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    accountFilterMenu
                    Spacer(minLength: 4)
                    responsibilityFilterMenu
                }
                VStack(alignment: .leading, spacing: 8) {
                    accountFilterMenu
                    responsibilityFilterMenu
                }
            }
        }
    }

    private var compactSortMenu: some View {
        Menu {
            Section("Sort by") {
                ForEach(PropertyActivitySortColumn.allCases) { column in
                    Button { selectSortColumn(column) } label: { sortMenuLabel(column) }
                }
            }
            Section("Sort direction") {
                Button { sortDirection = .ascending } label: {
                    directionMenuLabel(.ascending, symbol: sortDirection == .ascending ? "checkmark" : "arrow.up")
                }
                Button { sortDirection = .descending } label: {
                    directionMenuLabel(.descending, symbol: sortDirection == .descending ? "checkmark" : "arrow.down")
                }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .accessibilityHint(Text("Choose a column and sort direction."))
    }

    @ViewBuilder private func sortMenuLabel(_ column: PropertyActivitySortColumn) -> some View {
        if sortColumn == column {
            Label { Text(LocalizedStringKey(column.rawValue)) } icon: { Image(systemName: "checkmark") }
        } else {
            Text(LocalizedStringKey(column.rawValue))
        }
    }

    @ViewBuilder private func directionMenuLabel(_ direction: PropertyActivitySortDirection, symbol: String) -> some View {
        if sortDirection == direction {
            Label { Text(LocalizedStringKey(direction.rawValue)) } icon: { Image(systemName: symbol) }
        } else {
            Label(LocalizedStringKey(direction.rawValue), systemImage: symbol)
        }
    }

    private func sortHeader(_ column: PropertyActivitySortColumn, alignment: Alignment = .leading) -> some View {
        Button { toggleSort(column) } label: {
            HStack(spacing: 4) {
                Text(LocalizedStringKey(column.rawValue)).fixedSize(horizontal: true, vertical: false)
                if sortColumn == column { Image(systemName: sortDirection.symbolName) }
            }
            .frame(maxWidth: .infinity, alignment: alignment)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(LocalizedStringKey(column.rawValue)))
        .accessibilityValue(Text(LocalizedStringKey(sortColumn == column ? sortDirection.rawValue : "Not sorted")))
        .accessibilityHint(Text("Sort ascending or descending"))
    }

    private func toggleSort(_ column: PropertyActivitySortColumn) {
        if sortColumn == column {
            sortDirection = sortDirection == .ascending ? .descending : .ascending
        } else {
            sortColumn = column
            sortDirection = column == .date ? .descending : .ascending
        }
    }

    private func selectSortColumn(_ column: PropertyActivitySortColumn) {
        guard sortColumn != column else { return }
        sortColumn = column
        sortDirection = column == .date ? .descending : .ascending
    }
    private func wideRow(_ row: PropertyActivityRow) -> some View {
        HStack(spacing: PropertyActivityLayout.spacing) {
            checkbox(row).frame(width: PropertyActivityLayout.selection)
            date(row).frame(width: PropertyActivityLayout.date, alignment: .leading)
            Text(row.concept).frame(minWidth: PropertyActivityLayout.concept, maxWidth: .infinity, alignment: .leading)
            account(row).frame(width: PropertyActivityLayout.account, alignment: .leading)
            Text(LocalizedStringKey(row.kind.rawValue)).frame(width: PropertyActivityLayout.type, alignment: .leading)
            responsibility(row).frame(width: PropertyActivityLayout.responsibility, alignment: .leading)
            amount(row).frame(width: PropertyActivityLayout.amount, alignment: .trailing)
        }.font(.callout)
    }
    private func compactRow(_ row: PropertyActivityRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                checkbox(row)
                Text(row.concept).frame(maxWidth: .infinity, alignment: .leading)
                amount(row)
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                date(row)
                account(row).frame(maxWidth: .infinity, alignment: .leading)
                Text(LocalizedStringKey(row.kind.rawValue)).foregroundStyle(.secondary)
                responsibility(row)
            }.font(.caption)
        }
    }
    @ViewBuilder private func checkbox(_ row: PropertyActivityRow) -> some View {
        if row.canAssign {
            Toggle("Select transaction", isOn: Binding(get: { selection.contains(row.id) }, set: {
                if $0 { selection.insert(row.id) } else { selection.remove(row.id) }
            })).labelsHidden().toggleStyle(.checkbox).accessibilityLabel(Text("Select \(row.concept)"))
        } else { Color.clear.frame(width: 14, height: 14).accessibilityHidden(true) }
    }
    private func date(_ row: PropertyActivityRow) -> some View {
        Group {
            if let date = row.date { Text(date, format: .dateTime.day().month(.abbreviated).locale(Locale(identifier: "es-MX"))) }
            else { Text("Date unavailable") }
        }.foregroundStyle(.secondary)
    }
    private func account(_ row: PropertyActivityRow) -> some View {
        Text(row.account ?? String(localized: "Account unavailable")).foregroundStyle(.secondary)
    }
    private func amount(_ row: PropertyActivityRow) -> some View {
        Group {
            if let value = row.amount { Text(propertyMoneyText(value, code: row.currency)) }
            else { Text("Amount unavailable") }
        }.monospacedDigit().fixedSize(horizontal: true, vertical: false)
    }
    @ViewBuilder private func responsibility(_ row: PropertyActivityRow) -> some View {
        if row.canAssign {
            Menu { choices([row.id]) } label: { Text(row.responsibility).multilineTextAlignment(.leading) }
                .menuStyle(.borderlessButton).help(String(localized: "Change responsibility"))
                .accessibilityLabel(Text("Responsibility for \(row.concept)"))
        } else { Text(row.responsibility).font(.caption) }
    }
    @ViewBuilder private func choices(_ ids: Set<UUID>) -> some View {
        if !household || allowsUserAssignment { Button("At my expense") { assign(ids, .owner) } }
        if !household || allowsUserAssignment || allowsPartnerAssignment { Button("Shared") { assign(ids, .shared) } }
        if household {
            if allowsPartnerAssignment { Button("Fer") { assign(ids, .partner) } }
            if allowsUserAssignment && allowsPartnerAssignment { Button("Custom split…") { assign(ids, .custom) } }
        } else {
            ForEach(residents) { resident in Button(resident.name) { assign(ids, .member(resident.id)) } }
            Button("Among selected members…") { assign(ids, .group) }
        }
    }
}
