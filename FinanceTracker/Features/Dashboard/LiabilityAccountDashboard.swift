import SwiftUI
import Charts

/// Per-account dashboard for credit-card accounts. Shows utilization, payment
/// due info, charges-vs-payments chart, active MSI installment plans, and a
/// recent-transactions list. Spending donut + interest/fees card appear when
/// relevant.
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
            if snapshot.interestCharged > 0 || snapshot.feesCharged > 0 {
                interestFeesCard
            }
            if !snapshot.spendingByCategory.isEmpty {
                spendingDonut
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
                Text(MoneyFormat.string(snapshot.amountOwed))
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
                Text("of \(MoneyFormat.string(limit)) credit limit")
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
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }

    private var paymentDueCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Payment Due").font(.caption).foregroundStyle(.secondary)
            if let stmt = snapshot.latestStatement,
               let due = stmt.paymentDueDate {
                Text(due, format: .dateTime.day().month(.wide).year())
                    .font(.title3.bold())
                if let days = snapshot.daysUntilDue {
                    Text(daysCopy(days))
                        .font(.caption)
                        .foregroundStyle(days <= 7 ? .red : (days <= 14 ? .orange : .secondary))
                }
                Divider()
                if let min = stmt.minimumPayment {
                    HStack {
                        Text("Minimum").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Text(MoneyFormat.string(min)).font(.caption.monospacedDigit())
                    }
                }
                if let no = stmt.paymentForNoInterest {
                    HStack {
                        Text("No Interest").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Text(MoneyFormat.string(no)).font(.caption.monospacedDigit())
                    }
                }
            } else {
                Text("No statement yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
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
                        Text("Charges: \(MoneyFormat.string(entry.charges))").font(.caption2).foregroundStyle(.red)
                        Text("Payments: \(MoneyFormat.string(entry.payments))").font(.caption2).foregroundStyle(.green)
                    }
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .position(x: xPos, y: 24)
                }
            }

            HStack {
                Label(MoneyFormat.string(snapshot.totalCharges), systemImage: "arrow.up.right")
                    .foregroundStyle(.red)
                Spacer()
                Label(MoneyFormat.string(snapshot.totalPayments), systemImage: "arrow.down.left")
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
                        Text("Monthly: \(MoneyFormat.string(plan.monthlyAmount))")
                            .font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Text("Original: \(MoneyFormat.string(plan.originalAmount))")
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

    // MARK: - Interest / fees

    private var interestFeesCard: some View {
        ChartCard(title: "Interest & Fees") {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Interest").font(.caption).foregroundStyle(.secondary)
                    Text(MoneyFormat.string(snapshot.interestCharged))
                        .font(.title3.bold())
                        .foregroundStyle(snapshot.interestCharged > 0 ? .red : .secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Fees").font(.caption).foregroundStyle(.secondary)
                    Text(MoneyFormat.string(snapshot.feesCharged))
                        .font(.title3.bold())
                        .foregroundStyle(snapshot.feesCharged > 0 ? .red : .secondary)
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
                            Text(MoneyFormat.string(entry.amount)).font(.caption2)
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
                        Text(MoneyFormat.string(entry.amount)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var recentList: some View {
        ChartCard(title: "Recent Transactions") {
            ForEach(snapshot.recentTransactions.prefix(10)) { tx in
                DashboardTransactionRow(transaction: tx)
                if tx.id != snapshot.recentTransactions.prefix(10).last?.id {
                    Divider()
                }
            }
        }
    }
}
