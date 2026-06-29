import SwiftUI
import SwiftData
import Charts

struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = DashboardViewModel()
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

    @Query(sort: \Account.nickname) private var accounts: [Account]

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
            let outcome = AppDataResetService.repairIncompleteResetIfNeeded(context: modelContext)
            guard outcome != .hardResetRequested else { return }
            SeedDataLoader.bootstrapIfNeeded(context: modelContext)
            viewModel.setPeriod(selectedRange)
            viewModel.configure(context: modelContext)
            await BackupScheduler.runIfNeeded(context: modelContext)
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
                viewModel.setPeriod(selectedRange)
                viewModel.refresh()
            }
        }
        .onChange(of: accounts.map(\.id)) {
            validateAccountSelection()
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
        List(selection: $sidebarSelection) {
            Label("Overview", systemImage: "chart.pie")
                .tag(SidebarSelection.overview)

            Section {
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
            } header: {
                HStack {
                    Text("Accounts")
                    Spacer()
                    Button {
                        showingAddAccount = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.plain)
                    .help("Add account")
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
            TransactionsView(resetSignal: dataResetGeneration)
        case .importStatements:
            ImportView(modelContext: modelContext)
        case .settings:
            SettingsView(onAccountDeleted: { id in
                balanceSnapshotAccount = nil
                if case .account(let selectedID) = sidebarSelection, selectedID == id {
                    sidebarSelection = .overview
                    viewModel.scope = .consolidated
                }
                viewModel.refresh()
            }, onAccountCreated: { account in
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
                viewModel.refresh()
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
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                dashboardActions
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
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

    private var dashboardActions: some View {
        VStack(alignment: .trailing, spacing: 10) {
            if let account = selectedAccount {
                if account.type == .investment {
                    let canAddPositions = PortfolioService.canAddPositions(account: account, context: modelContext)
                    Button {
                        showingPositionsSheet = true
                    } label: {
                        Label(selectedAccountInPortfolioMode ? "Edit Stock Positions" : "Add Stock Positions", systemImage: "chart.line.uptrend.xyaxis")
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.glass)
                    .disabled(!canAddPositions)
                    if !canAddPositions {
                        Text("Create a separate brokerage account to track stocks.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if !selectedAccountInPortfolioMode {
                    Button {
                        showingManualTransaction = true
                    } label: {
                        Label("Add Transaction", systemImage: "plus.circle")
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.glass)
                    Button {
                        balanceSnapshotAccount = account
                    } label: {
                        Label("Add Balance", systemImage: "chart.line.uptrend.xyaxis")
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.glass)
                }
            }
            Button {
                showingImport = true
            } label: {
                Label("Import Statement", systemImage: "doc.badge.plus")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.glassProminent)
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
        return accounts.first { $0.id == id }
    }

    private var selectedAccountInPortfolioMode: Bool {
        if case .asset(let snapshot) = viewModel.snapshot {
            return PortfolioDashboardCopy.hidesManualActions(portfolio: snapshot.portfolio)
        }
        return false
    }

    private func validateAccountSelection() {
        guard case .account(let id) = sidebarSelection else { return }
        guard accounts.contains(where: { $0.id == id }) else {
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
            })
        case .asset(let snap):
            AssetAccountDashboard(
                snapshot: snap,
                onTransactionTap: { tx in
                    editingTransaction = tx
                },
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
    @Environment(\.modelContext) private var modelContext

    let account: Account
    let scopedViewModel: DashboardViewModel  // used to read the latest snapshot if needed

    init(account: Account, scopedViewModel: DashboardViewModel) {
        self.account = account
        self.scopedViewModel = scopedViewModel
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
              limit > 0 else { return nil }
        let balance = AccountBalanceResolver.currentBalance(account: account, context: modelContext)
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
            netWorthOverTime: [NetWorthPoint(month: period.effectiveNetWorthDate, balance: composition.totalNetWorth)],
            monthlyCashFlow: [],
            spendingByCategory: [],
            totalIncome: 0,
            totalExpenses: 0,
            totalInterestEarned: 0,
            totalInterestCharged: 0,
            recentTransactions: [],
            accountSummaries: summaries,
            totalTransactions: summaries.count,
            retirementAssets: composition.retirement,
            liquidNetWorth: composition.netLiquidity
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
            netWorthOverTime: [NetWorthPoint(month: period.effectiveNetWorthDate, balance: composition.totalNetWorth)],
            monthlyCashFlow: [],
            spendingByCategory: [],
            totalIncome: 0,
            totalExpenses: 0,
            totalInterestEarned: 0,
            totalInterestCharged: 0,
            recentTransactions: [],
            accountSummaries: summaries,
            totalTransactions: summaries.count,
            retirementAssets: composition.retirement,
            liquidNetWorth: composition.netLiquidity
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
            netWorthOverTime: netWorth,
            monthlyCashFlow: cashFlow,
            spendingByCategory: sampleSpending(),
            totalIncome: cashFlow.reduce(Decimal.zero) { $0 + $1.income },
            totalExpenses: cashFlow.reduce(Decimal.zero) { $0 + $1.expenses },
            totalInterestEarned: 420,
            totalInterestCharged: 0,
            recentTransactions: [],
            accountSummaries: summaries,
            totalTransactions: cashFlow.count,
            retirementAssets: composition.retirement,
            liquidNetWorth: composition.netLiquidity
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
            netWorthOverTime: resolvedNetWorth,
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
            totalTransactions: cashFlow.count,
            retirementAssets: 0,
            liquidNetWorth: finalNetWorth
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
