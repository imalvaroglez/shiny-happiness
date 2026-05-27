import SwiftUI
import Charts

/// Per-account dashboard for checking / savings / investment accounts. Same
/// pattern as ConsolidatedDashboard but scoped to one account.
struct AssetAccountDashboard: View {
    let snapshot: AssetAccountSnapshot

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
                BarMark(
                    x: .value("Month", entry.month, unit: .month),
                    y: .value("Expenses", abs(entry.expenses))
                )
                .foregroundStyle(.red)
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
                if let hover = cashFlowHover,
                   let entry = snapshot.monthlyCashFlow.first(where: { Calendar.current.isDate($0.month, equalTo: hover, toGranularity: .month) }),
                   let xPos = proxy.position(forX: entry.month) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.month, format: .dateTime.month(.wide).year()).font(.caption.bold())
                        Text("Income: \(MoneyFormat.string(code: snapshot.currencyCode,entry.income))").font(.caption2).foregroundStyle(.green)
                        Text("Expenses: \(MoneyFormat.string(code: snapshot.currencyCode,abs(entry.expenses)))").font(.caption2).foregroundStyle(.red)
                    }
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .position(x: xPos, y: 24)
                }
            }
        }
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
                if let hover = balanceHover,
                   let point = snapshot.balanceOverTime.first(where: { Calendar.current.isDate($0.month, equalTo: hover, toGranularity: .month) }),
                   let xPos = proxy.position(forX: point.month) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(point.month, format: .dateTime.month(.wide).year()).font(.caption.bold())
                        Text(MoneyFormat.string(code: snapshot.currencyCode,point.balance)).font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .position(x: xPos, y: 24)
                }
            }
        }
    }

    private var spendingDonut: some View {
        let top = Array(snapshot.spendingByCategory.prefix(8))
        let total = top.reduce(Decimal.zero) { $0 + $1.amount }
        return ChartCard(title: "Spending by Category") {
            Chart(top) { entry in
                SectorMark(
                    angle: .value("Amount", entry.amount),
                    innerRadius: .ratio(0.5),
                    angularInset: 1.5
                )
                .foregroundStyle(CategoryPalette.color(for: entry.category.name))
                .annotation(position: .overlay) {
                    if entry.amount > total / 5 {
                        VStack(spacing: 2) {
                            Text(entry.category.name).font(.caption2).fontWeight(.semibold)
                            Text(MoneyFormat.string(code: snapshot.currencyCode,entry.amount)).font(.caption2)
                        }
                        .foregroundStyle(.white)
                    }
                }
            }
            .frame(height: 220)

            ForEach(top) { entry in
                Button {
                    breakdown = .categorySpending(category: entry.category, amount: entry.amount, transactions: snapshot.recentTransactions)
                } label: {
                    HStack {
                        Circle().fill(CategoryPalette.color(for: entry.category.name)).frame(width: 8, height: 8)
                        Text(entry.category.name).font(.caption)
                        Spacer()
                        Text(MoneyFormat.string(code: snapshot.currencyCode,entry.amount)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var recentList: some View {
        DashboardListCard(title: "Recent Transactions") {
            ForEach(snapshot.recentTransactions.prefix(10)) { tx in
                DashboardTransactionRow(transaction: tx)
                if tx.id != snapshot.recentTransactions.prefix(10).last?.id {
                    DashboardSeparator()
                }
            }
        }
    }
}
