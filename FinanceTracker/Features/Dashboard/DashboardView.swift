import SwiftUI
import SwiftData
import Combine
import Charts
import os

struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel = DashboardViewModel()
    @State private var startupWarning: String?
    @State private var selectedRange: DashboardPeriodKind = .all
    @State private var customStart = Date().addingTimeInterval(-90 * 86400)
    @State private var customEnd = Date()
    @State private var showingCustomRange = false
    @State private var showingImport = false
    @State private var showingAddAccount = false
    @State private var showingManualTransaction = false
    @State private var balanceSnapshotAccount: Account?
    @State private var editingTransaction: Transaction?
    @State private var showingPaymentDetails = false
    @State private var showingPositionsSheet = false
    @State private var dataResetGeneration = 0
    @State private var pendingTransactionPreset: TransactionFilterPreset?
    @State private var transactionSession = TransactionSessionState()
    @State private var propertyWorkspace = PropertyWorkspaceModel()
    @AppStorage("sidebarPropertiesExpanded") private var sidebarPropertiesExpanded = true

    @Query private var accounts: [Account]
    @AppStorage("sidebarAccountSort") private var sidebarAccountSort = "nickname"
    @AppStorage("sidebarAccountsExpanded") private var sidebarAccountsExpanded = true

    private var activeAccounts: [Account] {
        accounts.filter { $0.archivedAt == nil }
    }

    private var sortedAccounts: [Account] {
        activeAccounts.sorted {
            if sidebarAccountSort == "institution" {
                return ($0.institution, $0.nickname) < ($1.institution, $1.nickname)
            }
            if sidebarAccountSort == "type" {
                return ($0.type.rawValue, $0.nickname) < ($1.type.rawValue, $1.nickname)
            }
            return $0.nickname.localizedCaseInsensitiveCompare($1.nickname) == .orderedAscending
        }
    }

    enum SidebarSelection: Hashable {
        case overview
        case account(UUID)
        case transactions
        case properties(PropertyDestination)
        case importStatements
        case settings
    }

    // The root stores which feature is active; the workspace owns the property destination.
    @State private var rootSelection: SidebarSelection = .overview
    private var sidebarSelection: SidebarSelection {
        get {
            if case .properties = rootSelection { return .properties(propertyWorkspace.destination) }
            return rootSelection
        }
        nonmutating set {
            if case .properties(let destination) = newValue {
                propertyWorkspace.destination = destination
                rootSelection = .properties(.allHomes)
            } else { rootSelection = newValue }
        }
    }

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
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 300)
        } detail: {
            detailPane
        }
        .environment(\.scopedTint, scopedTint)
        .safeAreaInset(edge: .top) {
            if let startupWarning {
                HStack {
                    Text(startupWarning).font(.caption).foregroundStyle(.orange)
                    Button("Reintentar") {
                        do {
                            try SeedDataLoader.bootstrapIfNeeded(context: modelContext)
                            self.startupWarning = nil
                            viewModel.refresh()
                        } catch { self.startupWarning = error.localizedDescription }
                    }
                }.padding(8)
            }
        }
        .task {
            do {
                let outcome = try AppDataResetService.repairIncompleteResetIfNeeded(context: modelContext)
                guard outcome != .hardResetRequested else { return }
                do { try SeedDataLoader.bootstrapIfNeeded(context: modelContext) }
                catch SeedDataLoader.BootstrapError.customizationUnavailable(let detail) {
                    startupWarning = "Personalización de categorías no disponible: \(detail). Seeds suspendidos; tus datos se conservan."
                }
            } catch {
                Logger.app.error("Category bootstrap failed; dashboard refresh skipped: \(error.localizedDescription)")
                return
            }
            HouseholdAllocationRepairService.repairIfNeeded(context: modelContext)
            viewModel.setPeriod(selectedRange)
            viewModel.configure(context: modelContext)
            propertyWorkspace.configure(context: modelContext, hasAccounts: !accounts.isEmpty)
            await propertyWorkspace.loadLedger()
            await BackupScheduler.runIfNeeded(context: modelContext)
        }
        .onChange(of: sidebarSelection) { previous, selection in
            switch selection {
            case .overview:
                viewModel.scope = .consolidated
                viewModel.refresh()
            case .account(let id):
                viewModel.scope = .account(id)
                viewModel.refresh()
            case .properties:
                propertyWorkspace.configure(context: modelContext, hasAccounts: !accounts.isEmpty)
                Task {
                    if case .properties = previous { await propertyWorkspace.refreshPeriod() }
                    else { await propertyWorkspace.refreshPeriod(force: true) }
                }
            default:
                break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: PropertyLedgerStore.didChangeNotification)) { _ in
            Task {
                await propertyWorkspace.loadLedger()
                if case .properties = sidebarSelection { await propertyWorkspace.refreshPeriod() }
            }
        }
        .onChange(of: selectedRange) {
            if selectedRange == .custom {
                showingCustomRange = true
            } else {
                viewModel.setPeriod(selectedRange)
                viewModel.refresh()
            }
        }
        .onChange(of: accounts.map { "\($0.id.uuidString):\($0.archivedAt?.timeIntervalSince1970 ?? 0)" }) {
            validateAccountSelection()
            propertyWorkspace.configure(context: modelContext, hasAccounts: !accounts.isEmpty)
            if case .properties = sidebarSelection { Task { await propertyWorkspace.refreshPeriod(force: true) } }
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                viewModel.refreshForCalendarChange()
                if case .properties = sidebarSelection { Task { await propertyWorkspace.refreshPeriod(force: true) } }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            if scenePhase == .active { viewModel.refreshForCalendarChange() }
        }
        .onReceive(
            NotificationCenter.default
                .publisher(for: ModelContext.didSave)
                // Side contexts of the same container must refresh too —
                // backup restores and the settings editor save on private
                // contexts, and an object-filtered subscription would leave
                // the dashboard stale after exactly those flows.
                // Filter BEFORE throttling: throttle only delivers the first
                // and latest event of each window, so a relevant save buried
                // under later irrelevant ones in the same window would be lost
                // if the filter ran downstream.
                .filter { DashboardDataChangePolicy.isBalanceRelevant($0, container: modelContext.container) }
                .throttle(for: .milliseconds(500), scheduler: RunLoop.main, latest: true)
        ) { _ in
            // A save from anywhere — Movimientos manual capture, edits, ingest,
            // pending-import resolutions — must be visible immediately: rebuild
            // the balance samplers and advance the period clock in one pass.
            viewModel.refreshAfterDataChange()
        }
        .popover(isPresented: $showingCustomRange) {
            customDatePopover
        }
        .sheet(isPresented: $showingAddAccount) {
            ManualAccountSheet { account in
                sidebarSelection = .account(account.id)
                viewModel.scope = .account(account.id)
                viewModel.refresh()
            }
        }
        .sheet(item: $balanceSnapshotAccount) { account in
            BalanceSnapshotSheet(account: account) {
                viewModel.refresh()
            }
        }
        .sheet(item: $editingTransaction) { tx in
            TransactionDetailSheet(
                transaction: tx,
                onCategoryAssigned: { _ in },
                onSaved: { viewModel.refresh() }
            )
        }
        .sheet(isPresented: $showingPaymentDetails) {
            if let account = selectedAccount {
                PaymentDetailsSheet(account: account) {
                    viewModel.refresh()
                }
            }
        }
        .sheet(isPresented: $showingPositionsSheet) {
            if let account = selectedAccount {
                PositionsEditSheet(account: account, context: modelContext) {
                    viewModel.refresh()
                }
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: Binding(get: { sidebarSelection }, set: { sidebarSelection = $0 })) {
            Label("Overview", systemImage: "chart.pie")
                .tag(SidebarSelection.overview)

            SidebarDestinationGroup(title: "Accounts", isExpanded: $sidebarAccountsExpanded) {
                if activeAccounts.isEmpty {
                    Text("No accounts yet").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(sortedAccounts) { account in
                    AccountSidebarRow(account: account)
                        .tag(SidebarSelection.account(account.id))
                }
            }
            .contextMenu {
                ForEach([("nickname", "Account name"), ("institution", "Institution"), ("type", "Type")], id: \.0) { key, label in
                    Button { sidebarAccountSort = key } label: {
                        Label(label, systemImage: sidebarAccountSort == key ? "checkmark" : "arrow.up.arrow.down")
                    }
                }
            }
            SidebarDestinationGroup(title: "Properties", isExpanded: $sidebarPropertiesExpanded) {
                    Label("All homes", systemImage: "square.grid.2x2")
                        .tag(SidebarSelection.properties(.allHomes))
                        .accessibilityIdentifier("properties.allHomes")
                    Label(PropertyDestination.householdName, systemImage: "house")
                        .tag(SidebarSelection.properties(.household))
                        .accessibilityIdentifier("properties.householdHome")
                    ForEach(propertyWorkspace.properties) { property in
                        Label(property.name, systemImage: "house")
                            .tag(SidebarSelection.properties(.property(property.id)))
                            .accessibilityIdentifier("properties.home.\(property.id.uuidString)")
                    }
            }
            .accessibilityIdentifier("properties.sidebar.item")
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
            TransactionsView(
                resetSignal: dataResetGeneration,
                preset: pendingTransactionPreset,
                onPresetConsumed: { _ in pendingTransactionPreset = nil },
                sessionState: $transactionSession
            )
        case .properties:
            PropertiesView(workspace: propertyWorkspace, onReviewHouseholdTransactions: { month in
                pendingTransactionPreset = TransactionFilterPreset(
                    month: month,
                    inclusion: .notIncluded
                )
                sidebarSelection = .transactions
            })
        case .importStatements:
            ImportView(modelContext: modelContext)
        case .settings:
            SettingsView(onAccountDeleted: { id in
                balanceSnapshotAccount = nil
                if case .account(let selectedID) = sidebarSelection, selectedID == id {
                    sidebarSelection = .overview
                    viewModel.scope = .consolidated
                }
                viewModel.reloadSpendRequirements(context: modelContext)
            }, onAccountArchived: { id in
                balanceSnapshotAccount = nil
                if case .account(let selectedID) = sidebarSelection, selectedID == id {
                    sidebarSelection = .overview
                    viewModel.scope = .consolidated
                    viewModel.refresh()
                }
            }, onAccountCreated: { account in
                viewModel.reloadSpendRequirements(context: modelContext)
                viewModel.refresh()
            }, onDataReset: {
                dataResetGeneration += 1
                sidebarSelection = .overview
                viewModel.scope = .consolidated
                balanceSnapshotAccount = nil
                showingManualTransaction = false
                showingImport = false
                showingAddAccount = false
                showingPositionsSheet = false
                viewModel.reloadSpendRequirements(context: modelContext)
            }, onSpendRequirementChanged: {
                viewModel.reloadSpendRequirements(context: modelContext)
            })
        }
    }

    private var dashboardDetail: some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                timeRangePicker
                snapshotContent
            }
            .padding()
        }
        .navigationTitle(navigationTitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { showingAddAccount = true } label: {
                        Label("Add account", systemImage: "creditcard")
                    }
                    Divider()
                    if let account = selectedAccount {
                        if !selectedAccountInPortfolioMode {
                            Button {
                                showingManualTransaction = true
                            } label: {
                                Label("Add Transaction", systemImage: "plus.circle")
                            }
                            Button {
                                balanceSnapshotAccount = account
                            } label: {
                                Label("Add Balance", systemImage: "chart.line.uptrend.xyaxis")
                            }
                        }

                        if account.type == .investment {
                            let canAddPositions = PortfolioService.canAddPositions(account: account, context: modelContext)
                            Button {
                                showingPositionsSheet = true
                            } label: {
                                Label(selectedAccountInPortfolioMode ? "Edit Stock Positions" : "Add Stock Positions", systemImage: "chart.line.uptrend.xyaxis")
                            }
                            .disabled(!canAddPositions)
                            if !canAddPositions {
                                Button("Create a separate brokerage account to track stocks.") {}
                                    .disabled(true)
                            }
                        }
                        Divider()
                    }

                    Button {
                        showingImport = true
                    } label: {
                        Label("Import Statement", systemImage: "doc.badge.plus")
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .help("Dashboard actions")
            }
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
        .sheet(isPresented: $showingManualTransaction) {
            ManualTransactionSheet(
                defaultAccountID: selectedAccount?.id,
                lockedAccountID: selectedAccount?.id,
                onSaved: { viewModel.refresh() }
            )
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

    private var selectedAccount: Account? {
        guard case .account(let id) = sidebarSelection else { return nil }
        return activeAccounts.first { $0.id == id }
    }

    private var selectedAccountInPortfolioMode: Bool {
        if case .asset(let snapshot) = viewModel.snapshot {
            return PortfolioDashboardCopy.hidesManualActions(portfolio: snapshot.portfolio)
        }
        return false
    }

    private func validateAccountSelection() {
        guard case .account(let id) = sidebarSelection else { return }
        guard activeAccounts.contains(where: { $0.id == id }) else {
            balanceSnapshotAccount = nil
            sidebarSelection = .overview
            viewModel.scope = .consolidated
            viewModel.refresh()
            return
        }
    }

    // MARK: - Snapshot dispatch

    @ViewBuilder
    private var snapshotContent: some View {
        switch viewModel.snapshot {
        case .consolidated(let snap):
            ConsolidatedDashboard(snapshot: snap, onTransactionTap: { tx in
                editingTransaction = tx
            }, onViewAllTransactions: {
                sidebarSelection = .transactions
            })
        case .asset(let snap):
            AssetAccountDashboard(
                snapshot: snap,
                onTransactionTap: { tx in
                    editingTransaction = tx
                },
                onViewAllTransactions: { openTransactions(for: snap.account.id) },
                onRefreshPrices: {
                    await refreshPortfolioPrices()
                },
                onEditPositions: {
                    showingPositionsSheet = true
                }
            )
        case .liability(let snap):
            LiabilityAccountDashboard(
                snapshot: snap,
                onTransactionTap: { tx in
                    editingTransaction = tx
                },
                onViewAllTransactions: { openTransactions(for: snap.account.id) },
                onEditPaymentDetails: {
                    if selectedAccount?.type == .creditCard {
                        showingPaymentDetails = true
                    }
                }
            )
        case .empty(let snap):
            emptyState(reason: snap.reason)
        }
    }

    private func refreshPortfolioPrices() async -> String? {
        guard let account = selectedAccount, account.type == .investment else { return nil }
        let outcome = await PortfolioPriceRefresher.refresh(account: account, context: modelContext)
        viewModel.refresh()
        return PortfolioDashboardCopy.refreshMessage(for: outcome)
    }

    private func openTransactions(for accountID: UUID) {
        pendingTransactionPreset = TransactionFilterPreset(accountID: accountID)
        sidebarSelection = .transactions
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
            ForEach(DashboardPeriodKind.allCases, id: \.self) { range in
                Text(range.localizedTitle).tag(range)
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
                    viewModel.setPeriod(.custom, customRange: DateRange(start: customStart, end: customEnd))
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

    var body: some View {
        HStack(spacing: 8) {
            iconForType
                .foregroundStyle(AccountIdentity.color(for: account))
            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName)
                    .font(.body)
                    .lineLimit(1)
                if let institution = AccountDisplay.institutionLabel(
                    displayName: account.displayName,
                    institution: account.institution
                ) {
                    Text(institution)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var iconForType: some View {
        switch account.type {
        case .creditCard:
            Image(systemName: "creditcard")
        case .checking, .savings:
            Image(systemName: "banknote")
        case .investment:
            Image(systemName: "chart.line.uptrend.xyaxis")
        case .loan:
            Image(systemName: "building.columns")
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

#Preview("Overview Month Current") {
    DashboardPreviewFixtures.preview(kind: .month, now: DashboardPreviewFixtures.date(2026, 6, 11))
}

#Preview("Overview Quarter Current") {
    DashboardPreviewFixtures.preview(kind: .quarter, now: DashboardPreviewFixtures.date(2026, 6, 11))
}

#Preview("Overview Custom May") {
    DashboardPreviewFixtures.preview(
        kind: .custom,
        now: DashboardPreviewFixtures.date(2026, 6, 11),
        customRange: DateRange(
            start: DashboardPreviewFixtures.date(2026, 5, 1),
            end: DashboardPreviewFixtures.date(2026, 5, 31)
        )
    )
}

#Preview("Overview Year Current") {
    DashboardPreviewFixtures.preview(kind: .year, now: DashboardPreviewFixtures.date(2026, 6, 11))
}

#Preview("Overview All") {
    DashboardPreviewFixtures.preview(kind: .all, now: DashboardPreviewFixtures.date(2026, 6, 11))
}

#Preview("Overview All Sparse Cash Flow") {
    DashboardPreviewFixtures.sparseAllPreview()
}

#Preview("Overview All Many Months") {
    DashboardPreviewFixtures.manyMonthsAllPreview()
}

#Preview("Overview All Retirement Jump") {
    DashboardPreviewFixtures.retirementJumpPreview()
}

#Preview("Overview Positive Net Worth") {
    DashboardPreviewFixtures.positiveNetWorthPreview()
}

#Preview("Overview Negative Net Worth") {
    DashboardPreviewFixtures.negativeNetWorthPreview()
}

#Preview("Net Worth Composition") {
    DashboardPreviewFixtures.netWorthCompositionPreview()
}

#Preview("Net Worth Composition Liquid Investments") {
    DashboardPreviewFixtures.liquidInvestmentCompositionPreview()
}

#Preview("Overview Four Charts Compact") {
    DashboardPreviewFixtures.fourChartOverviewPreview()
}

#Preview("Overview Four Charts Narrow") {
    DashboardPreviewFixtures.fourChartOverviewPreview(width: 760)
}

#Preview("Overview Year 12 Months") {
    DashboardPreviewFixtures.preview(kind: .year, now: DashboardPreviewFixtures.date(2026, 12, 31))
}

#Preview("Overview Empty Cash Flow") {
    DashboardPreviewFixtures.emptyCashFlowPreview()
}

#Preview("Overview Partial Net Worth Trend") {
    DashboardPreviewFixtures.partialTrendPreview()
}

#Preview("Overview Uncategorized Account") {
    DashboardPreviewFixtures.uncategorizedAccountPreview()
}

#Preview("Liability Sparse Charges vs Payments") {
    DashboardPreviewFixtures.liabilitySparsePreview()
}

@MainActor
private enum DashboardPreviewFixtures {
    static func preview(kind: DashboardPeriodKind, now: Date, customRange: DateRange? = nil) -> some View {
        overview(snapshot(kind: kind, now: now, customRange: customRange))
    }

    static func sparseAllPreview() -> some View {
        let now = date(2026, 6, 11)
        let requested = DashboardPeriodKind.all.resolvedRange(now: now)
        let period = DashboardPeriodResolver.context(
            kind: .all,
            requestedRange: requested,
            dataRange: DateRange(start: date(2026, 1, 1), end: now),
            now: now
        )
        let cashFlow = [
            MonthlyCashFlow(month: date(2026, 1, 1), income: 0, expenses: 0),
            MonthlyCashFlow(month: date(2026, 2, 1), income: 0, expenses: 0),
            MonthlyCashFlow(month: date(2026, 3, 1), income: 0, expenses: 0),
            MonthlyCashFlow(month: date(2026, 4, 1), income: 114_872, expenses: -34_576),
            MonthlyCashFlow(month: date(2026, 5, 1), income: 18_200, expenses: -12_400),
            MonthlyCashFlow(month: date(2026, 6, 1), income: 903, expenses: -12_650)
        ]
        return overview(snapshot(period: period, cashFlow: cashFlow))
    }

    static func manyMonthsAllPreview() -> some View {
        preview(kind: .all, now: date(2026, 12, 31))
    }

    static func partialTrendPreview() -> some View {
        let now = date(2026, 6, 11)
        let requested = DashboardPeriodKind.year.resolvedRange(now: now)
        let period = DashboardPeriodResolver.context(
            kind: .year,
            requestedRange: requested,
            dataRange: DateRange(start: date(2026, 1, 1), end: now),
            now: now
        )
        return overview(snapshot(
            period: period,
            cashFlow: [],
            netWorth: [NetWorthPoint(month: now, balance: 598_180)]
        ))
    }

    static func uncategorizedAccountPreview() -> some View {
        let now = date(2026, 6, 11)
        let requested = DashboardPeriodKind.all.resolvedRange(now: now)
        let period = DashboardPeriodResolver.context(
            kind: .all,
            requestedRange: requested,
            dataRange: DateRange(start: date(2026, 1, 1), end: now),
            now: now
        )
        let summaries = sampleCompositionSummaries() + [
            compositionSummary("Mystery Account", institution: "Unknown", type: .other, amount: 42_000)
        ]
        let composition = NetWorthComposition.calculate(from: summaries)
        let snapshot = ConsolidatedSnapshot(
            period: period,
            netWorth: composition.totalNetWorth,
            latestNetWorth: composition.totalNetWorth,
            snapshotAsOfDate: now,
            netWorthOverTime: [NetWorthPoint(month: now, balance: composition.totalNetWorth)],
            availableNetWorthOverTime: [NetWorthPoint(month: now, balance: composition.availableNetWorth)],
            monthlyCashFlow: [],
            spendingByCategory: sampleSpending(),
            totalIncome: 0,
            totalExpenses: 0,
            totalInterestEarned: 420,
            totalInterestCharged: 0,
            recentTransactions: [],
            accountSummaries: summaries,
            latestAccountSummaries: summaries,
            totalTransactions: summaries.count,
            retirementAssets: composition.retirement,
            liquidNetWorth: composition.netLiquidity,
            cardPace: CardPaceBuilder.build(priorMonthlyCharges: [], spentToDate: 0, dayOfMonth: 1, daysInMonth: 30),
            upcomingPayments: UpcomingPaymentsSnapshot(due: [], totalPrimary: 0, status: .calm),
            spendingAnomaly: SpendingAnomalySnapshot(strongest: nil, others: [], emptyReason: .calculatedNothingQualified)
        )
        return overview(snapshot)
    }

    static func retirementJumpPreview() -> some View {
        let now = date(2026, 12, 31)
        let requested = DashboardPeriodKind.all.resolvedRange(now: now)
        let period = DashboardPeriodResolver.context(
            kind: .all,
            requestedRange: requested,
            dataRange: DateRange(start: date(2026, 1, 1), end: now),
            now: now
        )
        let cashFlow = period.intervals().enumerated().map { index, interval in
            MonthlyCashFlow(
                month: interval.bucketStart,
                income: index.isMultiple(of: 3) ? 42_000 : 0,
                expenses: -Decimal(18_000 + (index % 4) * 1_500)
            )
        }
        let netWorth = period.intervals().enumerated().map { index, interval in
            let base = Decimal(180_000 + index * 7_500)
            let retirement = interval.bucketStart >= date(2026, 8, 1) ? Decimal(3_250_000) : 0
            return NetWorthPoint(month: interval.end, balance: base + retirement)
        }
        return overview(snapshot(period: period, cashFlow: cashFlow, netWorth: netWorth))
    }

    static func positiveNetWorthPreview() -> some View {
        let now = date(2026, 6, 11)
        let requested = DashboardPeriodKind.quarter.resolvedRange(now: now)
        let period = DashboardPeriodResolver.context(kind: .quarter, requestedRange: requested, dataRange: nil, now: now)
        let cashFlow = period.intervals().map {
            MonthlyCashFlow(month: $0.bucketStart, income: 24_000, expenses: -15_000)
        }
        let netWorth = period.intervals().enumerated().map { index, interval in
            NetWorthPoint(month: interval.end, balance: Decimal(240_000 + index * 32_000))
        }
        return overview(snapshot(period: period, cashFlow: cashFlow, netWorth: netWorth))
    }

    static func negativeNetWorthPreview() -> some View {
        let now = date(2026, 6, 11)
        let requested = DashboardPeriodKind.quarter.resolvedRange(now: now)
        let period = DashboardPeriodResolver.context(kind: .quarter, requestedRange: requested, dataRange: nil, now: now)
        let cashFlow = period.intervals().map {
            MonthlyCashFlow(month: $0.bucketStart, income: 20_000, expenses: -25_000)
        }
        let netWorth = period.intervals().enumerated().map { index, interval in
            NetWorthPoint(month: interval.end, balance: Decimal(-95_000 + index * 18_000))
        }
        return overview(snapshot(period: period, cashFlow: cashFlow, netWorth: netWorth))
    }

    static func emptyCashFlowPreview() -> some View {
        let now = date(2026, 6, 11)
        let requested = DashboardPeriodKind.month.resolvedRange(now: now)
        let period = DashboardPeriodResolver.context(kind: .month, requestedRange: requested, dataRange: nil, now: now)
        let cashFlow = period.intervals().map {
            MonthlyCashFlow(month: $0.bucketStart, income: 0, expenses: 0)
        }
        return overview(snapshot(period: period, cashFlow: cashFlow))
    }

    static func liabilitySparsePreview() -> some View {
        let now = date(2026, 6, 11)
        let period = DashboardPeriodResolver.context(
            kind: .all,
            requestedRange: DashboardPeriodKind.all.resolvedRange(now: now),
            dataRange: DateRange(start: date(2026, 1, 1), end: now),
            now: now
        )
        let chargesPayments = [
            MonthlyChargesPayments(month: date(2026, 1, 1), charges: 0, payments: 0),
            MonthlyChargesPayments(month: date(2026, 2, 1), charges: 0, payments: 0),
            MonthlyChargesPayments(month: date(2026, 3, 1), charges: 0, payments: 0),
            MonthlyChargesPayments(month: date(2026, 4, 1), charges: 34_575, payments: 6_200),
            MonthlyChargesPayments(month: date(2026, 5, 1), charges: 12_400, payments: 18_000),
            MonthlyChargesPayments(month: date(2026, 6, 1), charges: 12_650, payments: 900)
        ]
        let snapshot = LiabilityAccountSnapshot(
            period: period,
            account: DashboardAccountIdentity(
                id: UUID(),
                displayName: "Preview Credit Card",
                institution: "Preview Bank",
                type: .creditCard,
                currency: "MXN",
                tintHex: nil,
                creditLimit: 80_000
            ),
            currentBalance: -24_000,
            creditLimit: 80_000,
            utilizationPercent: 0.3,
            paymentStatement: nil,
            chargesVsPayments: chargesPayments,
            spendingByCategory: [],
            totalCharges: chargesPayments.reduce(Decimal.zero) { $0 + $1.charges },
            totalPayments: chargesPayments.reduce(Decimal.zero) { $0 + $1.payments },
            interestCharged: 0,
            feesCharged: 0,
            activeInstallmentPlans: [],
            sourceStatements: [],
            recentTransactions: [],
            totalTransactions: chargesPayments.count
        )

        return ScrollView {
            LiabilityAccountDashboard(snapshot: snapshot)
                .padding()
        }
        .frame(width: 1_100, height: 820)
        .background(AppBackdrop())
    }

    static func netWorthCompositionPreview() -> some View {
        let now = date(2026, 6, 11)
        let period = DashboardPeriodResolver.context(
            kind: .all,
            requestedRange: DashboardPeriodKind.all.resolvedRange(now: now),
            dataRange: DateRange(start: date(2026, 1, 1), end: now),
            now: now
        )
        let summaries = sampleCompositionSummaries()
        let composition = NetWorthComposition.calculate(from: summaries)
        let snapshot = ConsolidatedSnapshot(
            period: period,
            netWorth: composition.totalNetWorth,
            latestNetWorth: composition.totalNetWorth,
            snapshotAsOfDate: period.effectiveNetWorthDate,
            netWorthOverTime: [NetWorthPoint(month: period.effectiveNetWorthDate, balance: composition.totalNetWorth)],
            availableNetWorthOverTime: [NetWorthPoint(month: period.effectiveNetWorthDate, balance: composition.availableNetWorth)],
            monthlyCashFlow: [],
            spendingByCategory: [],
            totalIncome: 0,
            totalExpenses: 0,
            totalInterestEarned: 0,
            totalInterestCharged: 0,
            recentTransactions: [],
            accountSummaries: summaries,
            latestAccountSummaries: summaries,
            totalTransactions: summaries.count,
            retirementAssets: composition.retirement,
            liquidNetWorth: composition.netLiquidity,
            cardPace: CardPaceBuilder.build(priorMonthlyCharges: [], spentToDate: 0, dayOfMonth: 1, daysInMonth: 30),
            upcomingPayments: UpcomingPaymentsSnapshot(due: [], totalPrimary: 0, status: .calm),
            spendingAnomaly: SpendingAnomalySnapshot(strongest: nil, others: [], emptyReason: .calculatedNothingQualified)
        )
        return overview(snapshot)
    }

    static func liquidInvestmentCompositionPreview() -> some View {
        let now = date(2026, 6, 11)
        let period = DashboardPeriodResolver.context(
            kind: .all,
            requestedRange: DashboardPeriodKind.all.resolvedRange(now: now),
            dataRange: DateRange(start: date(2026, 1, 1), end: now),
            now: now
        )
        let summaries = [
            compositionSummary("Checking", institution: "Preview Bank", type: .checking, amount: 80_000),
            compositionSummary("Liquid Fund", institution: "Preview Broker", type: .investment, amount: 420_000, liquidity: .liquid),
            compositionSummary("AFORE", institution: "Preview Retirement", type: .retirement, amount: 900_000, liquidity: .lockedUntilRetirement, retirementKind: .afore),
            compositionSummary("Credit Card", institution: "Preview Bank", type: .creditCard, amount: -40_000),
        ]
        let composition = NetWorthComposition.calculate(from: summaries)
        let snapshot = ConsolidatedSnapshot(
            period: period,
            netWorth: composition.totalNetWorth,
            latestNetWorth: composition.totalNetWorth,
            snapshotAsOfDate: period.effectiveNetWorthDate,
            netWorthOverTime: [NetWorthPoint(month: period.effectiveNetWorthDate, balance: composition.totalNetWorth)],
            availableNetWorthOverTime: [NetWorthPoint(month: period.effectiveNetWorthDate, balance: composition.availableNetWorth)],
            monthlyCashFlow: [],
            spendingByCategory: [],
            totalIncome: 0,
            totalExpenses: 0,
            totalInterestEarned: 0,
            totalInterestCharged: 0,
            recentTransactions: [],
            accountSummaries: summaries,
            latestAccountSummaries: summaries,
            totalTransactions: summaries.count,
            retirementAssets: composition.retirement,
            liquidNetWorth: composition.netLiquidity,
            cardPace: CardPaceBuilder.build(priorMonthlyCharges: [], spentToDate: 0, dayOfMonth: 1, daysInMonth: 30),
            upcomingPayments: UpcomingPaymentsSnapshot(due: [], totalPrimary: 0, status: .calm),
            spendingAnomaly: SpendingAnomalySnapshot(strongest: nil, others: [], emptyReason: .calculatedNothingQualified)
        )
        return overview(snapshot)
    }

    static func fourChartOverviewPreview(width: CGFloat = 1_100) -> some View {
        let now = date(2026, 6, 11)
        let requested = DashboardPeriodKind.year.resolvedRange(now: now)
        let period = DashboardPeriodResolver.context(
            kind: .year,
            requestedRange: requested,
            dataRange: DateRange(start: date(2026, 1, 1), end: now),
            now: now
        )
        let cashFlow = period.intervals().enumerated().map { index, interval in
            MonthlyCashFlow(
                month: interval.bucketStart,
                income: Decimal(24_000 + index * 700),
                expenses: -Decimal(14_000 + (index % 4) * 1_200)
            )
        }
        let summaries = sampleCompositionSummaries()
        let composition = NetWorthComposition.calculate(from: summaries)
        let intervals = period.intervals()
        let netWorth = intervals.enumerated().map { index, interval in
            let remainingSteps = max(0, intervals.count - index - 1)
            return NetWorthPoint(month: interval.end, balance: composition.totalNetWorth - Decimal(remainingSteps * 18_000))
        }
        let snapshot = ConsolidatedSnapshot(
            period: period,
            netWorth: netWorth.last?.balance ?? composition.totalNetWorth,
            latestNetWorth: netWorth.last?.balance ?? composition.totalNetWorth,
            snapshotAsOfDate: period.effectiveNetWorthDate,
            netWorthOverTime: netWorth,
            availableNetWorthOverTime: netWorth,
            monthlyCashFlow: cashFlow,
            spendingByCategory: sampleSpending(),
            totalIncome: cashFlow.reduce(Decimal.zero) { $0 + $1.income },
            totalExpenses: cashFlow.reduce(Decimal.zero) { $0 + $1.expenses },
            totalInterestEarned: 420,
            totalInterestCharged: 0,
            recentTransactions: [],
            accountSummaries: summaries,
            latestAccountSummaries: summaries,
            totalTransactions: cashFlow.count,
            retirementAssets: composition.retirement,
            liquidNetWorth: composition.netLiquidity,
            cardPace: CardPaceBuilder.build(priorMonthlyCharges: [], spentToDate: 0, dayOfMonth: 1, daysInMonth: 30),
            upcomingPayments: UpcomingPaymentsSnapshot(due: [], totalPrimary: 0, status: .calm),
            spendingAnomaly: SpendingAnomalySnapshot(strongest: nil, others: [], emptyReason: .calculatedNothingQualified)
        )
        return overview(snapshot, width: width)
    }

    private static func sampleCompositionSummaries() -> [AccountSummary] {
        [
            compositionSummary("Apartados Open / Openbank", institution: "Openbank Mexico", type: .savings, amount: d("251936.32")),
            compositionSummary("BBVA", institution: "BBVA", type: .checking, amount: d("1000.00")),
            compositionSummary("BONDDIA / Cetesdirecto", institution: "Cetesdirecto", type: .investment, amount: d("201097.99"), liquidity: .liquid),
            compositionSummary("Instant Access Savings / Revolut", institution: "Revolut", type: .savings, amount: d("57334.53")),
            compositionSummary("Joint Instant Access Savings / Revolut", institution: "Revolut", type: .savings, amount: d("9927.64")),
            compositionSummary("Priority / Banamex", institution: "Banamex", type: .checking, amount: 0),
            compositionSummary("Investment / GBM", institution: "GBM", type: .investment, amount: d("239730.95"), liquidity: .restricted),
            compositionSummary("AFORE / Banamex", institution: "Banamex", type: .retirement, amount: d("630645.34"), liquidity: .lockedUntilRetirement, retirementKind: .afore),
            compositionSummary("Plan para el Retiro / Skandia", institution: "Skandia", type: .retirement, amount: d("826880.42"), liquidity: .lockedUntilRetirement, retirementKind: .employerRetirementPlan),
            compositionSummary("PPR / Fintual", institution: "Fintual", type: .retirement, amount: d("133976.59"), liquidity: .restricted, retirementKind: .ppr),
            compositionSummary("2now de Alvaro / HSBC", institution: "HSBC 2Now", type: .creditCard, amount: -d("63312.65")),
            compositionSummary("2now de Mar / HSBC", institution: "HSBC 2Now", type: .creditCard, amount: -d("10923.40")),
            compositionSummary("Explora / Banamex", institution: "Banamex", type: .creditCard, amount: -d("3374.43")),
            compositionSummary("Gold Elite Credit Card / American Express", institution: "American Express Mexico", type: .creditCard, amount: -d("63974.54")),
            compositionSummary("Volaris 0 / Invex", institution: "Invex", type: .creditCard, amount: -d("296.79")),
        ]
    }

    private static func sampleSpending() -> [CategorySpending] {
        [
            CategorySpending(category: Category(name: "Food", kind: .expense), amount: 12_400),
            CategorySpending(category: Category(name: "Transport", kind: .expense), amount: 7_800),
            CategorySpending(category: Category(name: "Home", kind: .expense), amount: 6_300),
            CategorySpending(category: Category(name: "Health", kind: .expense), amount: 4_100),
            CategorySpending(category: Category(name: "Subscriptions", kind: .expense), amount: 2_900),
        ]
    }

    private static func compositionSummary(
        _ name: String,
        institution: String,
        type: AccountType,
        amount: Decimal,
        liquidity: AccountLiquidity = .liquid,
        retirementKind: RetirementKind? = nil
    ) -> AccountSummary {
        AccountSummary(
            id: UUID(),
            displayName: name,
            institution: institution,
            type: type,
            currency: "MXN",
            latestBalance: amount,
            balanceAsOf: date(2026, 6, 11),
            balanceSourceKind: .exactBalanceSnapshot,
            balanceSourceDate: date(2026, 6, 11),
            creditLimit: nil,
            utilizationPercent: nil,
            liquidity: liquidity,
            retirementKind: retirementKind
        )
    }

    private static func overview(_ snapshot: ConsolidatedSnapshot, width: CGFloat = 1_100, height: CGFloat = 820) -> some View {
        ScrollView {
            ConsolidatedDashboard(snapshot: snapshot)
                .padding()
        }
        .frame(width: width, height: height)
        .background(AppBackdrop())
    }

    static func snapshot(kind: DashboardPeriodKind, now: Date, customRange: DateRange?) -> ConsolidatedSnapshot {
        let requested = kind.resolvedRange(now: now, customRange: customRange)
        let dataRange = DateRange(start: date(2026, 1, 1), end: now)
        let period = DashboardPeriodResolver.context(kind: kind, requestedRange: requested, dataRange: dataRange, now: now)
        let intervals = period.intervals()
        let cashFlow = intervals.enumerated().map { index, interval in
            MonthlyCashFlow(
                month: interval.bucketStart,
                income: index.isMultiple(of: 3) ? Decimal(18_000 + index * 350) : Decimal(index.isMultiple(of: 2) ? 1_200 : 0),
                expenses: -Decimal(3_000 + (index % 5) * 900)
            )
        }
        let netWorth = intervals.enumerated().map { index, interval in
            NetWorthPoint(month: interval.end, balance: Decimal(280_000 + index * 4_250 - (index % 4) * 1_500))
        }
        return snapshot(period: period, cashFlow: cashFlow, netWorth: netWorth)
    }

    private static func snapshot(
        period: DashboardPeriodContext,
        cashFlow: [MonthlyCashFlow],
        netWorth: [NetWorthPoint]? = nil,
        spending: [CategorySpending] = []
    ) -> ConsolidatedSnapshot {
        let resolvedNetWorth = netWorth ?? period.intervals().enumerated().map { index, interval in
            NetWorthPoint(month: interval.end, balance: Decimal(280_000 + index * 4_250 - (index % 4) * 1_500))
        }
        let finalNetWorth = resolvedNetWorth.last?.balance ?? 0
        return ConsolidatedSnapshot(
            period: period,
            netWorth: finalNetWorth,
            latestNetWorth: finalNetWorth,
            snapshotAsOfDate: period.effectiveNetWorthDate,
            netWorthOverTime: resolvedNetWorth,
            availableNetWorthOverTime: resolvedNetWorth,
            monthlyCashFlow: cashFlow,
            spendingByCategory: spending,
            totalIncome: cashFlow.reduce(Decimal.zero) { $0 + $1.income },
            totalExpenses: cashFlow.reduce(Decimal.zero) { $0 + $1.expenses },
            totalInterestEarned: 420,
            totalInterestCharged: 0,
            recentTransactions: [],
            accountSummaries: [
                AccountSummary(
                    id: UUID(),
                    displayName: "Preview Checking",
                    institution: "Preview Bank",
                    type: .checking,
                    currency: "MXN",
                    latestBalance: finalNetWorth,
                    balanceAsOf: period.effectiveNetWorthDate,
                    balanceSourceKind: .reconstructedBalance,
                    balanceSourceDate: date(2026, 1, 1),
                    creditLimit: nil,
                    utilizationPercent: nil
                )
            ],
            latestAccountSummaries: [
                AccountSummary(
                    id: UUID(),
                    displayName: "Preview Checking",
                    institution: "Preview Bank",
                    type: .checking,
                    currency: "MXN",
                    latestBalance: finalNetWorth,
                    balanceAsOf: period.effectiveNetWorthDate,
                    balanceSourceKind: .reconstructedBalance,
                    balanceSourceDate: date(2026, 1, 1),
                    creditLimit: nil,
                    utilizationPercent: nil
                )
            ],
            totalTransactions: cashFlow.count,
            retirementAssets: 0,
            liquidNetWorth: finalNetWorth,
            cardPace: CardPaceBuilder.build(priorMonthlyCharges: [], spentToDate: 0, dayOfMonth: 1, daysInMonth: 30),
            upcomingPayments: UpcomingPaymentsSnapshot(due: [], totalPrimary: 0, status: .calm),
            spendingAnomaly: SpendingAnomalySnapshot(strongest: nil, others: [], emptyReason: .calculatedNothingQualified)
        )
    }

    static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.timeZone = TimeZone(identifier: "America/Mexico_City")
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    private static func d(_ value: String) -> Decimal {
        Decimal(string: value) ?? 0
    }
}
