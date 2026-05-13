import SwiftUI
import SwiftData
import Charts

/// The default scope: aggregated view across every account. Renders summary tiles
/// for net worth / income / expenses / interest, then the cash-flow bar chart,
/// net-worth line chart, spending donut, recent transactions, and a small
/// per-account list. All cards and chart marks support drill-down via a sheet.
struct ConsolidatedDashboard: View {
    let snapshot: ConsolidatedSnapshot

    @State private var breakdown: BreakdownRequest? = nil
    @State private var cashFlowSeries: Set<CashFlowSeries> = [.income, .expenses]
    @State private var cashFlowHover: Date? = nil
    @State private var netWorthHover: Date? = nil
    @State private var donutHover: Decimal? = nil

    var body: some View {
        VStack(spacing: 20) {
            summaryCards
            if !snapshot.monthlyCashFlow.isEmpty { cashFlowChart }
            if !snapshot.netWorthOverTime.isEmpty { netWorthChart }
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
        GlassEffectContainer {
            HStack(spacing: 16) {
                SummaryCard(title: "Net Worth", amount: snapshot.netWorth, currencyCode: snapshot.currencyCode) {
                    breakdown = .netWorth(snapshot.accountSummaries)
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
    }

    // MARK: - Cash flow

    enum CashFlowSeries: String, CaseIterable, Identifiable {
        case income = "Income"
        case expenses = "Expenses"
        var id: String { rawValue }
        var color: Color { self == .income ? .green : .red }
    }

    private var cashFlowChart: some View {
        ChartCard(title: "Cash Flow") {
            VStack(alignment: .leading, spacing: 8) {
                seriesFilter
                Chart(snapshot.monthlyCashFlow) { entry in
                    if cashFlowSeries.contains(.income) {
                        BarMark(
                            x: .value("Month", entry.month, unit: .month),
                            y: .value("Income", entry.income)
                        )
                        .foregroundStyle(.green)
                    }
                    if cashFlowSeries.contains(.expenses) {
                        BarMark(
                            x: .value("Month", entry.month, unit: .month),
                            y: .value("Expenses", abs(entry.expenses))
                        )
                        .foregroundStyle(.red)
                    }
                }
                .frame(height: 220)
                .chartBackground { _ in Color.clear }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.month(.abbreviated))
                    }
                }
                .chartXSelection(value: $cashFlowHover)
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        if let hover = cashFlowHover,
                           let entry = snapshot.monthlyCashFlow.first(where: { Calendar.current.isDate($0.month, equalTo: hover, toGranularity: .month) }),
                           let xPos = proxy.position(forX: entry.month) {
                            cashFlowTooltip(entry: entry, x: xPos, in: geo)
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

    private func cashFlowTooltip(entry: MonthlyCashFlow, x: CGFloat, in geo: GeometryProxy) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.month, format: .dateTime.month(.wide).year())
                .font(.caption.bold())
            Text("Income: \(MoneyFormat.string(code: snapshot.currencyCode,entry.income))")
                .font(.caption2).foregroundStyle(.green)
            Text("Expenses: \(MoneyFormat.string(code: snapshot.currencyCode,abs(entry.expenses)))")
                .font(.caption2).foregroundStyle(.red)
            Text("Net: \(MoneyFormat.string(code: snapshot.currencyCode,entry.savings))")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .position(x: x, y: 30)
    }

    // MARK: - Net worth

    private var netWorthChart: some View {
        ChartCard(title: "Net Worth") {
            Chart(snapshot.netWorthOverTime) { point in
                LineMark(
                    x: .value("Month", point.month, unit: .month),
                    y: .value("Balance", point.balance)
                )
                .foregroundStyle(.blue)
                .interpolationMethod(.catmullRom)
                AreaMark(
                    x: .value("Month", point.month, unit: .month),
                    y: .value("Balance", point.balance)
                )
                .foregroundStyle(.blue.opacity(0.15))
                .interpolationMethod(.catmullRom)
            }
            .frame(height: 220)
            .chartBackground { _ in Color.clear }
            .chartXAxis {
                AxisMarks(values: .stride(by: .month)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month(.abbreviated))
                }
            }
            .chartXSelection(value: $netWorthHover)
            .chartOverlay { proxy in
                GeometryReader { _ in
                    if let hover = netWorthHover,
                       let point = snapshot.netWorthOverTime.first(where: { Calendar.current.isDate($0.month, equalTo: hover, toGranularity: .month) }),
                       let xPos = proxy.position(forX: point.month) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(point.month, format: .dateTime.month(.wide).year())
                                .font(.caption.bold())
                            Text(MoneyFormat.string(code: snapshot.currencyCode,point.balance))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .position(x: xPos, y: 24)
                    }
                }
            }
            .onTapGesture {
                guard let hover = netWorthHover else { return }
                breakdown = .netWorthMonth(month: hover, accounts: snapshot.accountSummaries)
            }
        }
    }

    // MARK: - Spending donut

    private var spendingDonut: some View {
        let topCategories = Array(snapshot.spendingByCategory.prefix(8))
        let totalAmount = topCategories.reduce(Decimal.zero) { $0 + $1.amount }
        return ChartCard(title: "Spending by Category") {
            Chart(topCategories) { entry in
                SectorMark(
                    angle: .value("Amount", entry.amount),
                    innerRadius: .ratio(0.5),
                    angularInset: 1.5
                )
                .foregroundStyle(CategoryPalette.color(for: entry.category.name))
                .annotation(position: .overlay) {
                    if entry.amount > totalAmount / 5 {
                        VStack(spacing: 2) {
                            Text(entry.category.name)
                                .font(.caption2).fontWeight(.semibold)
                            Text(MoneyFormat.string(code: snapshot.currencyCode,entry.amount))
                                .font(.caption2)
                        }
                        .foregroundStyle(.white)
                    }
                }
            }
            .frame(height: 250)
            .chartAngleSelection(value: $donutHover)

            ForEach(topCategories) { entry in
                Button {
                    breakdown = .categorySpending(category: entry.category, amount: entry.amount, transactions: snapshot.recentTransactions)
                } label: {
                    HStack {
                        Circle()
                            .fill(CategoryPalette.color(for: entry.category.name))
                            .frame(width: 8, height: 8)
                        Text(entry.category.name).font(.caption)
                        Spacer()
                        Text(MoneyFormat.string(code: snapshot.currencyCode,entry.amount))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Accounts list

    private var accountsList: some View {
        ChartCard(title: "Accounts") {
            ForEach(snapshot.accountSummaries) { summary in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary.nickname).font(.body)
                        Text(summary.institution).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let util = summary.utilizationPercent {
                        Text(String(format: "%.0f%%", util * 100))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(util > 0.7 ? .red : (util > 0.3 ? .orange : .secondary))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .glassEffect(.regular, in: .capsule)
                    }
                    Text(MoneyFormat.string(code: snapshot.currencyCode,summary.latestBalance))
                        .font(.body.bold())
                        .foregroundStyle(summary.latestBalance >= 0 ? .green : .red)
                }
                .padding(.vertical, 4)
                if summary.id != snapshot.accountSummaries.last?.id {
                    Divider()
                }
            }
        }
    }

    private var recentTransactionsList: some View {
        ChartCard(title: "Recent Transactions") {
            ForEach(snapshot.recentTransactions.prefix(10)) { tx in
                DashboardTransactionRow(transaction: tx)
                if tx.id != snapshot.recentTransactions.prefix(10).last?.id {
                    Divider()
                }
            }
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

