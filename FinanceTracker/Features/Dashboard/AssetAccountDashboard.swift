import SwiftUI
import Charts

/// Per-account dashboard for checking / savings / investment accounts. Same
/// pattern as ConsolidatedDashboard but scoped to one account.
struct AssetAccountDashboard: View {
    let snapshot: AssetAccountSnapshot
    var onTransactionTap: ((Transaction) -> Void)? = nil

    @State private var breakdown: BreakdownRequest? = nil
    @State private var cashFlowHover: Date? = nil
    @State private var balanceHover: Date? = nil

    var body: some View {
        VStack(spacing: 20) {
            summaryCards
            if !snapshot.monthlyCashFlow.isEmpty { cashFlowChart }
            if !snapshot.balanceOverTime.isEmpty { balanceChart }
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
            Chart(snapshot.monthlyCashFlow) { entry in
                BarMark(
                    x: .value("Month", entry.month, unit: .month),
                    y: .value("Income", entry.income)
                )
                .foregroundStyle(.green)
                .opacity(cashFlowOpacity(for: entry.month))
                BarMark(
                    x: .value("Month", entry.month, unit: .month),
                    y: .value("Expenses", abs(entry.expenses))
                )
                .foregroundStyle(.red)
                .opacity(cashFlowOpacity(for: entry.month))
            }
            .frame(height: 200)
            .chartBackground { _ in Color.clear }
            .chartXSelection(value: $cashFlowHover)
            .chartXAxis {
                AxisMarks(values: .stride(by: .month)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month(.abbreviated))
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    if let hover = cashFlowHover,
                       let entry = snapshot.monthlyCashFlow.first(where: { Calendar.current.isDate($0.month, equalTo: hover, toGranularity: .month) }),
                       let xPos = proxy.position(forX: entry.month) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.month, format: .dateTime.month(.wide).year()).font(.caption.bold())
                            Text("Income: \(MoneyFormat.string(code: snapshot.currencyCode,entry.income))").font(.caption2).foregroundStyle(.green)
                            Text("Expenses: \(MoneyFormat.string(code: snapshot.currencyCode,abs(entry.expenses)))").font(.caption2).foregroundStyle(.red)
                            Text("Net: \(MoneyFormat.string(code: snapshot.currencyCode,entry.savings))").font(.caption2).foregroundStyle(.secondary)
                            if entry.income > 0 {
                                Text("Savings Rate: \(cashFlowSavingsRateText(entry))").font(.caption2).foregroundStyle(entry.savings >= 0 ? .blue : .red)
                            }
                        }
                        .padding(8)
                        .frame(width: 210, alignment: .leading)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .position(x: dashboardTooltipX(xPos, in: geo), y: 30)
                    }
                }
            }
            .onTapGesture {
                guard let hover = cashFlowHover,
                      let entry = snapshot.monthlyCashFlow.first(where: { Calendar.current.isDate($0.month, equalTo: hover, toGranularity: .month) }) else { return }
                breakdown = .cashFlowMonth(month: entry.month, transactions: snapshot.recentTransactions)
            }
        }
    }

    private func cashFlowOpacity(for month: Date) -> Double {
        guard let hover = cashFlowHover else { return 1 }
        return Calendar.current.isDate(month, equalTo: hover, toGranularity: .month) ? 1 : 0.28
    }

    private func cashFlowSavingsRateText(_ entry: MonthlyCashFlow) -> String {
        guard entry.income > 0 else { return "0.0%" }
        let rate = ((entry.savings / entry.income) as NSDecimalNumber).doubleValue * 100
        return String(format: "%.1f%%", rate)
    }

    private var balanceChart: some View {
        ChartCard(title: "Balance Over Time") {
            Chart(snapshot.balanceOverTime) { point in
                LineMark(
                    x: .value("Month", point.month, unit: .month),
                    y: .value("Balance", point.balance)
                )
                .foregroundStyle(.blue)
                .interpolationMethod(.stepEnd)
                AreaMark(
                    x: .value("Month", point.month, unit: .month),
                    y: .value("Balance", point.balance)
                )
                .foregroundStyle(.blue.opacity(0.15))
                .interpolationMethod(.stepEnd)
                PointMark(
                    x: .value("Month", point.month, unit: .month),
                    y: .value("Balance", point.balance)
                )
                .foregroundStyle(.blue)
                .symbolSize(24)
            }
            .frame(height: 200)
            .chartBackground { _ in Color.clear }
            .chartXSelection(value: $balanceHover)
            .chartOverlay { proxy in
                GeometryReader { geo in
                    if let hover = balanceHover,
                       let point = snapshot.balanceOverTime.first(where: { Calendar.current.isDate($0.month, equalTo: hover, toGranularity: .month) }),
                       let xPos = proxy.position(forX: point.month) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(point.month, format: .dateTime.month(.wide).year()).font(.caption.bold())
                            Text(MoneyFormat.string(code: snapshot.currencyCode,point.balance)).font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(8)
                        .frame(width: 190, alignment: .leading)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .position(x: dashboardTooltipX(xPos, in: geo, width: 190), y: 24)
                    }
                }
            }
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
