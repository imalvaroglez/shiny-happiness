import SwiftUI
import SwiftData
import Charts

/// The default scope: aggregated view across every account. Renders summary tiles
/// for net worth / income / expenses / interest, then the cash-flow bar chart,
/// net-worth line chart, spending donut, recent transactions, and a small
/// per-account list. All cards and chart marks support drill-down via a sheet.
struct ConsolidatedDashboard: View {
    let snapshot: ConsolidatedSnapshot
    var onTransactionTap: ((Transaction) -> Void)? = nil

    @State private var breakdown: BreakdownRequest? = nil
    @State private var cashFlowSeries: Set<CashFlowSeries> = [.income, .expenses]
    @State private var netWorthHover: Date? = nil

    var body: some View {
        VStack(spacing: 20) {
            summaryCards
            if !snapshot.monthlyCashFlow.isEmpty { cashFlowChart }
            if snapshot.netWorthOverTime.isEmpty {
                insufficientNetWorthCard
            } else {
                netWorthChart
            }
            if !snapshot.spendingByCategory.isEmpty { spendingDonut }
            if !snapshot.accountSummaries.isEmpty { accountsList }
            if !snapshot.recentTransactions.isEmpty { recentTransactionsList }
            if snapshot.totalTransactions == 0 { emptyState }
        }
        .sheet(item: $breakdown) { req in
            BreakdownSheet(request: req)
        }
    }

    // MARK: - Summary tiles

    private var summaryCards: some View {
        HStack(spacing: 16) {
            SummaryCard(title: "Net Worth", amount: snapshot.netWorth, currencyCode: snapshot.currencyCode) {
                breakdown = .netWorth(period: snapshot.period, accounts: snapshot.accountSummaries)
            }
            SummaryCard(title: "Income", amount: snapshot.totalIncome, currencyCode: snapshot.currencyCode, tint: .green) {
                breakdown = .income(transactions: snapshot.recentTransactions, total: snapshot.totalIncome)
            }
            SummaryCard(title: "Expenses", amount: abs(snapshot.totalExpenses), currencyCode: snapshot.currencyCode, tint: .red) {
                breakdown = .expenses(transactions: snapshot.recentTransactions, total: snapshot.totalExpenses)
            }
            SummaryCard(title: "Interest Earned", amount: snapshot.totalInterestEarned, currencyCode: snapshot.currencyCode, tint: .mint) {
                breakdown = .interest(transactions: snapshot.recentTransactions, total: snapshot.totalInterestEarned)
            }
        }
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
                seriesFilter
                Text("Transfers between your accounts are excluded.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

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
                        return parts.joined(separator: " · ")
                    },
                    onGroupTap: { group in
                        breakdown = .cashFlowPeriod(start: group.bucketStart, bucket: snapshot.period.bucket, transactions: snapshot.recentTransactions)
                    }
                )
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
            Spacer()
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
        ChartCard(title: "Net Worth") {
            DashboardBalanceTimeSeriesChart(
                points: snapshot.netWorthOverTime,
                period: snapshot.period,
                currencyCode: snapshot.currencyCode,
                onPointTap: { _ in
                    breakdown = .netWorth(period: snapshot.period, accounts: snapshot.accountSummaries)
                },
                hoverBucketStart: $netWorthHover
            )
        }
        .onTapGesture {
            if netWorthHover == nil {
                breakdown = .netWorth(period: snapshot.period, accounts: snapshot.accountSummaries)
            }
        }
    }

    private var insufficientNetWorthCard: some View {
        ChartCard(title: "Net Worth") {
            DashboardChartEmptyState(message: "Not enough balance history to calculate net worth for this period.")
        }
    }

    // MARK: - Spending donut

    private var spendingDonut: some View {
        let topCategories = Array(snapshot.spendingByCategory.prefix(8))
        return ChartCard(title: "Spending by Category") {
            SpendingCategoryDonut(
                entries: topCategories,
                currencyCode: snapshot.currencyCode
            ) { entry in
                breakdown = .categorySpending(category: entry.category, amount: entry.amount, transactions: snapshot.recentTransactions)
            }
        }
    }

    // MARK: - Accounts list

    private var accountsList: some View {
        DashboardListCard(title: "Accounts") {
            ForEach(snapshot.accountSummaries) { summary in
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

                    Text(MoneyFormat.string(code: snapshot.currencyCode,summary.latestBalance))
                        .font(.callout.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(summary.latestBalance >= 0 ? .green : .red)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                if summary.id != snapshot.accountSummaries.last?.id {
                    DashboardSeparator()
                }
            }
        }
    }

    private var recentTransactionsList: some View {
        DashboardListCard(title: "Recent Transactions") {
            ForEach(snapshot.recentTransactions.prefix(10)) { tx in
                Button {
                    onTransactionTap?(tx)
                } label: {
                    DashboardTransactionRow(transaction: tx)
                }
                .buttonStyle(.plain)
                if tx.id != snapshot.recentTransactions.prefix(10).last?.id {
                    DashboardSeparator()
                }
            }
        }
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

    private var emptyState: some View {
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
