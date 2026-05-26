import SwiftUI
import Charts

/// Per-account dashboard for credit-card accounts. Shows utilization, payment
/// due info, charges-vs-payments chart, active MSI installment plans, a
/// spending donut, and recent transactions.
struct LiabilityAccountDashboard: View {
    let snapshot: LiabilityAccountSnapshot

    @State private var breakdown: BreakdownRequest? = nil
    @State private var hover: Date? = nil

    var body: some View {
        VStack(spacing: 20) {
            headerRow
            chargesVsPaymentsChart
            if !snapshot.activeInstallmentPlans.isEmpty {
                installmentsCard
            }
            if !snapshot.spendingByCategory.isEmpty {
                spendingDonut
            }
            if !snapshot.sourceStatements.isEmpty {
                sourceStatementsCard
            }
            recentList
        }
        .sheet(item: $breakdown) { req in
            BreakdownSheet(request: req)
        }
    }

    // MARK: - Header (utilization + payment due)

    private var headerRow: some View {
        HStack(spacing: 16) {
            utilizationCard
            paymentDueCard
        }
    }

    private var utilizationCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Utilization").font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline) {
                Text(MoneyFormat.string(code: snapshot.currencyCode,snapshot.amountOwed))
                    .font(.title.bold())
                    .foregroundStyle(.red)
                Spacer()
                if let pct = snapshot.utilizationPercent {
                    Text(String(format: "%.1f%%", pct * 100))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(pct > 0.7 ? .red : (pct > 0.3 ? .orange : .green))
                }
            }
            if let limit = snapshot.creditLimit {
                Text("of \(MoneyFormat.string(code: snapshot.currencyCode,limit)) credit limit")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let pct = snapshot.utilizationPercent {
                ProgressView(value: min(max(pct, 0), 1))
                    .progressViewStyle(.linear)
                    .tint(pct > 0.7 ? .red : (pct > 0.3 ? .orange : .green))
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var paymentDueCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Payment Due").font(.caption).foregroundStyle(.secondary)
            let state = PaymentDueDisplayState.from(
                latestStatement: snapshot.latestStatement,
                daysUntilDue: snapshot.daysUntilDue
            )
            switch state {
            case .noStatement:
                Text("No statement yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .statementNoDueDate:
                Text("Statement imported")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Due date unavailable")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            case .dueDateOnly(let due, let days):
                dueDateContent(due: due, days: days)
                Divider()
                unavailableRow("Minimum")
                unavailableRow("No Interest")
            case .full(let due, let days, let minimum, let noInterest):
                dueDateContent(due: due, days: days)
                Divider()
                amountRow(label: "Minimum", value: minimum)
                amountRow(label: "No Interest", value: noInterest)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func dueDateContent(due: Date, days: Int?) -> some View {
        Group {
            Text(due, format: .dateTime.day().month(.wide).year())
                .font(.title3.bold())
            if let days {
                Text(daysCopy(days))
                    .font(.caption)
                    .foregroundStyle(days <= 7 ? .red : (days <= 14 ? .orange : .secondary))
            }
        }
    }

    private func amountRow(label: String, value: Decimal?) -> some View {
        HStack {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Spacer()
            if let value {
                Text(MoneyFormat.string(code: snapshot.currencyCode, value)).font(.caption.monospacedDigit())
            } else {
                Text("Unavailable").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func unavailableRow(_ label: String) -> some View {
        HStack {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Text("Unavailable").font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func daysCopy(_ days: Int) -> String {
        if days < 0 { return "Overdue by \(-days) day\(days == -1 ? "" : "s")" }
        if days == 0 { return "Due today" }
        return "in \(days) day\(days == 1 ? "" : "s")"
    }

    // MARK: - Charges vs Payments

    private var chargesVsPaymentsChart: some View {
        ChartCard(title: "Charges vs Payments") {
            Chart(snapshot.chargesVsPayments) { entry in
                BarMark(
                    x: .value("Month", entry.month, unit: .month),
                    y: .value("Charges", entry.charges)
                )
                .foregroundStyle(.red)
                BarMark(
                    x: .value("Month", entry.month, unit: .month),
                    y: .value("Payments", entry.payments)
                )
                .foregroundStyle(.green)
            }
            .frame(height: 200)
            .chartBackground { _ in Color.clear }
            .chartXSelection(value: $hover)
            .chartXAxis {
                AxisMarks(values: .stride(by: .month)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month(.abbreviated))
                }
            }
            .chartOverlay { proxy in
                if let h = hover,
                   let entry = snapshot.chargesVsPayments.first(where: { Calendar.current.isDate($0.month, equalTo: h, toGranularity: .month) }),
                   let xPos = proxy.position(forX: entry.month) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.month, format: .dateTime.month(.wide).year()).font(.caption.bold())
                        Text("Charges: \(MoneyFormat.string(code: snapshot.currencyCode,entry.charges))").font(.caption2).foregroundStyle(.red)
                        Text("Payments: \(MoneyFormat.string(code: snapshot.currencyCode,entry.payments))").font(.caption2).foregroundStyle(.green)
                    }
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .position(x: xPos, y: 24)
                }
            }

            HStack {
                Label(MoneyFormat.string(code: snapshot.currencyCode,snapshot.totalCharges), systemImage: "arrow.up.right")
                    .foregroundStyle(.red)
                Spacer()
                Label(MoneyFormat.string(code: snapshot.currencyCode,snapshot.totalPayments), systemImage: "arrow.down.left")
                    .foregroundStyle(.green)
            }
            .font(.caption.monospacedDigit())
        }
    }

    // MARK: - Installments

    private var installmentsCard: some View {
        ChartCard(title: "Active Installment Plans") {
            ForEach(snapshot.activeInstallmentPlans) { plan in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(plan.merchantDescription)
                            .font(.body)
                            .lineLimit(1)
                        Spacer()
                        Text("\(plan.currentMonth) / \(plan.totalMonths)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Monthly: \(MoneyFormat.string(code: snapshot.currencyCode,plan.monthlyAmount))")
                            .font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Text("Original: \(MoneyFormat.string(code: snapshot.currencyCode,plan.originalAmount))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    ProgressView(value: Double(plan.currentMonth) / Double(max(plan.totalMonths, 1)))
                        .progressViewStyle(.linear)
                        .tint(.blue)
                }
                .padding(.vertical, 4)
                if plan.id != snapshot.activeInstallmentPlans.last?.id {
                    Divider()
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

    private var sourceStatementsCard: some View {
        DashboardListCard(title: "Source Statements") {
            ForEach(snapshot.sourceStatements) { src in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(src.displayName)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        Text(src.metadataStatus)
                            .font(.caption2)
                            .foregroundStyle(src.metadataStatus == "Complete" ? .green : .orange)
                    }
                    HStack {
                        Text(src.periodStart, format: .dateTime.month(.abbreviated).day().year())
                            .font(.caption2).foregroundStyle(.secondary)
                        Text("–")
                            .font(.caption2).foregroundStyle(.secondary)
                        Text(src.periodEnd, format: .dateTime.month(.abbreviated).day().year())
                            .font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Text("Imported \(src.importedAt, format: .dateTime.month(.abbreviated).day())")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
                if src.id != snapshot.sourceStatements.last?.id {
                    DashboardSeparator()
                }
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
