import SwiftUI
import Charts

/// Per-account dashboard for debt accounts. Credit cards show utilization and
/// statement metadata; loans use simpler amount-owed language.
struct LiabilityAccountDashboard: View {
    let snapshot: LiabilityAccountSnapshot
    var onTransactionTap: ((Transaction) -> Void)? = nil
    var onEditPaymentDetails: (() -> Void)? = nil

    @State private var breakdown: BreakdownRequest? = nil

    var body: some View {
        VStack(spacing: 20) {
            headerRow
            chargesVsPaymentsChart
            if snapshot.account.type == .creditCard, !snapshot.activeInstallmentPlans.isEmpty {
                installmentsCard
            }
            if !snapshot.spendingByCategory.isEmpty {
                spendingDonut
            }
            if snapshot.account.type == .creditCard, !snapshot.sourceStatements.isEmpty {
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
            if snapshot.account.type == .creditCard {
                paymentDueCard
            }
        }
    }

    private var utilizationCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(snapshot.account.type == .loan ? "Amount Owed" : "Utilization")
                .font(.caption)
                .foregroundStyle(.secondary)
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
            if snapshot.account.type == .creditCard, let limit = snapshot.creditLimit {
                Text("of \(MoneyFormat.string(code: snapshot.currencyCode,limit)) credit limit")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if snapshot.account.type == .creditCard, let pct = snapshot.utilizationPercent {
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
            HStack {
                Text("Payment Due").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    onEditPaymentDetails?()
                } label: {
                    Text("Edit")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            let state = PaymentDueDisplayState.from(
                paymentStatement: snapshot.paymentStatement,
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
                unavailableRow("Amount to pay")
            case .full(let due, let days, let minimum, let noInterest):
                dueDateContent(due: due, days: days)
                Divider()
                amountRow(label: "Minimum", value: minimum)
                amountRow(label: "Amount to pay", value: noInterest)
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
            DashboardGroupedPeriodBarChart(
                groups: chargesPaymentsBarGroups,
                firstSeriesName: "Charges",
                secondSeriesName: "Payments & Credits",
                firstColor: DashboardChartSeriesColor.expense,
                secondColor: DashboardChartSeriesColor.income,
                currencyCode: snapshot.currencyCode,
                emptyMessage: "No charges or payments for this period.",
                footerText: { group in
                    guard let entry = chargesPaymentsEntry(for: group.bucketStart) else { return nil }
                    return "Net Debt Change: \(MoneyFormat.string(code: snapshot.currencyCode, entry.payments - entry.charges))"
                }
            )

            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(DashboardChartSeriesColor.expense).frame(width: 10, height: 10)
                    Text("Charges").font(.caption2).foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(DashboardChartSeriesColor.income).frame(width: 10, height: 10)
                    Text("Payments & Credits").font(.caption2).foregroundStyle(.secondary)
                }
            }

            HStack {
                Label(MoneyFormat.string(code: snapshot.currencyCode,snapshot.totalCharges), systemImage: "arrow.up.right")
                    .foregroundStyle(DashboardChartSeriesColor.expense)
                Spacer()
                Label(MoneyFormat.string(code: snapshot.currencyCode,snapshot.totalPayments), systemImage: "arrow.down.left")
                    .foregroundStyle(DashboardChartSeriesColor.income)
            }
            .font(.caption.monospacedDigit())
        }
    }

    private var chargesPaymentsBarGroups: [DashboardPeriodBarGroup] {
        DashboardPeriodBarGroupBuilder.groups(
            period: snapshot.period,
            buckets: snapshot.chargesVsPayments.map { entry in
                DashboardPeriodBucketDisplayValue(
                    bucketStart: entry.month,
                    firstMagnitude: entry.charges,
                    secondMagnitude: entry.payments
                )
            }
        )
    }

    private func chargesPaymentsEntry(for selection: Date) -> MonthlyChargesPayments? {
        guard selection >= snapshot.period.dateRange.start && selection <= snapshot.period.dateRange.end else { return nil }
        let bucketStart = snapshot.period.bucketStart(forSelection: selection)
        return snapshot.chargesVsPayments.first { $0.month == bucketStart }
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
        return ChartCard(title: "Spending by Category") {
            SpendingCategoryDonut(
                entries: top,
                currencyCode: snapshot.currencyCode
            ) { entry in
                breakdown = .categorySpending(category: entry.category, amount: entry.amount, transactions: snapshot.recentTransactions)
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
