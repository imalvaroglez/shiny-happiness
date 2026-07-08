import SwiftUI
import Charts

/// Per-account dashboard for checking / savings / investment accounts. Same
/// pattern as ConsolidatedDashboard but scoped to one account.
struct AssetAccountDashboard: View {
    let snapshot: AssetAccountSnapshot
    var onTransactionTap: ((Transaction) -> Void)? = nil
    var onRefreshPrices: (() async -> String?)? = nil
    var onEditPositions: (() -> Void)? = nil

    @State private var breakdown: BreakdownRequest? = nil
    @State private var balanceHover: Date? = nil
    @State private var isRefreshingPrices = false
    @State private var refreshError: String? = nil

    var body: some View {
        VStack(spacing: 20) {
            summaryCards
            portfolioSection
            if !snapshot.monthlyCashFlow.isEmpty { cashFlowChart }
            if snapshot.balanceOverTime.isEmpty {
                insufficientBalanceCard
            } else {
                balanceChart
            }
            if !snapshot.spendingByCategory.isEmpty { spendingDonut }
            if !snapshot.recentTransactions.isEmpty { recentList }
        }
        .sheet(item: $breakdown) { req in
            BreakdownSheet(request: req)
        }
    }

    @ViewBuilder
    private var portfolioSection: some View {
        if let portfolio = snapshot.portfolio, portfolio.inPortfolioMode {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Portfolio")
                            .font(.headline)
                        if let amount = portfolio.valuationAmount, let date = portfolio.valuationDate {
                            Text(MoneyFormat.string(amount, code: snapshot.currencyCode))
                                .font(.title2.bold())
                                .money()
                            Text("Valued as of \(date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("No portfolio valuation for this period")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button {
                        refreshPrices()
                    } label: {
                        if isRefreshingPrices {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Refresh prices", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(isRefreshingPrices || onRefreshPrices == nil)

                    Button("Edit Positions") {
                        onEditPositions?()
                    }
                    .disabled(onEditPositions == nil)
                }

                if PortfolioDashboardCopy.showsHoldingsWarning(portfolio: portfolio) {
                    Text("Holdings changed — refresh prices to update the period valuation and growth.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if let refreshError {
                    Text(refreshError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                portfolioSummaryRow(
                    title: "Total invested",
                    amount: portfolio.totalInvested,
                    growth: portfolio.totalGrowthPercent
                )

                Text("Latest positions / quotes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                positionsList(portfolio.rows)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func portfolioSummaryRow(title: String, amount: Decimal, growth: Double?) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(MoneyFormat.string(amount, code: snapshot.currencyCode))
                .money()
            if let growth {
                Text(String(format: "%+.1f%%", growth))
                    .monospacedDigit()
                    .foregroundStyle(growth >= 0 ? .green : .red)
            }
        }
        .font(.callout)
    }

    private func positionsList(_ rows: [PortfolioViewData.PositionRow]) -> some View {
        VStack(spacing: 0) {
            portfolioHeaderRow
            ForEach(rows) { row in
                Divider()
                portfolioPositionRow(row)
            }
        }
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var portfolioHeaderRow: some View {
        HStack {
            Text("Ticker").frame(width: 110, alignment: .leading)
            Text("Shares").frame(width: 90, alignment: .trailing)
            Text("Avg cost").frame(width: 120, alignment: .trailing)
            Text("Last").frame(width: 120, alignment: .trailing)
            Text("Value").frame(width: 120, alignment: .trailing)
            Text("Growth").frame(width: 80, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func portfolioPositionRow(_ row: PortfolioViewData.PositionRow) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.ticker)
                    .font(.callout.weight(.semibold))
                if let name = row.name, !name.isEmpty {
                    Text(name)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: 110, alignment: .leading)
            Text(decimalText(row.shares)).frame(width: 90, alignment: .trailing)
            Text(MoneyFormat.string(row.averageCost, code: snapshot.currencyCode)).frame(width: 120, alignment: .trailing)
            Text(row.lastPrice.map { MoneyFormat.string($0, code: snapshot.currencyCode) } ?? "—").frame(width: 120, alignment: .trailing)
            Text(row.value.map { MoneyFormat.string($0, code: snapshot.currencyCode) } ?? "Not priced").frame(width: 120, alignment: .trailing)
            Text(row.growthPercent.map { String(format: "%+.1f%%", $0) } ?? "—")
                .foregroundStyle((row.growthPercent ?? 0) >= 0 ? .green : .red)
                .frame(width: 80, alignment: .trailing)
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func refreshPrices() {
        guard !isRefreshingPrices, let onRefreshPrices else { return }
        Task { @MainActor in
            isRefreshingPrices = true
            refreshError = nil
            refreshError = await onRefreshPrices()
            isRefreshingPrices = false
        }
    }

    private func decimalText(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }

    private var summaryCards: some View {
        HStack(spacing: 16) {
            SummaryCard(title: "Balance", amount: snapshot.currentBalance, currencyCode: snapshot.currencyCode, copyableAmount: true)
            SummaryCard(title: "Income", amount: snapshot.totalIncome, currencyCode: snapshot.currencyCode, tint: .green) {
                breakdown = .income(transactions: snapshot.recentTransactions, total: snapshot.totalIncome)
            }
            SummaryCard(title: "Expenses", amount: abs(snapshot.totalExpenses), currencyCode: snapshot.currencyCode, tint: .red) {
                breakdown = .expenses(transactions: snapshot.recentTransactions, total: snapshot.totalExpenses)
            }
            fourthSummaryCard
        }
    }

    /// Retirement accounts show observed balance movement for the period
    /// (matches the Balance Over Time chart) instead of Interest Earned;
    /// every other asset account keeps Interest Earned.
    @ViewBuilder private var fourthSummaryCard: some View {
        if snapshot.account.type == .retirement {
            SummaryCard(
                title: "Balance Change",
                amount: snapshot.balanceChange,
                currencyCode: snapshot.currencyCode,
                subtitle: snapshot.balanceChangePercentage.map { String(format: "%+.1f%%", $0) }
            )
        } else {
            SummaryCard(title: "Interest Earned", amount: snapshot.totalInterestEarned, currencyCode: snapshot.currencyCode, tint: .mint) {
                breakdown = .interest(transactions: snapshot.recentTransactions, total: snapshot.totalInterestEarned)
            }
        }
    }

    private var cashFlowChart: some View {
        ChartCard(title: "Cash Flow") {
            DashboardGroupedPeriodBarChart(
                groups: cashFlowBarGroups,
                firstSeriesName: "Income",
                secondSeriesName: "Expenses",
                firstColor: DashboardChartSeriesColor.income,
                secondColor: DashboardChartSeriesColor.expense,
                currencyCode: snapshot.currencyCode,
                emptyMessage: "No cash flow activity for this period.",
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

    private var balanceChart: some View {
        ChartCard(title: "Balance Over Time", subtitle: periodLabel) {
            DashboardBalanceTimeSeriesChart(
                points: snapshot.balanceOverTime,
                period: snapshot.period,
                currencyCode: snapshot.currencyCode,
                hoverBucketStart: $balanceHover
            )
        }
    }

    private var insufficientBalanceCard: some View {
        ChartCard(title: "Balance Over Time", subtitle: periodLabel) {
            DashboardChartEmptyState(message: "Not enough balance history to calculate this account balance for the selected period.")
        }
    }

    private var spendingDonut: some View {
        let top = Array(snapshot.spendingByCategory.prefix(8))
        return ChartCard(title: "Spending by Category") {
            SpendingCategoryDonut(
                entries: top,
                currencyCode: snapshot.currencyCode
            ) { entry in
                breakdown = .categorySpending(category: entry.category, amount: entry.amount, transactions: snapshot.recentTransactions)
            }
        }
    }

    private var recentList: some View {
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

    private var periodLabel: String {
        snapshot.period.kind == .all ? "All time" : NetWorthBreakdownCopy.periodRange(snapshot.period.dateRange)
    }
}

enum PortfolioDashboardCopy {
    static func refreshMessage(for outcome: PortfolioPriceRefresher.Outcome) -> String? {
        switch outcome {
        case .priced:
            nil
        case .partial(let missing):
            if missing.isEmpty {
                "Some positions could not be priced. No portfolio valuation was saved."
            } else {
                "Some positions could not be priced: \(missing.joined(separator: ", ")). No portfolio valuation was saved."
            }
        case .empty:
            "No active positions to price."
        case .notAuthenticated:
            "Add your DataBursatil token in Settings before refreshing prices."
        case .failed:
            "Could not refresh prices from DataBursatil."
        }
    }

    static func hidesManualActions(portfolio: PortfolioViewData?) -> Bool {
        portfolio?.inPortfolioMode == true
    }

    static func showsHoldingsWarning(portfolio: PortfolioViewData) -> Bool {
        portfolio.inPortfolioMode && !portfolio.holdingsFingerprintMatches
    }
}

#Preview("Retirement Balance Change") {
    let calendar = Calendar(identifier: .gregorian)
    let end = Date.now
    let start = calendar.date(byAdding: .month, value: -3, to: end) ?? end

    AssetAccountDashboard(snapshot: AssetAccountSnapshot(
        period: DashboardPeriodContext(
            kind: .custom,
            dateRange: DateRange(start: start, end: end),
            effectiveNetWorthDate: end,
            chartDomain: start...end,
            plotDomain: start...end,
            bucket: .month
        ),
        account: DashboardAccountIdentity(
            id: UUID(),
            displayName: "AFORE Retirement",
            institution: "AFORE",
            type: .retirement,
            currency: "MXN",
            tintHex: nil,
            creditLimit: nil
        ),
        currentBalance: 5_000,
        balanceOverTime: [
            NetWorthPoint(month: start, balance: 4_000),
            NetWorthPoint(month: calendar.date(byAdding: .month, value: 1, to: start) ?? start, balance: 4_500),
            NetWorthPoint(month: calendar.date(byAdding: .month, value: 2, to: start) ?? start, balance: 4_800),
            NetWorthPoint(month: end, balance: 5_000)
        ],
        monthlyCashFlow: [],
        spendingByCategory: [],
        totalIncome: 0,
        totalExpenses: 0,
        totalInterestEarned: 0,
        recentTransactions: [],
        totalTransactions: 0
    ))
}
