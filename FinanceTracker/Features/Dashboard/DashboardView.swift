import SwiftUI
import SwiftData
import Charts

struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = DashboardViewModel()
    @State private var selectedRange: TimeRange = .all
    @State private var customStart = Date().addingTimeInterval(-90 * 86400)
    @State private var customEnd = Date()
    @State private var showingCustomRange = false
    @State private var showingImport = false

    enum TimeRange: String, CaseIterable {
        case month = "Month"
        case quarter = "Quarter"
        case year = "Year"
        case all = "All"
        case custom = "Custom"

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
                return DateRange(start: .distantPast, end: now)
            case .custom:
                return DateRange(start: .distantPast, end: now)
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List {
                NavigationLink("Dashboard", destination: dashboardDetail)
                NavigationLink("Transactions", destination: TransactionsView())
                NavigationLink("Import Statements", destination: ImportView(modelContext: modelContext))
                NavigationLink("Settings", destination: SettingsView())
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
        .onAppear {
            viewModel.refresh()
        }
        .onChange(of: selectedRange) {
            if selectedRange == .custom {
                showingCustomRange = true
            } else {
                viewModel.dateRange = selectedRange.dateRange
                viewModel.refresh()
            }
        }
        .popover(isPresented: $showingCustomRange) {
            customDatePopover
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
        .overlay(alignment: .bottomTrailing) {
            Button {
                showingImport = true
            } label: {
                Label("Import Statement", systemImage: "doc.badge.plus")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.glassProminent)
            .padding(20)
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
        GlassEffectContainer {
            HStack(spacing: 16) {
                SummaryCard(title: "Net Worth", amount: viewModel.currentNetWorth)
                SummaryCard(title: "Income", amount: viewModel.totalIncome)
                SummaryCard(title: "Expenses", amount: abs(viewModel.totalExpenses))
                SummaryCard(title: "Interest Earned", amount: viewModel.totalInterestEarned)
            }
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
            .chartBackground { _ in Color.clear }
            .chartXAxis {
                AxisMarks(values: .stride(by: .month)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month(.abbreviated))
                }
            }
        }
        .padding()
        .glassEffect(.regular, in: .rect(cornerRadius: 10))
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
                .foregroundStyle(.blue.opacity(0.15))
                .interpolationMethod(.catmullRom)
            }
            .frame(height: 200)
            .chartBackground { _ in Color.clear }
            .chartXAxis {
                AxisMarks(values: .stride(by: .month)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month(.abbreviated))
                }
            }
        }
        .padding()
        .glassEffect(.regular, in: .rect(cornerRadius: 10))
    }

    private var spendingDonut: some View {
        let topCategories = Array(viewModel.spendingByCategory.prefix(8))
        let totalAmount = topCategories.reduce(Decimal.zero) { $0 + $1.amount }

        return VStack(alignment: .leading) {
            Text("Spending by Category")
                .font(.headline)
            Chart(topCategories) { entry in
                SectorMark(
                    angle: .value("Amount", entry.amount),
                    innerRadius: .ratio(0.5),
                    angularInset: 1.5
                )
                .foregroundStyle(colorForCategory(entry.category.name))
                .annotation(position: .overlay) {
                    if entry.amount > totalAmount / 5 {
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

            ForEach(Array(zip(topCategories.indices, topCategories)), id: \.1.id) { index, entry in
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
        .glassEffect(.regular, in: .rect(cornerRadius: 10))
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
        .glassEffect(.regular, in: .rect(cornerRadius: 10))
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

    private var customDatePopover: some View {
        VStack(spacing: 16) {
            Text("Custom Date Range")
                .font(.headline)
            DatePicker("From", selection: $customStart, displayedComponents: .date)
            DatePicker("To", selection: $customEnd, in: ...Date(), displayedComponents: .date)
            HStack {
                Button("Cancel") {
                    selectedRange = .all
                    showingCustomRange = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    viewModel.dateRange = DateRange(start: customStart, end: customEnd)
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

    private func formatMoney(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "MXN"
        return formatter.string(from: amount as NSDecimalNumber) ?? "$0.00"
    }

    private func colorForCategory(_ name: String) -> Color {
        let map: [String: Color] = [
            "Food & Drink": .orange,
            "Groceries": .orange,
            "Coffee": .orange,
            "Restaurants": .orange,
            "Transport": .blue,
            "Rideshare": .blue,
            "Shopping": .purple,
            "General Merchandise": .purple,
            "Entertainment": .pink,
            "Streaming": .pink,
            "Bills & Utilities": .yellow,
            "Bank Fees": .yellow,
            "Insurance": .yellow,
            "Health": .red,
            "Home": .green,
            "Rent": .green,
            "Travel": .cyan,
            "Flights": .cyan,
            "Transfers": .gray,
            "Internal Transfer": .gray,
            "To Own Accounts": .gray,
            "Credit Card Payments": .gray,
            "Taxes": .brown,
            "ISR Retenido": .brown,
            "Income": .mint,
            "Interest": .mint,
            "Salary": .mint,
            "Subscriptions": .indigo,
            "Software": .indigo,
            "Fees & Charges": .yellow,
            "Interest Charges": .yellow,
        ]
        return map[name] ?? Color(white: 0.3)
    }

    private func colorForIndex(_ index: Int) -> Color {
        let colors: [Color] = [.orange, .blue, .purple, .pink, .yellow, .red, .green, .cyan, .gray, .brown, .mint, .indigo]
        return colors[index % colors.count]
    }
}

private struct SummaryCard: View {
    let title: String
    let amount: Decimal

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(formatMoney(amount))
                .font(.title2.bold())
                .foregroundStyle(amount >= 0 ? .green : .red)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
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
