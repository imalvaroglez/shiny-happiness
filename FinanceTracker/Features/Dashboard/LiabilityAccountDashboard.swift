import SwiftUI
import Charts

/// Per-account dashboard for debt accounts. Credit cards show utilization and
/// statement metadata; loans use simpler amount-owed language.
struct LiabilityAccountDashboard: View {
    let snapshot: LiabilityAccountSnapshot
    var onTransactionTap: ((Transaction) -> Void)? = nil
    var onViewAllTransactions: (() -> Void)? = nil
    var onEditPaymentDetails: (() -> Void)? = nil

    @State private var breakdown: BreakdownRequest? = nil
    @State private var balanceCopied = false
    @State private var reviewExpanded = false
    @ScaledMetric(relativeTo: .body) private var insightCardHeight: CGFloat = 188

    var body: some View {
        VStack(spacing: 20) {
            if snapshot.account.type == .creditCard {
                creditCardInsightSection
            } else {
                headerRow
            }
            if !snapshot.promotions.isEmpty {
                PromoSummaryLine(promotions: snapshot.promotions, currencyCode: snapshot.currencyCode,
                                 accountName: snapshot.account.displayName, accountID: snapshot.account.id)
            }
            chartsSection
            if snapshot.account.type == .creditCard, !snapshot.activeInstallmentPlans.isEmpty {
                installmentsCard
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

    private func spendRequirementCardContent(_ data: SpendRequirementCardData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Gasto mínimo").font(.caption.weight(.semibold))
                Spacer(minLength: 4)
                if case .available(let progress) = data.calculation {
                    let isReview = progress.isPotentiallyAmbiguous
                    Text(isReview ? "Por revisar" : (progress.targetReached ? "Alcanzado" : "En progreso"))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(isReview ? .orange : (progress.targetReached ? .green : .red))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            switch data.calculation {
            case .available(let progress):
                Text("\(MoneyFormat.string(code: progress.requirement.currency, progress.eligibleSpend)) / \(MoneyFormat.string(code: progress.requirement.currency, progress.requirement.amount))")
                    .font(.callout.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(progress.isPotentiallyAmbiguous ? .orange : (progress.targetReached ? .green : .red))
                    .lineLimit(1).minimumScaleFactor(0.8)
                ProgressView(value: NSDecimalNumber(decimal: min(progress.progress, 1)).doubleValue)
                    .tint(progress.isPotentiallyAmbiguous ? .orange : (progress.targetReached ? .green : .red))
                Text(progress.isPotentiallyAmbiguous ? "Resultado provisional: revisa los abonos" :
                     (progress.targetReached ? "Gasto mínimo alcanzado" : "Faltan \(MoneyFormat.string(code: progress.requirement.currency, progress.remaining))"))
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
                spendCycleColumn(progress)
            case .unavailable(let message):
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func spendCycleColumn(_ progress: SpendRequirementProgress) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text("Ciclo \(shortDate(progress.cycle.start)) – \(shortDate(progress.cycle.closingDate))")
                Spacer(minLength: 2)
                Text(progress.cycle.daysUntilClosing == 0 ? "Cierra hoy" : "\(progress.cycle.daysUntilClosing) días restantes")
            }
            .font(.caption2)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            if progress.cycle.nominalClosingDate != progress.cycle.closingDate {
                Text("Corte nominal: \(cutoffDate(progress.cycle.nominalClosingDate)) · aplicado: \(cutoffDate(progress.cycle.closingDate))")
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "es-MX")))
    }

    private func cutoffDate(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(Locale(identifier: "es-MX")))
    }

    @ViewBuilder
    private var creditCardInsightSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            creditCardInsightCards
            if let data = snapshot.spendRequirementCard,
               case .available(let progress) = data.calculation,
               !data.reviewTransactions.isEmpty || progress.ambiguousCreditTotal > 0 {
                DisclosureGroup(isExpanded: $reviewExpanded) {
                    if progress.isPotentiallyAmbiguous {
                        Text("El resultado puede cambiar al revisar los abonos.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(data.reviewTransactions) { transaction in
                        Button { onTransactionTap?(transaction) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(transaction.descriptionRaw).lineLimit(1)
                                    Text(transaction.postedAt.formattedMX(date: .abbreviated, time: .omitted))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(MoneyFormat.string(code: transaction.currency, transaction.amount))
                                    .monospacedDigit()
                            }
                            .font(.caption)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } label: {
                    HStack {
                        Text("Abonos por revisar (\(data.reviewTransactions.count))")
                        Spacer()
                        if progress.ambiguousCreditTotal > 0 {
                            Text(MoneyFormat.string(code: progress.requirement.currency, progress.ambiguousCreditTotal))
                                .monospacedDigit()
                        }
                    }
                    .foregroundStyle(.orange)
                }
                .font(.caption)
                .padding(.horizontal, 12)
            }
        }
    }

    @ViewBuilder
    private var creditCardInsightCards: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                equalInsightCard { utilizationCardContent }
                    .frame(minWidth: 250, maxWidth: .infinity)
                equalInsightCard { paymentDueCardContent }
                    .frame(minWidth: 250, maxWidth: .infinity)
                if let spendRequirementCard = snapshot.spendRequirementCard {
                    equalInsightCard { spendRequirementCardContent(spendRequirementCard) }
                        .frame(minWidth: 250, maxWidth: .infinity)
                }
            }
            VStack(spacing: 12) {
                cardSurface { utilizationCardContent }
                cardSurface { paymentDueCardContent }
                if let spendRequirementCard = snapshot.spendRequirementCard {
                    cardSurface { spendRequirementCardContent(spendRequirementCard) }
                }
            }
        }
    }

    private func cardSurface<Content: View>(
        minHeight: CGFloat? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding()
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func equalInsightCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding()
            .frame(maxWidth: .infinity, minHeight: insightCardHeight, maxHeight: insightCardHeight,
                   alignment: .topLeading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Header (utilization + payment due)

    private var headerRow: some View {
        HStack(spacing: 16) {
            cardSurface(minHeight: 188) { utilizationCardContent }
            if snapshot.account.type == .creditCard {
                paymentDueCard
            }
        }
    }

    private var utilizationCardContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(snapshot.account.type == .loan ? "Amount Owed" : "Utilization")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline) {
                // Copy what the user sees: the positive amount-owed magnitude.
                Text(MoneyFormat.string(code: snapshot.currencyCode,snapshot.amountOwed))
                    .font(.title.bold())
                    .foregroundStyle(.red)
                    .copyBalanceAffordance(
                        amount: snapshot.amountOwed,
                        displayedAmount: MoneyFormat.string(code: snapshot.currencyCode, snapshot.amountOwed),
                        copied: $balanceCopied
                    )
                Spacer()
                if let pct = snapshot.utilizationPercent {
                    Text(String(format: "%.1f%%", pct * 100))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(pct > 0.7 ? .red : (pct > 0.3 ? .orange : .green))
                }
            }
            if balanceCopied {
                Label("Balance copied", systemImage: "checkmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            } else if snapshot.account.type == .creditCard, let limit = snapshot.creditLimit {
                            Text("de límite de crédito: \(MoneyFormat.string(code: snapshot.currencyCode,limit))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if snapshot.account.type == .creditCard, let pct = snapshot.utilizationPercent {
                ProgressView(value: min(max(pct, 0), 1))
                    .progressViewStyle(.linear)
                    .tint(pct > 0.7 ? .red : (pct > 0.3 ? .orange : .green))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: balanceCopied)
    }

    private var paymentDueCard: some View {
        cardSurface(minHeight: 188) { paymentDueCardContent }
    }

    private var paymentDueCardContent: some View {
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

    @ViewBuilder
    private var chartsSection: some View {
        if snapshot.account.type == .creditCard {
            if snapshot.spendingByCategory.isEmpty {
                selectedChargesChart
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        selectedChargesChart.frame(minWidth: 442)
                        spendingDonut.frame(minWidth: 442)
                    }
                    VStack(spacing: 16) {
                        selectedChargesChart.frame(maxWidth: .infinity)
                        spendingDonut.frame(maxWidth: .infinity)
                    }
                }
            }
        } else {
            chargesVsPaymentsChart
            if !snapshot.spendingByCategory.isEmpty { spendingDonut }
        }
    }

    @ViewBuilder
    private var selectedChargesChart: some View {
        if snapshot.period.kind == .month {
            monthlyChargesChart
        } else {
            chargesVsPaymentsChart
        }
    }

    private var monthlyChargesChart: some View {
        BalancedChartCard(title: "Daily Spending", plot: {
            DashboardGroupedPeriodBarChart(
                groups: monthlyChargesBarGroups,
                firstSeriesName: String(localized: "Charges"),
                secondSeriesName: String(localized: "Payments & Credits"),
                firstColor: DashboardChartSeriesColor.expense,
                secondColor: DashboardChartSeriesColor.income,
                currencyCode: snapshot.currencyCode,
                emptyMessage: String(localized: "No charges in this period."),
                showsSecondSeries: false,
                footerText: { group in
                    guard let entry = chargesPaymentsEntry(for: group.bucketStart) else { return nil }
                    return dashboardBucketLabel(for: entry.month, bucket: .day)
                }
            )
        }, footer: {
            HStack(spacing: 14) {
                amountSummary(String(localized: "Charges"), amount: snapshot.totalCharges, color: DashboardChartSeriesColor.expense)
                Divider().frame(height: 22)
                amountSummary(String(localized: "Payments & Credits"), amount: snapshot.totalPayments, color: DashboardChartSeriesColor.income)
            }
            .font(.caption2.monospacedDigit())
        })
    }

    private func amountSummary(_ title: String, amount: Decimal, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Text(MoneyFormat.string(code: snapshot.currencyCode, amount))
                .foregroundStyle(.primary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }

    private var monthlyChargesBarGroups: [DashboardPeriodBarGroup] {
        DashboardPeriodBarGroupBuilder.groups(
            period: snapshot.period,
            buckets: snapshot.chargesVsPayments
                .map { entry in
                    DashboardPeriodBucketDisplayValue(
                        bucketStart: entry.month,
                        firstMagnitude: entry.charges,
                        secondMagnitude: 0
                    )
                },
            onlyFirstSeries: true
        )
    }

    private var chargesVsPaymentsChart: some View {
        BalancedChartCard(title: "Charges vs Payments", plot: {
            DashboardGroupedPeriodBarChart(
                groups: chargesPaymentsBarGroups,
                firstSeriesName: String(localized: "Charges"),
                secondSeriesName: String(localized: "Payments & Credits"),
                firstColor: DashboardChartSeriesColor.expense,
                secondColor: DashboardChartSeriesColor.income,
                currencyCode: snapshot.currencyCode,
                emptyMessage: String(localized: "No charges or payments for this period."),
                footerText: { group in
                    guard let entry = chargesPaymentsEntry(for: group.bucketStart) else { return nil }
                    return String(localized: "Net debt change: \(MoneyFormat.string(code: snapshot.currencyCode, entry.payments - entry.charges))")
                }
            )
        }, footer: {
            HStack(spacing: 14) {
                amountSummary(String(localized: "Charges"), amount: snapshot.totalCharges, color: DashboardChartSeriesColor.expense)
                Divider().frame(height: 22)
                amountSummary(String(localized: "Payments & Credits"), amount: snapshot.totalPayments, color: DashboardChartSeriesColor.income)
            }
            .font(.caption2.monospacedDigit())
        })
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
                        Text("Mensualidad: \(MoneyFormat.string(code: snapshot.currencyCode,plan.monthlyAmount))")
                            .font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Text("Importe original: \(MoneyFormat.string(code: snapshot.currencyCode,plan.originalAmount))")
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
        let categoryCount = snapshot.spendingByCategory.count
        let total = snapshot.spendingByCategory.reduce(Decimal.zero) { $0 + $1.amount }
        return BalancedChartCard(title: "Spending by Category", plot: {
            SpendingCategoryDonut(
                entries: snapshot.spendingByCategory,
                currencyCode: snapshot.currencyCode,
                showsLegend: false,
                aggregatesOther: true,
                onSelect: { entry in
                breakdown = .categorySpending(category: entry.category, amount: entry.amount, transactions: snapshot.recentTransactions)
                },
                onSelectOther: { showCategoryBreakdown() }
            )
        }, footer: {
            HStack(spacing: 8) {
                Text(String(localized: "Total spending"))
                    .foregroundStyle(.secondary)
                Text(MoneyFormat.string(code: snapshot.currencyCode, total))
                    .font(.caption.monospacedDigit())
                Spacer(minLength: 4)
                Text(String(localized: "\(categoryCount) categories"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button("View breakdown") { showCategoryBreakdown() }
                    .buttonStyle(.borderless)
                    .fixedSize()
            }
            .font(.caption)
        })
    }

    private func showCategoryBreakdown() {
        breakdown = .categoryList(
            entries: snapshot.spendingByCategory,
            currencyCode: snapshot.currencyCode,
            transactions: snapshot.recentTransactions
        )
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
                        Text("Importado el \(src.importedAt, format: .dateTime.day().month(.abbreviated).locale(Locale(identifier: "es-MX")))")
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
            let rows = Array(snapshot.recentTransactions.prefix(10))
            if rows.isEmpty {
                Text("No transactions for this period")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            ForEach(rows) { tx in
                Button {
                    onTransactionTap?(tx)
                } label: {
                    DashboardTransactionRow(transaction: tx, showsAccount: false)
                }
                .buttonStyle(.plain)
                if tx.id != rows.last?.id {
                    DashboardSeparator()
                }
            }
            if let onViewAllTransactions {
                Button("View more transactions", systemImage: "arrow.right", action: onViewAllTransactions)
                    .buttonStyle(.borderless)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(10)
            }
        }
    }
}

private enum LiabilityDashboardPreviewData {
    static func snapshot(
        chargeDays: [Int],
        payments: Decimal,
        includeCategories: Bool = true,
        periodKind: DashboardPeriodKind = .month,
        spendRequirementCard: SpendRequirementCardData? = nil
    ) -> LiabilityAccountSnapshot {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 24
        components.timeZone = TimeZone(identifier: "America/Mexico_City")
        let now = Calendar(identifier: .gregorian).date(from: components)!
        let range = periodKind.resolvedRange(now: now)
        let period = DashboardPeriodResolver.context(kind: periodKind, requestedRange: range, dataRange: nil, now: now)
        func date(month: Int, day: Int) -> Date {
            var dateComponents = DateComponents()
            dateComponents.year = 2026
            dateComponents.month = month
            dateComponents.day = day
            dateComponents.timeZone = TimeZone(identifier: "America/Mexico_City")
            return Calendar(identifier: .gregorian).date(from: dateComponents)!
        }
        let charges: [MonthlyChargesPayments]
        if periodKind == .month {
            charges = chargeDays.map { day in
                MonthlyChargesPayments(
                    month: date(month: 9, day: day),
                    charges: Decimal(day == 14 ? 15_000 : 11_000),
                    payments: 0
                )
            } + [MonthlyChargesPayments(month: now, charges: 0, payments: payments)]
        } else {
            charges = [
                MonthlyChargesPayments(month: date(month: 4, day: 1), charges: 7_000, payments: 0),
                MonthlyChargesPayments(month: date(month: 6, day: 1), charges: 9_000, payments: 0),
                MonthlyChargesPayments(month: date(month: 8, day: 1), charges: 11_000, payments: 0),
                MonthlyChargesPayments(month: date(month: 9, day: 1), charges: 10_000, payments: payments)
            ]
        }
        let totalCharges = charges.reduce(Decimal.zero) { $0 + $1.charges }
        let categories = [
            ("Events", 30), ("Doctor", 14), ("Restaurants", 14), ("Travel", 14),
            ("Electronics", 8), ("Shopping", 7), ("Uncategorized", 5), ("Phone", 3),
            ("Groceries", 3), ("Transport", 2)
        ]

        return LiabilityAccountSnapshot(
            period: period,
            account: DashboardAccountIdentity(
                id: UUID(), displayName: "Tarjeta de crédito", institution: "Banco", type: .creditCard,
                currency: "MXN", tintHex: nil, creditLimit: 100_000
            ),
            currentBalance: -8_500,
            creditLimit: 100_000,
            utilizationPercent: 0.085,
            paymentStatement: nil,
            chargesVsPayments: charges,
            spendingByCategory: includeCategories && totalCharges > 0 ? categories.map { name, weight in
                CategorySpending(category: Category(name: name), amount: totalCharges * Decimal(weight) / 100)
            } : [],
            totalCharges: totalCharges,
            totalPayments: payments,
            interestCharged: 0,
            feesCharged: 0,
            activeInstallmentPlans: [],
            sourceStatements: [],
            recentTransactions: [],
            totalTransactions: 0,
            spendRequirementCard: spendRequirementCard
        )
    }

    static func spendCard(
        spend: Decimal,
        ambiguous: Decimal = 0,
        days: Int = 15,
        includeReviewTransaction: Bool = false
    ) -> SpendRequirementCardData {
        let requirement = SpendRequirement(accountID: UUID(), name: "Gasto mínimo", amount: 3_500,
                                            currency: "MXN", statementClosingDay: 11,
                                            adjustToPreviousBusinessDay: true)
        let cycle = SpendRequirementCycle(start: date(2026, 9, 12), closingDate: date(2026, 10, 9),
                                          nominalClosingDate: date(2026, 10, 11),
                                          daysUntilClosing: days)
        let progress = SpendRequirementProgress(requirement: requirement, cycle: cycle,
                                                eligibleSpend: spend, ambiguousCreditTotal: ambiguous,
                                                reviewMovementIDs: [])
        return SpendRequirementCardData(requirement: requirement, calculation: .available(progress),
                                        reviewTransactions: includeReviewTransaction ? [
                                            Transaction(postedAt: date(2026, 9, 22), amount: ambiguous,
                                                        descriptionRaw: "Abono por identificar", source: .manual)
                                        ] : [])
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = MexicoBankingCalendar.timeZone
        return calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }
}

#Preview("Tarjeta mensual · ventana amplia") {
    LiabilityAccountDashboard(snapshot: LiabilityDashboardPreviewData.snapshot(chargeDays: [2, 14, 21], payments: 3_200))
        .frame(width: 1_100)
}

#Preview("Tarjeta completa · ventana amplia") {
    LiabilityAccountDashboard(snapshot: LiabilityDashboardPreviewData.snapshot(
        chargeDays: [2, 14, 21], payments: 3_200, periodKind: .all
    ))
    .frame(width: 1_100)
}

#Preview("Tarjeta mensual · tema oscuro") {
    LiabilityAccountDashboard(snapshot: LiabilityDashboardPreviewData.snapshot(chargeDays: [2, 14, 21], payments: 3_200))
        .frame(width: 1_100)
        .preferredColorScheme(.dark)
}

#Preview("Tarjeta mensual · ventana estrecha") {
    LiabilityAccountDashboard(snapshot: LiabilityDashboardPreviewData.snapshot(chargeDays: [2, 21], payments: 3_200))
        .frame(width: 760)
}

#Preview("Tarjeta mensual · un día con cargos") {
    LiabilityAccountDashboard(snapshot: LiabilityDashboardPreviewData.snapshot(chargeDays: [21], payments: 0))
        .frame(width: 1_000)
}

#Preview("Tarjeta mensual · sin cargos") {
    LiabilityAccountDashboard(snapshot: LiabilityDashboardPreviewData.snapshot(chargeDays: [], payments: 5_000))
        .frame(width: 1_000)
}

#Preview("Gasto mínimo · en progreso") {
    LiabilityAccountDashboard(snapshot: LiabilityDashboardPreviewData.snapshot(chargeDays: [2, 14], payments: 0,
        spendRequirementCard: LiabilityDashboardPreviewData.spendCard(spend: 2_250)))
        .frame(width: 1_000)
}

#Preview("Gasto mínimo · alcanzado") {
    LiabilityAccountDashboard(snapshot: LiabilityDashboardPreviewData.snapshot(chargeDays: [2, 14], payments: 0,
        spendRequirementCard: LiabilityDashboardPreviewData.spendCard(spend: 3_500)))
        .frame(width: 1_000)
}

#Preview("Gasto mínimo · por revisar") {
    LiabilityAccountDashboard(snapshot: LiabilityDashboardPreviewData.snapshot(chargeDays: [2, 14], payments: 0,
        spendRequirementCard: LiabilityDashboardPreviewData.spendCard(
            spend: 3_500, ambiguous: 250, includeReviewTransaction: true)))
        .frame(width: 1_000)
}

#Preview("Gasto mínimo · texto ampliado") {
    LiabilityAccountDashboard(snapshot: LiabilityDashboardPreviewData.snapshot(chargeDays: [2, 14], payments: 0,
        spendRequirementCard: LiabilityDashboardPreviewData.spendCard(spend: 2_250)))
        .frame(width: 1_000)
        .environment(\.dynamicTypeSize, .xxxLarge)
}

#Preview("Gasto mínimo · datos no disponibles") {
    let card = SpendRequirementCardData(requirement: nil,
        calculation: .unavailable("No se pudo leer el historial."), reviewTransactions: [])
    LiabilityAccountDashboard(snapshot: LiabilityDashboardPreviewData.snapshot(chargeDays: [], payments: 0,
                                                                                spendRequirementCard: card))
        .frame(width: 760)
}
