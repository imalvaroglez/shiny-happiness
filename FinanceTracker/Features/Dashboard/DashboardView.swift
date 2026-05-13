import SwiftUI
import SwiftData
import Charts

struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = DashboardViewModel()
    @State private var selectedRange: TimeRange = .all
    @State private var customStart = Date().addingTimeInterval(-90 * 86400)
    @State private var customEnd = Date()
    @State private var showingCustomRange = false
    @State private var showingImport = false

    @Query(sort: \Account.nickname) private var accounts: [Account]

    enum TimeRange: String, CaseIterable {
        case month = "Month"
        case quarter = "Quarter"
        case year = "Year"
        case all = "All"
        case custom = "Custom"

        var dateRange: DateRange {
            let now = Date()
            let calendar = Calendar(identifier: .gregorian)
            switch self {
            case .month:
                return .month(now)
            case .quarter:
                let start = calendar.date(byAdding: .month, value: -3, to: now)!
                return DateRange(start: start, end: now)
            case .year:
                return .year(now)
            case .all:
                return DateRange(start: .distantPast, end: now)
            case .custom:
                return DateRange(start: .distantPast, end: now)
            }
        }
    }

    enum SidebarSelection: Hashable {
        case overview
        case account(UUID)
        case transactions
        case importStatements
        case settings
    }

    @State private var sidebarSelection: SidebarSelection = .overview

    /// Identity color of the currently scoped account, used by glass cards
    /// (specular tint), the sidebar selection highlight, and chart plot-area
    /// strokes. Resolved from the snapshot so it tracks `sidebarSelection`.
    private var scopedTint: Color {
        switch viewModel.snapshot {
        case .consolidated, .empty:
            return AccountIdentity.consolidated
        case .asset(let snap):
            return AccountIdentity.color(for: snap.account)
        case .liability(let snap):
            return AccountIdentity.color(for: snap.account)
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationTitle("FinanceTracker")
        } detail: {
            detailPane
        }
        .environment(\.scopedTint, scopedTint)
        .task {
            SeedDataLoader.bootstrapIfNeeded(context: modelContext)
            viewModel.configure(context: modelContext)
        }
        .onAppear {
            viewModel.refresh()
        }
        .onChange(of: sidebarSelection) {
            switch sidebarSelection {
            case .overview:
                viewModel.scope = .consolidated
                viewModel.refresh()
            case .account(let id):
                viewModel.scope = .account(id)
                viewModel.refresh()
            default:
                break
            }
        }
        .onChange(of: selectedRange) {
            if selectedRange == .custom {
                showingCustomRange = true
            } else {
                viewModel.dateRange = selectedRange.dateRange
                viewModel.refresh()
            }
        }
        .popover(isPresented: $showingCustomRange) {
            customDatePopover
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $sidebarSelection) {
            Label("Overview", systemImage: "chart.pie")
                .tag(SidebarSelection.overview)

            Section("Accounts") {
                if accounts.isEmpty {
                    Text("No accounts yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(accounts) { account in
                        AccountSidebarRow(account: account, scopedViewModel: viewModel)
                            .tag(SidebarSelection.account(account.id))
                    }
                }
            }

            Section {
                Label("Transactions", systemImage: "list.bullet")
                    .tag(SidebarSelection.transactions)
                Label("Import Statements", systemImage: "doc.badge.plus")
                    .tag(SidebarSelection.importStatements)
                Label("Settings", systemImage: "gearshape")
                    .tag(SidebarSelection.settings)
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Detail pane dispatch

    @ViewBuilder
    private var detailPane: some View {
        switch sidebarSelection {
        case .overview, .account:
            dashboardDetail
        case .transactions:
            TransactionsView()
        case .importStatements:
            ImportView(modelContext: modelContext)
        case .settings:
            SettingsView()
        }
    }

    private var dashboardDetail: some View {
        ScrollView {
            VStack(spacing: 20) {
                timeRangePicker
                snapshotContent
            }
            .padding()
        }
        .navigationTitle(navigationTitle)
        .overlay(alignment: .bottomTrailing) {
            Button {
                showingImport = true
            } label: {
                Label("Import Statement", systemImage: "doc.badge.plus")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.glassProminent)
            .padding(20)
        }
        .sheet(isPresented: $showingImport) {
            NavigationStack {
                ImportView(modelContext: modelContext)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingImport = false }
                        }
                    }
            }
            .frame(minWidth: 600, minHeight: 500)
        }
    }

    private var navigationTitle: String {
        switch viewModel.snapshot {
        case .consolidated:
            return "Overview"
        case .asset(let snap):
            return snap.account.displayName
        case .liability(let snap):
            return snap.account.displayName
        case .empty:
            return "Dashboard"
        }
    }

    // MARK: - Snapshot dispatch

    @ViewBuilder
    private var snapshotContent: some View {
        switch viewModel.snapshot {
        case .consolidated(let snap):
            ConsolidatedDashboard(snapshot: snap)
        case .asset(let snap):
            AssetAccountDashboard(snapshot: snap)
        case .liability(let snap):
            LiabilityAccountDashboard(snapshot: snap)
        case .empty(let snap):
            emptyState(reason: snap.reason)
        }
    }

    private func emptyState(reason: String) -> some View {
        GlassCard(role: .card, interactive: false) {
            VStack(spacing: 14) {
                Image(systemName: "chart.line.uptrend.xyaxis.circle.fill")
                    .font(.system(size: 56))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(scopedTint)
                Text(reason == "Loading…" ? "Loading…" : "No transactions yet")
                    .font(.headline)
                if reason != "Loading…" {
                    Text("Import a bank statement to get started")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
            .padding(.horizontal, 24)
        }
    }

    // MARK: - Time range picker / custom popover

    private var timeRangePicker: some View {
        Picker("Period", selection: $selectedRange) {
            ForEach(TimeRange.allCases, id: \.self) { range in
                Text(range.rawValue).tag(range)
            }
        }
        .pickerStyle(.segmented)
    }

    private var customDatePopover: some View {
        VStack(spacing: 16) {
            Text("Custom Date Range").font(.headline)
            DatePicker("From", selection: $customStart, displayedComponents: .date)
            DatePicker("To", selection: $customEnd, in: ...Date(), displayedComponents: .date)
            HStack {
                Button("Cancel") {
                    selectedRange = .all
                    showingCustomRange = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    viewModel.dateRange = DateRange(start: customStart, end: customEnd)
                    viewModel.refresh()
                    showingCustomRange = false
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
            }
        }
        .padding(20)
        .frame(width: 280)
    }
}

// MARK: - Sidebar row

private struct AccountSidebarRow: View {
    let account: Account
    let scopedViewModel: DashboardViewModel  // used to read the latest snapshot if needed

    /// Most-recent closing balance for this account (synchronous DB lookup).
    /// Powers the utilization bar (Item 6) for credit-card accounts.
    @Query private var statements: [Statement]

    init(account: Account, scopedViewModel: DashboardViewModel) {
        self.account = account
        self.scopedViewModel = scopedViewModel
        let id = account.id
        _statements = Query(
            filter: #Predicate<Statement> { $0.account?.id == id },
            sort: [SortDescriptor(\Statement.periodEnd, order: .reverse)]
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            iconForType
                .foregroundStyle(AccountIdentity.color(for: account))
            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName)
                    .font(.body)
                    .lineLimit(1)
                Text(account.institution)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                if account.type == .creditCard, let utilization = utilization {
                    ProgressView(value: min(max(utilization, 0), 1))
                        .progressViewStyle(.linear)
                        .tint(utilization > 0.7 ? .red : (utilization > 0.3 ? .orange : AccountIdentity.color(for: account)))
                        .frame(height: 3)
                        .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var utilization: Double? {
        guard account.type == .creditCard,
              let limit = account.creditLimit,
              limit > 0,
              let latest = statements.first,
              let balance = latest.closingBalance else { return nil }
        let owed = (abs(balance) as NSDecimalNumber).doubleValue
        let lim = (limit as NSDecimalNumber).doubleValue
        return owed / lim
    }

    private var iconForType: some View {
        switch account.type {
        case .creditCard:
            Image(systemName: "creditcard")
        case .checking, .savings:
            Image(systemName: "banknote")
        case .investment:
            Image(systemName: "chart.line.uptrend.xyaxis")
        case .retirement:
            Image(systemName: "calendar")
        case .wallet:
            Image(systemName: "wallet.bifold")
        case .other:
            Image(systemName: "questionmark.circle")
        }
    }
}

#Preview {
    DashboardView()
}
