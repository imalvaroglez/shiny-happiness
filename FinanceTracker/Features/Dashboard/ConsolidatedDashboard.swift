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
    /// When true, Spending by Category shows every category instead of top-5 +
    /// "Other". Toggled by the "Other" warning chip so the user can see exactly
    /// which smaller categories make up the remainder (the warning is honest
    /// about Other being an aggregation, not a category).
    @State private var showAllCategories = false

    private var composition: NetWorthComposition { snapshot.netWorthComposition }

    var body: some View {
        VStack(alignment: .leading, spacing: DashboardCardTokens.topStackSpacing) {
            // ① Financial Snapshot
            financialSnapshotSection

            // ② Insights
            insightsSection

            // ③ Trends
            trendsSection

            // ④ Breakdowns
            breakdownsSection

            if !accountGroups.isEmpty { accountsList }
            if !snapshot.recentTransactions.isEmpty { recentTransactionsList }
            if snapshot.totalTransactions == 0 { emptyState }
        }
        .sheet(item: $breakdown) { req in
            BreakdownSheet(request: req)
        }
    }

    // MARK: - ① Financial Snapshot

    private var financialSnapshotSection: some View {
        VStack(alignment: .leading, spacing: DashboardCardTokens.sectionSpacing) {
            DashboardSectionHeader(title: "Financial Snapshot", systemImage: "square.grid.2x2")
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
    }

    private var availableNetWorthHeroDelta: (percent: Double, tone: DashboardTone)? {
        guard let delta = NetWorthDeltaBuilder.delta(series: snapshot.availableNetWorthOverTime),
              let pct = delta.percent else { return nil }
        return (pct, delta.absolute >= 0 ? .positive : .negative)
    }

    @ViewBuilder
    private var availableNetWorthSplit: some View {
        // Hero enrichment: Liquidity / Patrimonial split + quiet sparkline.
        // Sparkline source matches the hero metric (available NW, excludes
        // retirement) — refinement #2.
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 18) {
                splitItem(label: "Liquidity", value: composition.netLiquidity)
                splitItem(label: "Patrimonial", value: composition.patrimonial)
            }
            DashboardNetWorthSparkline(points: snapshot.availableNetWorthOverTime, tint: .secondary)
        }
    }

    private func splitItem(label: String, value: Decimal) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(MoneyFormat.string(code: snapshot.currencyCode, value))
                .font(.callout.weight(.semibold).monospacedDigit())
        }
    }

    private var availableNetWorthCard: some View {
        DashboardMetricCard(
            title: "Available Net Worth",
            amount: composition.availableNetWorth,
            currencyCode: snapshot.currencyCode,
            periodLabel: .asOf(snapshot.snapshotAsOfDate),
            systemImage: "banknote",
            tone: DashboardTone.signed(composition.availableNetWorth),
            subtitle: "Excluding retirement",
            prominent: true,
            deltaPercent: availableNetWorthHeroDelta?.percent,
            deltaTone: availableNetWorthHeroDelta?.tone ?? .positive,
            accessory: AnyView(availableNetWorthSplit)
        ) {
            breakdown = .netWorth(period: latestSnapshotPeriod, accounts: snapshot.overviewAccountSummaries)
        }
    }

    private var secondaryMetricGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], alignment: .leading, spacing: 12) {
            DashboardMetricCard(
                title: "Total Net Worth",
                amount: composition.totalNetWorth,
                currencyCode: snapshot.currencyCode,
                periodLabel: .asOf(snapshot.snapshotAsOfDate),
                systemImage: "chart.pie",
                tone: DashboardTone.signed(composition.totalNetWorth),
                subtitle: "Includes retirement"
            ) {
                breakdown = .netWorth(period: latestSnapshotPeriod, accounts: snapshot.overviewAccountSummaries)
            }

            DashboardMetricCard(
                title: "Card Liabilities",
                amount: composition.totalLiabilities,
                currencyCode: snapshot.currencyCode,
                periodLabel: .asOf(snapshot.snapshotAsOfDate),
                systemImage: "creditcard",
                tone: .negative,
                subtitle: "Short-term debt"
            ) {
                breakdown = .netWorth(period: latestSnapshotPeriod, accounts: snapshot.overviewAccountSummaries)
            }

            DashboardMetricCard(
                title: "Net Cash Flow",
                amount: snapshot.netCashFlow,
                currencyCode: snapshot.currencyCode,
                periodLabel: .period(periodLabel),
                systemImage: "arrow.left.arrow.right",
                tone: DashboardTone.signed(snapshot.netCashFlow),
                subtitle: "Income − expenses"
            )

            DashboardMetricCard(
                title: "Interest Earned",
                amount: snapshot.totalInterestEarned,
                currencyCode: snapshot.currencyCode,
                periodLabel: .period(periodLabel),
                systemImage: "percent",
                tone: .yield,
                subtitle: "Period interest"
            ) {
                breakdown = .interest(transactions: snapshot.recentTransactions, total: snapshot.totalInterestEarned)
            }
        }
    }

    // MARK: - ② Insights

    private var insightsSection: some View {
        VStack(alignment: .leading, spacing: DashboardCardTokens.sectionSpacing) {
            DashboardSectionHeader(title: "Insights — What Needs Your Attention", systemImage: "sparkles")
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    cardPaceCard
                    upcomingPaymentsCard
                    spendingAnomalyCard
                }
                VStack(spacing: 12) {
                    cardPaceCard
                    upcomingPaymentsCard
                    spendingAnomalyCard
                }
            }
        }
    }

    private var cardPaceCard: some View {
        let pace = snapshot.cardPace
        let status = mapPaceStatus(pace.status)
        let monthLabel = calendarMonthToDateLabel()
        let dailyAvg = MoneyFormat.string(code: snapshot.currencyCode, pace.dailyAverage)
        let projected = MoneyFormat.string(code: snapshot.currencyCode, pace.projectedMonthEnd)
        let spent = MoneyFormat.string(code: snapshot.currencyCode, pace.spentToDate) + " spent"

        return DashboardInsightCard(
            title: "Credit Card Pace",
            systemImage: "creditcard.and.123",
            status: status,
            statusText: paceStatusText(pace.status),
            primary: spent,
            secondaryLines: pace.status == .insufficientHistory
                ? []
                : ["Daily avg \(dailyAvg)", "Projected month-end \(projected)"],
            periodLabel: .calendarMonthToDate(monthLabel),
            calmMessage: pace.status == .insufficientHistory ? "Not enough history yet" : nil
        ) {
            // ponytail: progress bar omitted in insufficient-history state.
            if pace.status != .insufficientHistory {
                PaceProgressBar(day: pace.dayOfMonth, days: pace.daysInMonth, status: status)
            }
        }
    }

    private var upcomingPaymentsCard: some View {
        let payments = snapshot.upcomingPayments
        let status = mapPaymentStatus(payments.status)
        let total = MoneyFormat.string(code: snapshot.currencyCode, payments.totalPrimary)
        let isCalm = payments.due.isEmpty

        var secondary: [String] = []
        for payment in payments.due.prefix(3) {
            let amount = MoneyFormat.string(code: snapshot.currencyCode, payment.primaryAmount ?? 0)
            // No-interest-first (D12): label the primary as "to avoid interest"
            // when available, and surface the minimum as a smaller secondary.
            let qualifier: String
            if payment.hasNoInterest {
                let minimumText = payment.minimumAmount.map {
                    " (min \(MoneyFormat.string(code: snapshot.currencyCode, $0)))"
                } ?? ""
                qualifier = " to avoid interest\(minimumText)"
            } else {
                qualifier = " minimum"
            }
            let due = payment.dueDate.formatted(.dateTime.month(.abbreviated).day())
            secondary.append("\(payment.institution)  \(amount)\(qualifier) · \(due)")
        }

        return DashboardInsightCard(
            title: "Upcoming Payments",
            systemImage: "calendar.badge.clock",
            status: status,
            statusText: isCalm ? nil : paymentStatusText(payments.status),
            primary: isCalm ? "" : "\(total) due in next 14 days",
            secondaryLines: secondary,
            periodLabel: .calendarMonthToDate("Next 14 days"),
            calmMessage: isCalm ? "No payments due soon" : nil
        ) {
            EmptyView()
        }
    }

    private var spendingAnomalyCard: some View {
        let anomaly = snapshot.spendingAnomaly
        let status: InsightStatus = anomaly.isCalm ? .calm : .watch

        if anomaly.wasSkipped {
            // Honestly distinct from "clean": the check was intentionally not
            // run for this range (.year/.all perf guardrail).
            return DashboardInsightCard(
                title: "Spending Anomaly",
                systemImage: "chart.bar.xaxis",
                status: .calm,
                primary: "",
                secondaryLines: [],
                periodLabel: .period(periodLabel),
                calmMessage: "Not shown for this range — switch to Month or Quarter"
            ) { EmptyView() }
        }

        if anomaly.isCalm {
            return DashboardInsightCard(
                title: "Spending Anomaly",
                systemImage: "chart.bar.xaxis",
                status: .calm,
                primary: "",
                secondaryLines: [],
                periodLabel: .period("vs previous \(periodLabel)"),
                calmMessage: "No unusual spending detected"
            ) { EmptyView() }
        }

        let strongest = anomaly.strongest!
        let primary = "\(strongest.categoryName) \(formatSignedPercent(strongest.percentChange))"
        var secondary: [String] = []
        for other in anomaly.others {
            secondary.append("\(other.categoryName) \(formatSignedPercent(other.percentChange))")
        }

        return DashboardInsightCard(
            title: "Spending Anomaly",
            systemImage: "chart.bar.xaxis",
            status: status,
            statusText: "WATCH",
            primary: primary,
            secondaryLines: ["vs previous \(periodLabel)"] + secondary,
            periodLabel: .period(periodLabel)
        ) {
            EmptyView()
        }
    }

    // MARK: - ③ Trends

    private var trendsSection: some View {
        VStack(alignment: .leading, spacing: DashboardCardTokens.sectionSpacing) {
            DashboardSectionHeader(title: "Trends", systemImage: "chart.line.uptrend.xyaxis")
            ViewThatFits(in: .horizontal) {
                LazyVGrid(columns: twoChartColumns, alignment: .leading, spacing: 16) {
                    cashFlowChart
                    netWorthChart
                }
                .frame(minWidth: 860)
                LazyVGrid(columns: oneChartColumn, alignment: .leading, spacing: 16) {
                    cashFlowChart
                    netWorthChart
                }
            }
        }
    }

    // MARK: - ④ Breakdowns

    private var breakdownsSection: some View {
        VStack(alignment: .leading, spacing: DashboardCardTokens.sectionSpacing) {
            DashboardSectionHeader(title: "Breakdowns", systemImage: "chart.pie")
            ViewThatFits(in: .horizontal) {
                LazyVGrid(columns: twoChartColumns, alignment: .leading, spacing: 16) {
                    netWorthCompositionCard
                    spendingBars
                }
                .frame(minWidth: 860)
                LazyVGrid(columns: oneChartColumn, alignment: .leading, spacing: 16) {
                    netWorthCompositionCard
                    spendingBars
                }
            }
        }
    }


    // MARK: - Overview grid (legacy 6-card grid removed; sections replace it)

    private var twoChartColumns: [GridItem] {
        [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]
    }

    private var oneChartColumn: [GridItem] {
        [GridItem(.flexible(), spacing: 16)]
    }

    // MARK: - Cash flow

    enum CashFlowSeries: String, CaseIterable, Identifiable {
        case income = "Income"
        case expenses = "Expenses"
        var id: String { rawValue }
        var color: Color { self == .income ? DashboardChartSeriesColor.income : DashboardChartSeriesColor.expense }
    }

    private var cashFlowChart: some View {
        DashboardChartPanel(
            title: "Cash Flow",
            subtitle: cashFlowSummarySubtitle,
            headerAccessory: AnyView(seriesFilter),
            strokePlot: false
        ) {
            VStack(alignment: .leading, spacing: 8) {
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
        DashboardChartPanel(
            title: "Net Worth Trend",
            subtitle: periodLabel,
            headerAccessory: AnyView(netWorthDeltaAccessory),
            strokePlot: false
        ) {
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

    @ViewBuilder
    private var netWorthDeltaAccessory: some View {
        if let delta = NetWorthDeltaBuilder.delta(series: snapshot.netWorthOverTime), let pct = delta.percent {
            DeltaBadge(percent: pct, tone: delta.absolute >= 0 ? .positive : .negative)
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

    // MARK: - Spending (matte bars + Other warning, D9/refinement #5)

    private var spendingBars: some View {
        DashboardBreakdownPanel(title: "Spending by Category", subtitle: spendingTotalSubtitle, strokePlot: false) {
            VStack(alignment: .leading, spacing: 8) {
                DashboardSpendingCategoryBars(
                    entries: snapshot.spendingByCategory,
                    currencyCode: snapshot.currencyCode,
                    limit: showAllCategories ? snapshot.spendingByCategory.count : 5
                ) { entry in
                    breakdown = .categorySpending(category: entry.category, amount: entry.amount, transactions: snapshot.recentTransactions)
                }

                if let other = otherWarning {
                    // "Other" is the aggregation remainder beyond the top-N
                    // categories shown — it can include categorized spend, so
                    // the action expands the list in place (honest about what
                    // Other contains) rather than routing to uncategorized rows
                    // that wouldn't explain the amount.
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showAllCategories.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: showAllCategories ? "chevron.up" : "exclamationmark.triangle.fill")
                            Text(showAllCategories ? "Showing all categories" : other)
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(DashboardTone.warning.color, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showAllCategories ? "Collapse spending categories" : other)
                    .accessibilityHint("Shows the smaller categories grouped into Other")
                }
            }
        }
    }

    private var spendingTotalSubtitle: String {
        "Total expenses \(MoneyFormat.string(code: snapshot.currencyCode, abs(snapshot.totalExpenses)))"
    }

    /// Warning copy when "Other" (the aggregation remainder beyond the top 5
    /// shown) is ≥ 40% of period spending (refinement #5, exact threshold).
    /// "Other" groups smaller categories — it is not the same as uncategorized.
    private var otherWarning: String? {
        let total = snapshot.spendingByCategory.reduce(Decimal(0)) { $0 + $1.amount }
        guard total > 0 else { return nil }
        let topN = snapshot.spendingByCategory.prefix(5).reduce(Decimal(0)) { $0 + $1.amount }
        let otherAmount = max(total - topN, 0)
        let otherPercent = ((otherAmount / total) as NSDecimalNumber).doubleValue * 100
        guard otherPercent >= 40 else { return nil }
        let percentText = String(format: "%.1f%%", otherPercent)
        return "\(percentText) of spend is in smaller categories — expand to review"
    }

    // MARK: - Insight status mapping

    private func mapPaceStatus(_ status: CardPaceSnapshot.PaceStatus) -> InsightStatus {
        switch status {
        case .calm: return .calm
        case .watch: return .watch
        case .critical: return .critical
        case .insufficientHistory: return .calm
        }
    }

    private func paceStatusText(_ status: CardPaceSnapshot.PaceStatus) -> String? {
        switch status {
        case .critical: return "ABOVE PACE"
        case .watch: return "ON PACE"
        case .calm: return nil
        case .insufficientHistory: return nil
        }
    }

    private func mapPaymentStatus(_ status: UpcomingPaymentsSnapshot.PaymentStatus) -> InsightStatus {
        switch status {
        case .calm: return .calm
        case .watch: return .watch
        case .critical: return .critical
        }
    }

    private func paymentStatusText(_ status: UpcomingPaymentsSnapshot.PaymentStatus) -> String {
        switch status {
        case .calm: return ""
        case .watch: return "DUE SOON"
        case .critical: return "DUE ≤3 DAYS"
        }
    }

    /// "Calendar month to date" label for Credit Card Pace (D5/refinement #7).
    /// Never "Last 30 days".
    private func calendarMonthToDateLabel() -> String {
        let calendar = Calendar(identifier: .gregorian)
        guard let monthStart = calendar.dateInterval(of: .month, for: snapshot.snapshotAsOfDate)?.start else {
            return "Calendar month to date"
        }
        let today = snapshot.snapshotAsOfDate.formatted(.dateTime.month(.abbreviated).day())
        let start = monthStart.formatted(.dateTime.month(.abbreviated).day())
        return start == today ? "Calendar month to date" : "\(start) – today"
    }

    private func formatSignedPercent(_ value: Double) -> String {
        String(format: "%+.0f%%", value)
    }

    private var cashFlowSummarySubtitle: String {
        let net = MoneyFormat.string(code: snapshot.currencyCode, snapshot.netCashFlow)
        let income = MoneyFormat.string(code: snapshot.currencyCode, snapshot.totalIncome)
        let out = MoneyFormat.string(code: snapshot.currencyCode, abs(snapshot.totalExpenses))
        return "Net \(net) · In \(income) · Out \(out)"
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

/// Day-N-of-month progress bar for the Credit Card Pace card.
struct PaceProgressBar: View {
    let day: Int
    let days: Int
    let status: InsightStatus

    var body: some View {
        let progress = days > 0 ? min(Double(day) / Double(days), 1.0) : 0
        VStack(alignment: .leading, spacing: 3) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.secondary.opacity(0.18))
                    Capsule()
                        .fill(status.tone.color)
                        .frame(width: proxy.size.width * progress)
                }
            }
            .frame(height: 5)
            HStack {
                Text("Day \(day) of \(days)")
                Spacer()
                Text("\(Int((progress * 100).rounded()))% of month")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
        }
    }
}

