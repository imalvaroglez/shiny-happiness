import SwiftUI
import SwiftData
import Charts

/// The default scope: aggregated view across every account. Snapshot cards use
/// the latest available balances, while period cards and charts use the
/// selected dashboard period.
struct ConsolidatedDashboard: View {
    let snapshot: ConsolidatedSnapshot
    var onTransactionTap: ((Transaction) -> Void)? = nil
    var onViewAllTransactions: (() -> Void)? = nil

    @State private var breakdown: BreakdownRequest? = nil
    @State private var cashFlowSeries: Set<CashFlowSeries> = [.income, .expenses]
    @State private var netWorthHover: Date? = nil
    @State private var cashFlowTrendHover: Date? = nil
    @State private var expandedAccountGroups = Set(DashboardAccountBucket.allCases)

    private var composition: NetWorthComposition { snapshot.netWorthComposition }

    var body: some View {
        VStack(spacing: 16) {
            heroSummary
            overviewGrid
            if !accountGroups.isEmpty { accountsList }
            if !snapshot.recentTransactions.isEmpty { recentTransactionsList }
            if snapshot.totalTransactions == 0 { emptyState }
        }
        .sheet(item: $breakdown) { req in
            BreakdownSheet(request: req)
        }
    }

    // MARK: - Hero

    private var heroSummary: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 14) {
                availableNetWorthCard
                    .frame(minWidth: 330, maxWidth: .infinity)
                secondaryMetricGrid
                    .frame(minWidth: 500, maxWidth: 620)
            }

            VStack(spacing: 12) {
                availableNetWorthCard
                secondaryMetricGrid
            }
        }
    }

    private var availableNetWorthCard: some View {
        OverviewMetricCard(
            title: "Available Net Worth",
            amount: composition.availableNetWorth,
            currencyCode: snapshot.currencyCode,
            subtitle: "Liquidity + patrimonial, excluding retirement",
            footnote: snapshotAsOfText,
            systemImage: "banknote",
            tint: composition.availableNetWorth >= 0 ? DashboardChartSeriesColor.income : DashboardChartSeriesColor.expense,
            prominent: true
        ) {
            breakdown = .netWorth(period: latestSnapshotPeriod, accounts: snapshot.overviewAccountSummaries)
        }
    }

    private var secondaryMetricGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], alignment: .leading, spacing: 12) {
            OverviewMetricCard(
                title: "Total Net Worth",
                amount: composition.totalNetWorth,
                currencyCode: snapshot.currencyCode,
                subtitle: "Includes retirement assets",
                footnote: snapshotAsOfText,
                systemImage: "chart.pie",
                tint: composition.totalNetWorth >= 0 ? DashboardChartSeriesColor.income : DashboardChartSeriesColor.expense
            ) {
                breakdown = .netWorth(period: latestSnapshotPeriod, accounts: snapshot.overviewAccountSummaries)
            }

            OverviewMetricCard(
                title: "Net Cash Flow",
                amount: snapshot.netCashFlow,
                currencyCode: snapshot.currencyCode,
                subtitle: "Income - expenses",
                footnote: periodLabel,
                systemImage: "arrow.left.arrow.right",
                tint: snapshot.netCashFlow >= 0 ? DashboardChartSeriesColor.income : DashboardChartSeriesColor.expense
            )

            OverviewMetricCard(
                title: "Card Liabilities",
                amount: composition.totalLiabilities,
                currencyCode: snapshot.currencyCode,
                subtitle: "Outstanding short-term liabilities",
                footnote: snapshotAsOfText,
                systemImage: "creditcard",
                tint: DashboardChartSeriesColor.expense
            ) {
                breakdown = .netWorth(period: latestSnapshotPeriod, accounts: snapshot.overviewAccountSummaries)
            }

            OverviewMetricCard(
                title: "Interest Earned",
                amount: snapshot.totalInterestEarned,
                currencyCode: snapshot.currencyCode,
                subtitle: "Period interest income",
                footnote: periodLabel,
                systemImage: "percent",
                tint: .mint
            ) {
                breakdown = .interest(transactions: snapshot.recentTransactions, total: snapshot.totalInterestEarned)
            }
        }
    }

    // MARK: - Overview grid

    private var overviewGrid: some View {
        ViewThatFits(in: .horizontal) {
            LazyVGrid(columns: twoChartColumns, alignment: .leading, spacing: 16) {
                overviewCards
            }
            .frame(minWidth: 860)

            LazyVGrid(columns: oneChartColumn, alignment: .leading, spacing: 16) {
                overviewCards
            }
        }
    }

    private var twoChartColumns: [GridItem] {
        [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]
    }

    private var oneChartColumn: [GridItem] {
        [GridItem(.flexible(), spacing: 16)]
    }

    @ViewBuilder
    private var overviewCards: some View {
        cashFlowChart
        netWorthChart
        netWorthCompositionCard
        spendingBars
        interestYieldCard
        needsAttentionCard
    }

    // MARK: - Cash flow

    enum CashFlowSeries: String, CaseIterable, Identifiable {
        case income = "Income"
        case expenses = "Expenses"
        var id: String { rawValue }
        var color: Color { self == .income ? DashboardChartSeriesColor.income : DashboardChartSeriesColor.expense }
    }

    private var cashFlowChart: some View {
        ChartCard(title: "Cash Flow") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Net Cash Flow")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(MoneyFormat.string(code: snapshot.currencyCode, snapshot.netCashFlow))
                            .font(.title3.bold().monospacedDigit())
                            .foregroundStyle(snapshot.netCashFlow >= 0 ? DashboardChartSeriesColor.income : DashboardChartSeriesColor.expense)
                    }
                    Spacer()
                    seriesFilter
                }

                Text("Transfers between your own accounts are excluded.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if DashboardCashFlowTrendBuilder.usesTrendCard(period: snapshot.period) {
                    DashboardCashFlowTrendChart(
                        entries: snapshot.monthlyCashFlow,
                        period: snapshot.period,
                        currencyCode: snapshot.currencyCode,
                        onPointTap: { point in
                            breakdown = .cashFlowPeriod(start: point.bucketStart, bucket: snapshot.period.bucket, transactions: snapshot.recentTransactions)
                        },
                        hoverBucketStart: $cashFlowTrendHover
                    )
                } else {
                    DashboardGroupedPeriodBarChart(
                        groups: cashFlowBarGroups,
                        firstSeriesName: CashFlowSeries.income.rawValue,
                        secondSeriesName: CashFlowSeries.expenses.rawValue,
                        firstColor: DashboardChartSeriesColor.income,
                        secondColor: DashboardChartSeriesColor.expense,
                        currencyCode: snapshot.currencyCode,
                        emptyMessage: "No cash flow activity for this period.",
                        showsFirstSeries: cashFlowSeries.contains(.income),
                        showsSecondSeries: cashFlowSeries.contains(.expenses),
                        footerText: { group in
                            guard let entry = cashFlowEntry(for: group.bucketStart) else { return nil }
                            var parts = ["Net: \(MoneyFormat.string(code: snapshot.currencyCode, entry.savings))"]
                            if entry.income > 0 {
                                parts.append("Savings Rate: \(cashFlowSavingsRateText(entry))")
                            }
                            return parts.joined(separator: " . ")
                        },
                        onGroupTap: { group in
                            breakdown = .cashFlowPeriod(start: group.bucketStart, bucket: snapshot.period.bucket, transactions: snapshot.recentTransactions)
                        }
                    )
                }
            }
        }
    }

    private var seriesFilter: some View {
        HStack(spacing: 8) {
            ForEach(CashFlowSeries.allCases) { series in
                Toggle(isOn: Binding(
                    get: { cashFlowSeries.contains(series) },
                    set: { isOn in
                        if isOn { cashFlowSeries.insert(series) } else { cashFlowSeries.remove(series) }
                    }
                )) {
                    HStack(spacing: 4) {
                        Circle().fill(series.color).frame(width: 8, height: 8)
                        Text(series.rawValue).font(.caption)
                    }
                }
                .toggleStyle(.button)
                .controlSize(.small)
            }
        }
    }

    private var cashFlowBarGroups: [DashboardPeriodBarGroup] {
        DashboardPeriodBarGroupBuilder.groups(
            period: snapshot.period,
            buckets: snapshot.monthlyCashFlow.map { entry in
                DashboardPeriodBucketDisplayValue(
                    bucketStart: entry.month,
                    firstMagnitude: entry.income,
                    secondMagnitude: abs(entry.expenses)
                )
            }
        )
    }

    private func cashFlowEntry(for selection: Date) -> MonthlyCashFlow? {
        guard selection >= snapshot.period.dateRange.start && selection <= snapshot.period.dateRange.end else { return nil }
        let bucketStart = snapshot.period.bucketStart(forSelection: selection)
        return snapshot.monthlyCashFlow.first { $0.month == bucketStart }
    }

    private func cashFlowSavingsRateText(_ entry: MonthlyCashFlow) -> String {
        guard entry.income > 0 else { return "0.0%" }
        let rate = ((entry.savings / entry.income) as NSDecimalNumber).doubleValue * 100
        return String(format: "%.1f%%", rate)
    }

    // MARK: - Net worth

    private var netWorthChart: some View {
        ChartCard(title: "Net Worth Trend", subtitle: periodLabel) {
            VStack(alignment: .leading, spacing: 8) {
                if hasReliableNetWorthTrend {
                    DashboardBalanceTimeSeriesChart(
                        points: snapshot.netWorthOverTime,
                        period: snapshot.period,
                        currencyCode: snapshot.currencyCode,
                        onPointTap: { _ in
                            breakdown = .netWorth(period: snapshot.period, accounts: snapshot.accountSummaries)
                        },
                        hoverBucketStart: $netWorthHover
                    )
                } else {
                    DashboardChartEmptyState(message: "Net worth trend will appear after more balance snapshots.")
                }
            }
        }
        .onTapGesture {
            if netWorthHover == nil {
                breakdown = .netWorth(period: snapshot.period, accounts: snapshot.accountSummaries)
            }
        }
    }

    private var hasReliableNetWorthTrend: Bool {
        !snapshot.netWorthOverTime.isEmpty
    }

    private var netWorthCompositionCard: some View {
        NetWorthCompositionCard(
            composition: composition,
            currencyCode: snapshot.currencyCode,
            compact: true,
            defaultMode: .available
        )
    }

    // MARK: - Spending

    private var spendingBars: some View {
        ChartCard(title: "Spending by Category") {
            DashboardSpendingCategoryBars(
                entries: snapshot.spendingByCategory,
                currencyCode: snapshot.currencyCode,
                limit: 5
            ) { entry in
                breakdown = .categorySpending(category: entry.category, amount: entry.amount, transactions: snapshot.recentTransactions)
            }
        }
    }

    // MARK: - Interest and attention

    private var interestYieldCard: some View {
        OverviewPanel(title: "Interest & Yield", systemImage: "percent") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Interest earned")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(MoneyFormat.string(code: snapshot.currencyCode, snapshot.totalInterestEarned))
                            .font(.title3.bold().monospacedDigit())
                            .foregroundStyle(.mint)
                    }
                    Spacer()
                    Text(periodLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Label("Add account yield rates to estimate weighted yield.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var needsAttentionCard: some View {
        OverviewPanel(title: "Needs Attention", systemImage: "exclamationmark.circle") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(attentionItems.prefix(4)) { item in
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: item.systemImage)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(item.tint)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.caption.weight(.semibold))
                            Text(item.detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
    }

    private var attentionItems: [OverviewAttentionItem] {
        var items: [OverviewAttentionItem] = []

        if composition.totalLiabilities > 0 {
            items.append(OverviewAttentionItem(
                title: "Credit card liabilities",
                detail: MoneyFormat.string(code: snapshot.currencyCode, composition.totalLiabilities),
                systemImage: "creditcard",
                tint: DashboardChartSeriesColor.expense
            ))
        }

        items.append(OverviewAttentionItem(
            title: composition.netLiquidity < 0 ? "Liquidity is negative after cards" : "Liquidity after cards",
            detail: MoneyFormat.string(code: snapshot.currencyCode, composition.netLiquidity),
            systemImage: "banknote",
            tint: composition.netLiquidity >= 0 ? DashboardChartSeriesColor.income : .orange
        ))

        if let allocation = availableAllocationText {
            items.append(OverviewAttentionItem(
                title: "Available allocation",
                detail: allocation,
                systemImage: "chart.pie",
                tint: .cyan
            ))
        }

        if composition.hasUncategorized {
            items.append(OverviewAttentionItem(
                title: "Review account classification",
                detail: "\(composition.uncategorizedAccounts.count) uncategorized account\(composition.uncategorizedAccounts.count == 1 ? "" : "s")",
                systemImage: "questionmark.circle",
                tint: .orange
            ))
        }

        if !hasReliableNetWorthTrend {
            items.append(OverviewAttentionItem(
                title: "Trend history is partial",
                detail: "Net worth trend needs more balance snapshots.",
                systemImage: "chart.line.uptrend.xyaxis",
                tint: .secondary
            ))
        }

        return items
    }

    private var availableAllocationText: String? {
        let display = composition.display(mode: .available)
        guard let liquidity = display.percentage(for: .liquidity),
              let patrimonial = display.percentage(for: .patrimonial) else { return nil }
        return String(format: "%.0f%% liquidity / %.0f%% patrimonial", liquidity, patrimonial)
    }

    // MARK: - Accounts

    private var accountGroups: [DashboardAccountGroup] {
        DashboardAccountGroupBuilder.groups(from: composition, currencyCode: snapshot.currencyCode)
    }

    private var accountsList: some View {
        DashboardListCard(title: "Accounts by Bucket") {
            ForEach(accountGroups) { group in
                DisclosureGroup(isExpanded: binding(for: group.bucket)) {
                    VStack(spacing: 0) {
                        ForEach(group.accounts) { summary in
                            accountRow(summary)
                            if summary.id != group.accounts.last?.id {
                                DashboardSeparator()
                            }
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: iconName(for: group.bucket))
                            .foregroundStyle(tint(for: group.bucket))
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.bucket.rawValue)
                                .font(.callout.weight(.semibold))
                            if let detail = group.detail {
                                Text(detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(MoneyFormat.string(code: snapshot.currencyCode, group.subtotal))
                            .font(.callout.weight(.semibold).monospacedDigit())
                            .foregroundStyle(group.subtotal >= 0 ? .primary : DashboardChartSeriesColor.expense)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .padding(.horizontal, 2)

                if group.id != accountGroups.last?.id {
                    DashboardSeparator()
                }
            }
        }
    }

    private func binding(for bucket: DashboardAccountBucket) -> Binding<Bool> {
        Binding(
            get: { expandedAccountGroups.contains(bucket) },
            set: { isExpanded in
                if isExpanded {
                    expandedAccountGroups.insert(bucket)
                } else {
                    expandedAccountGroups.remove(bucket)
                }
            }
        )
    }

    private func accountRow(_ summary: AccountSummary) -> some View {
        HStack(spacing: 12) {
            accountIcon(for: summary)

            VStack(alignment: .leading, spacing: 3) {
                Text(summary.displayName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(summary.institution)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(NetWorthBreakdownCopy.sourceText(summary))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            if let util = summary.utilizationPercent {
                Text(String(format: "%.0f%%", util * 100))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(util > 0.7 ? .red : (util > 0.3 ? .orange : .secondary))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.tertiary.opacity(0.10), in: Capsule())
            }

            Text(MoneyFormat.string(code: snapshot.currencyCode, summary.latestBalance))
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(summary.latestBalance >= 0 ? .primary : DashboardChartSeriesColor.expense)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Transactions

    private var recentTransactionsList: some View {
        GlassCard(role: .card, interactive: false) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Recent Transactions").font(.headline)
                    Spacer()
                    if let onViewAllTransactions {
                        Button("View all") { onViewAllTransactions() }
                            .controlSize(.small)
                    }
                }
                VStack(spacing: 0) {
                    let rows = Array(snapshot.recentTransactions.prefix(10))
                    ForEach(rows) { tx in
                        Button {
                            onTransactionTap?(tx)
                        } label: {
                            DashboardTransactionRow(transaction: tx)
                        }
                        .buttonStyle(.plain)
                        if tx.id != rows.last?.id {
                            DashboardSeparator()
                        }
                    }
                }
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
            }
            .padding()
        }
    }

    // MARK: - Shared helpers

    private var latestSnapshotPeriod: DashboardPeriodContext {
        DashboardPeriodContext(
            kind: snapshot.period.kind,
            dateRange: snapshot.period.dateRange,
            effectiveNetWorthDate: snapshot.snapshotAsOfDate,
            chartDomain: snapshot.period.chartDomain,
            plotDomain: snapshot.period.plotDomain,
            bucket: snapshot.period.bucket
        )
    }

    private var snapshotAsOfText: String {
        "As of \(shortDate(snapshot.snapshotAsOfDate))"
    }

    private var periodLabel: String {
        snapshot.period.kind == .all ? "All time" : NetWorthBreakdownCopy.periodRange(snapshot.period.dateRange)
    }

    private func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    private func accountIcon(for summary: AccountSummary) -> some View {
        let color = AccountIdentity.defaultMap[summary.institution] ?? .accentColor
        return RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(color.opacity(0.14))
            .overlay {
                Image(systemName: iconName(for: summary.type))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color)
            }
            .frame(width: 28, height: 28)
    }

    private func iconName(for type: AccountType) -> String {
        switch type {
        case .creditCard: "creditcard"
        case .loan: "building.columns"
        case .investment: "chart.line.uptrend.xyaxis"
        case .wallet: "wallet.bifold"
        case .retirement: "calendar"
        case .checking, .savings: "banknote"
        case .other: "questionmark.circle"
        }
    }

    private func iconName(for bucket: DashboardAccountBucket) -> String {
        switch bucket {
        case .liquidity: "banknote"
        case .patrimonial: "chart.line.uptrend.xyaxis"
        case .retirement: "calendar"
        case .liabilities: "creditcard"
        case .uncategorized: "questionmark.circle"
        }
    }

    private func tint(for bucket: DashboardAccountBucket) -> Color {
        switch bucket {
        case .liquidity: NetWorthCompositionBucket.liquidity.color
        case .patrimonial: NetWorthCompositionBucket.patrimonial.color
        case .retirement: NetWorthCompositionBucket.retirement.color
        case .liabilities: DashboardChartSeriesColor.expense
        case .uncategorized: .orange
        }
    }

    private var emptyState: some View {
        GlassCard(role: .card, interactive: false) {
            VStack(spacing: 12) {
                Image(systemName: "tray")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("No transactions yet")
                    .font(.headline)
                Text("Import a bank statement to get started")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(40)
        }
    }
}

private struct OverviewMetricCard: View {
    let title: String
    let amount: Decimal
    let currencyCode: String
    let subtitle: String
    let footnote: String
    let systemImage: String
    let tint: Color
    var prominent = false
    var onTap: (() -> Void)? = nil

    @State private var hovering = false

    var body: some View {
        Button {
            onTap?()
        } label: {
            GlassCard(role: prominent ? .hero : .card, interactive: onTap != nil) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: systemImage)
                        .font(.system(size: prominent ? 19 : 15, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: prominent ? 38 : 30, height: prominent ? 38 : 30)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                    VStack(alignment: .leading, spacing: prominent ? 10 : 6) {
                        Text(title)
                            .font(prominent ? .headline : .caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(MoneyFormat.string(code: currencyCode, amount))
                            .font(.system(size: prominent ? 34 : 21, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(tint)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                        Text(subtitle)
                            .font(prominent ? .subheadline : .caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Text(footnote)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(prominent ? 18 : 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scaleEffect(hovering && onTap != nil ? 1.01 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct OverviewPanel<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        GlassCard(role: .card, interactive: false) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: systemImage)
                        .foregroundStyle(.secondary)
                    Text(title).font(.headline)
                }
                content()
            }
            .padding()
        }
    }
}

private struct OverviewAttentionItem: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color
}
