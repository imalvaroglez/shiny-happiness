import SwiftUI
import Charts

/// Per-account dashboard for checking / savings / investment accounts. Same
/// pattern as ConsolidatedDashboard but scoped to one account.
struct AssetAccountDashboard: View {
    let snapshot: AssetAccountSnapshot
    var onTransactionTap: ((Transaction) -> Void)? = nil

    @State private var breakdown: BreakdownRequest? = nil
    @State private var balanceHover: Date? = nil

    var body: some View {
        VStack(spacing: 20) {
            summaryCards
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

    private var summaryCards: some View {
        HStack(spacing: 16) {
            SummaryCard(title: "Balance", amount: snapshot.currentBalance, currencyCode: snapshot.currencyCode)
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
        ChartCard(title: "Balance Over Time") {
            DashboardBalanceTimeSeriesChart(
                points: snapshot.balanceOverTime,
                period: snapshot.period,
                currencyCode: snapshot.currencyCode,
                hoverBucketStart: $balanceHover
            )
        }
    }

    private var insufficientBalanceCard: some View {
        ChartCard(title: "Balance Over Time") {
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
}
