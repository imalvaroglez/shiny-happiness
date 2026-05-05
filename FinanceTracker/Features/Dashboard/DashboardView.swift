import SwiftUI
import SwiftData
import Charts

struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = DashboardViewModel()
    @State private var selectedRange: TimeRange = .year

    enum TimeRange: String, CaseIterable {
        case month = "Month"
        case quarter = "Quarter"
        case year = "Year"
        case all = "All"

        var dateRange: DateRange {
            let now = Date()
            let calendar = Calendar(identifier: .gregorian)
            switch self {
            case .month:
                return .month(now)
            case .quarter:
                let start = calendar.date(byAdding: .month, value: -3, to: now)!
                return DateRange(start: start, end: now)
            case .year:
                return .year(now)
            case .all:
                let start = calendar.date(from: DateComponents(year: 2020, month: 1, day: 1))!
                return DateRange(start: start, end: now)
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List {
                NavigationLink("Dashboard", destination: dashboardDetail)
                NavigationLink("Transactions", destination: Text("Transactions"))
                NavigationLink("Import Statements", destination: ImportView(modelContext: modelContext))
                NavigationLink("Settings", destination: Text("Settings"))
            }
            .navigationTitle("FinanceTracker")
            .listStyle(.sidebar)
        } detail: {
            dashboardDetail
        }
        .task {
            SeedDataLoader.bootstrapIfNeeded(context: modelContext)
            viewModel.configure(context: modelContext)
        }
        .onChange(of: selectedRange) {
            viewModel.dateRange = selectedRange.dateRange
            viewModel.refresh()
        }
    }

    private var dashboardDetail: some View {
        ScrollView {
            VStack(spacing: 20) {
                timeRangePicker
                summaryCards

                if !viewModel.monthlyCashFlow.isEmpty {
                    cashFlowChart
                }

                if !viewModel.netWorthOverTime.isEmpty {
                    netWorthChart
                }

                if !viewModel.spendingByCategory.isEmpty {
                    spendingDonut
                }

                if !viewModel.recentTransactions.isEmpty {
                    recentTransactionsList
                }

                if viewModel.totalTransactions == 0 {
                    emptyState
                }
            }
            .padding()
        }
        .navigationTitle("Dashboard")
    }

    private var timeRangePicker: some View {
        Picker("Period", selection: $selectedRange) {
            ForEach(TimeRange.allCases, id: \.self) { range in
                Text(range.rawValue).tag(range)
            }
        }
        .pickerStyle(.segmented)
    }

    private var summaryCards: some View {
        HStack(spacing: 16) {
            SummaryCard(title: "Income", amount: viewModel.totalIncome, color: .green)
            SummaryCard(title: "Expenses", amount: abs(viewModel.totalExpenses), color: .red)
            SummaryCard(title: "Net", amount: viewModel.totalIncome + viewModel.totalExpenses, color: .blue)
        }
    }

    private var cashFlowChart: some View {
        VStack(alignment: .leading) {
            Text("Cash Flow")
                .font(.headline)
            Chart(viewModel.monthlyCashFlow) { entry in
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
            .chartXAxis {
                AxisMarks(values: .stride(by: .month)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month(.abbreviated))
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var netWorthChart: some View {
        VStack(alignment: .leading) {
            Text("Net Worth")
                .font(.headline)
            Chart(viewModel.netWorthOverTime) { point in
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
                .foregroundStyle(.blue.opacity(0.1))
                .interpolationMethod(.catmullRom)
            }
            .frame(height: 200)
            .chartXAxis {
                AxisMarks(values: .stride(by: .month)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month(.abbreviated))
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var spendingDonut: some View {
        VStack(alignment: .leading) {
            Text("Spending by Category")
                .font(.headline)
            Chart(viewModel.spendingByCategory.prefix(8)) { entry in
                SectorMark(
                    angle: .value("Amount", entry.amount),
                    innerRadius: .ratio(0.5),
                    angularInset: 1.5
                )
                .foregroundStyle(colorForCategory(entry.category.name))
                .annotation(position: .overlay) {
                    if entry.amount > viewModel.spendingByCategory.prefix(8).reduce(Decimal.zero) { $0 + $1.amount } / 5 {
                        VStack(spacing: 2) {
                            Text(entry.category.name)
                                .font(.caption2)
                                .fontWeight(.semibold)
                            Text(formatMoney(entry.amount))
                                .font(.caption2)
                        }
                        .foregroundStyle(.white)
                    }
                }
            }
            .frame(height: 250)

            ForEach(viewModel.spendingByCategory.prefix(8)) { entry in
                HStack {
                    Circle()
                        .fill(colorForCategory(entry.category.name))
                        .frame(width: 8, height: 8)
                    Text(entry.category.name)
                        .font(.caption)
                    Spacer()
                    Text(formatMoney(entry.amount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var recentTransactionsList: some View {
        VStack(alignment: .leading) {
            Text("Recent Transactions")
                .font(.headline)
            ForEach(viewModel.recentTransactions.prefix(10)) { tx in
                TransactionRow(transaction: tx)
                if tx.id != viewModel.recentTransactions.prefix(10).last?.id {
                    Divider()
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
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

    private func formatMoney(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "MXN"
        return formatter.string(from: amount as NSDecimalNumber) ?? "$0.00"
    }

    private func colorForCategory(_ name: String) -> Color {
        let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .yellow, .teal, .indigo]
        let index = abs(name.hashValue) % colors.count
        return colors[index]
    }
}

private struct SummaryCard: View {
    let title: String
    let amount: Decimal
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(formatMoney(amount))
                .font(.title2.bold())
                .foregroundStyle(amount >= 0 ? color : .red)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func formatMoney(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "MXN"
        return formatter.string(from: amount as NSDecimalNumber) ?? "$0.00"
    }
}

private struct TransactionRow: View {
    let transaction: Transaction

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.merchantNormalized.isEmpty ? transaction.descriptionRaw : transaction.merchantNormalized)
                    .font(.body)
                    .lineLimit(1)
                Text(transaction.postedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(formatMoney(transaction.amount))
                .font(.body.bold())
                .foregroundStyle(transaction.amount >= 0 ? .green : .primary)
        }
        .padding(.vertical, 4)
    }

    private func formatMoney(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "MXN"
        return formatter.string(from: amount as NSDecimalNumber) ?? "$0.00"
    }
}

#Preview {
    DashboardView()
}
