import SwiftUI
import Charts

enum NetWorthCompositionBucket: String, CaseIterable, Identifiable {
    case liquidity = "Liquidity"
    case patrimonial = "Patrimonial"
    case retirement = "Retirement"

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .liquidity:
            Color(light: Color(hex: "00796B") ?? .teal, dark: Color(hex: "4DB6AC") ?? .teal)
        case .patrimonial:
            Color(light: Color(hex: "B26A00") ?? .orange, dark: Color(hex: "FFB74D") ?? .orange)
        case .retirement:
            Color(light: Color(hex: "5E5BB7") ?? .indigo, dark: Color(hex: "B5B2FF") ?? .indigo)
        }
    }
}

enum NetWorthCompositionAccountBucket {
    case liability
    case liquidity
    case patrimonial
    case retirement
    case uncategorized
}

enum NetWorthCompositionMode: String, CaseIterable, Identifiable {
    case total = "Total"
    case available = "Available"

    var id: String { rawValue }

    var buckets: [NetWorthCompositionBucket] {
        switch self {
        case .total:
            [.liquidity, .patrimonial, .retirement]
        case .available:
            [.liquidity, .patrimonial]
        }
    }

    var footerTitle: String {
        switch self {
        case .total: "Total net worth"
        case .available: "Available net worth"
        }
    }

    var helperText: String? {
        switch self {
        case .total: "Liabilities reduce liquidity."
        case .available: "Excludes retirement assets."
        }
    }
}

struct NetWorthCompositionSlice: Identifiable, Hashable {
    let bucket: NetWorthCompositionBucket
    let amount: Decimal

    var id: NetWorthCompositionBucket { bucket }
}

struct NetWorthCompositionDisplay {
    let mode: NetWorthCompositionMode
    let total: Decimal
    let buckets: [NetWorthCompositionBucket]
    let chartSlices: [NetWorthCompositionSlice]
    let amounts: [NetWorthCompositionBucket: Decimal]

    var footerTitle: String { mode.footerTitle }
    var helperText: String? { mode.helperText }

    func amount(for bucket: NetWorthCompositionBucket) -> Decimal {
        amounts[bucket] ?? 0
    }

    func percentage(for bucket: NetWorthCompositionBucket) -> Double? {
        percentage(of: amount(for: bucket))
    }

    func percentage(of amount: Decimal) -> Double? {
        let positiveTotal = chartSlices.reduce(Decimal.zero) { $0 + $1.amount }
        guard total > 0, amount > 0, positiveTotal > 0 else { return nil }
        return ((amount / positiveTotal) as NSDecimalNumber).doubleValue * 100
    }
}

struct NetWorthComposition {
    let grossLiquidity: Decimal
    let totalLiabilities: Decimal
    let netLiquidity: Decimal
    let patrimonial: Decimal
    let retirement: Decimal
    let uncategorized: Decimal
    let totalNetWorth: Decimal
    let liquidAssetAccounts: [AccountSummary]
    let liabilityAccounts: [AccountSummary]
    let patrimonialAccounts: [AccountSummary]
    let retirementAccounts: [AccountSummary]
    let uncategorizedAccounts: [AccountSummary]

    var liabilitiesExceedLiquidAssets: Bool { netLiquidity < 0 }
    var hasUncategorized: Bool { !uncategorizedAccounts.isEmpty }
    var classifiedNetWorth: Decimal { netLiquidity + patrimonial + retirement }
    var availableNetWorth: Decimal { netLiquidity + patrimonial }

    var chartSlices: [NetWorthCompositionSlice] {
        display(mode: .total).chartSlices
    }

    func amount(for bucket: NetWorthCompositionBucket) -> Decimal {
        switch bucket {
        case .liquidity: netLiquidity
        case .patrimonial: patrimonial
        case .retirement: retirement
        }
    }

    func percentage(of amount: Decimal) -> Double? {
        display(mode: .total).percentage(of: amount)
    }

    func display(mode: NetWorthCompositionMode) -> NetWorthCompositionDisplay {
        let buckets = mode.buckets
        let total = mode == .total ? classifiedNetWorth : availableNetWorth
        let amounts = Dictionary(uniqueKeysWithValues: buckets.map { ($0, amount(for: $0)) })
        let chartSlices = total > 0
            ? buckets
                .map { NetWorthCompositionSlice(bucket: $0, amount: amount(for: $0)) }
                .filter { $0.amount > 0 }
            : []
        return NetWorthCompositionDisplay(
            mode: mode,
            total: total,
            buckets: buckets,
            chartSlices: chartSlices,
            amounts: amounts
        )
    }

    static func calculate(from summaries: [AccountSummary]) -> NetWorthComposition {
        var grossLiquidity = Decimal.zero
        var totalLiabilities = Decimal.zero
        var patrimonial = Decimal.zero
        var retirement = Decimal.zero
        var uncategorized = Decimal.zero
        var liquidAssetAccounts: [AccountSummary] = []
        var liabilityAccounts: [AccountSummary] = []
        var patrimonialAccounts: [AccountSummary] = []
        var retirementAccounts: [AccountSummary] = []
        var uncategorizedAccounts: [AccountSummary] = []

        for summary in summaries {
            switch bucket(for: summary) {
            case .liability:
                totalLiabilities += abs(summary.latestBalance)
                liabilityAccounts.append(summary)
            case .liquidity:
                grossLiquidity += summary.latestBalance
                liquidAssetAccounts.append(summary)
            case .patrimonial:
                patrimonial += summary.latestBalance
                patrimonialAccounts.append(summary)
            case .retirement:
                retirement += summary.latestBalance
                retirementAccounts.append(summary)
            case .uncategorized:
                uncategorized += summary.latestBalance
                uncategorizedAccounts.append(summary)
            case nil:
                continue
            }
        }

        let netLiquidity = grossLiquidity - totalLiabilities
        return NetWorthComposition(
            grossLiquidity: grossLiquidity,
            totalLiabilities: totalLiabilities,
            netLiquidity: netLiquidity,
            patrimonial: patrimonial,
            retirement: retirement,
            uncategorized: uncategorized,
            totalNetWorth: netLiquidity + patrimonial + retirement + uncategorized,
            liquidAssetAccounts: liquidAssetAccounts,
            liabilityAccounts: liabilityAccounts,
            patrimonialAccounts: patrimonialAccounts,
            retirementAccounts: retirementAccounts,
            uncategorizedAccounts: uncategorizedAccounts
        )
    }

    static func bucket(for summary: AccountSummary) -> NetWorthCompositionAccountBucket? {
        guard summary.balanceSourceKind != .insufficientHistory else { return nil }
        if summary.isLiability { return .liability }
        if summary.type == .retirement { return .retirement }
        if summary.type == .other { return .uncategorized }
        if summary.liquidity == .liquid { return .liquidity }
        if summary.type == .investment { return .patrimonial }
        return .uncategorized
    }

}

struct NetWorthCompositionCard: View {
    let composition: NetWorthComposition
    let currencyCode: String
    var compact: Bool = false

    @State private var selectedMode: NetWorthCompositionMode
    @State private var selectedAngle: Decimal? = nil
    @State private var hoveredBucket: NetWorthCompositionBucket? = nil

    init(
        composition: NetWorthComposition,
        currencyCode: String,
        compact: Bool = false,
        defaultMode: NetWorthCompositionMode = .total
    ) {
        self.composition = composition
        self.currencyCode = currencyCode
        self.compact = compact
        _selectedMode = State(initialValue: defaultMode)
    }

    private var display: NetWorthCompositionDisplay { composition.display(mode: selectedMode) }
    private var chartSlices: [NetWorthCompositionSlice] { display.chartSlices }
    private var activeBucket: NetWorthCompositionBucket? {
        guard let bucket = hoveredBucket ?? slice(for: selectedAngle)?.bucket,
              display.buckets.contains(bucket) else { return nil }
        return bucket
    }
    private var chartHeight: CGFloat { compact ? 170 : 220 }
    private var hasLiquidInvestmentsInLiquidity: Bool {
        composition.patrimonial == 0 && composition.liquidAssetAccounts.contains { $0.type == .investment }
    }

    var body: some View {
        ChartCard(title: "Net Worth Composition") {
            VStack(alignment: .leading, spacing: compact ? 8 : 12) {
                HStack {
                    if !compact {
                        Text("Based on current account balances")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    modePicker
                }

                if let helperText = display.helperText {
                    Label(helperText, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                chart

                rows

                if composition.liabilitiesExceedLiquidAssets {
                    Label("Liabilities exceed liquid assets.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if hasLiquidInvestmentsInLiquidity {
                    Label("Liquid investments are included in Liquidity.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(accessibilitySummary)
            .onChange(of: selectedMode) { _, _ in
                hoveredBucket = nil
                selectedAngle = nil
            }
        }
    }

    private var modePicker: some View {
        Picker("Composition view", selection: $selectedMode) {
            ForEach(NetWorthCompositionMode.allCases) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.small)
        .frame(maxWidth: compact ? 190 : 220)
    }

    @ViewBuilder
    private var chart: some View {
        if display.total <= 0 {
            DashboardChartEmptyState(message: "\(display.footerTitle) must be positive to chart composition.")
                .frame(height: chartHeight)
        } else if chartSlices.isEmpty {
            DashboardChartEmptyState(message: "No positive composition buckets to chart.")
                .frame(height: chartHeight)
        } else {
            ZStack {
                Chart(chartSlices) { slice in
                    let isActive = activeBucket == slice.bucket
                    let hasActiveSlice = activeBucket.map { bucket in
                        chartSlices.contains { $0.bucket == bucket }
                    } ?? false

                    SectorMark(
                        angle: .value("Amount", slice.amount),
                        innerRadius: .ratio(0.58),
                        outerRadius: .ratio(isActive ? 1.0 : (hasActiveSlice ? 0.92 : 0.97)),
                        angularInset: 1.6
                    )
                    .foregroundStyle(slice.bucket.color)
                    .opacity(hasActiveSlice && !isActive ? 0.28 : 1)
                }
                .frame(height: chartHeight)
                .chartAngleSelection(value: $selectedAngle)
                .chartBackground { _ in Color.clear }
                .contentShape(Rectangle())
                .onHover { hovering in
                    if !hovering {
                        selectedAngle = nil
                    }
                }

                centerLabel
            }
            .accessibilityLabel("Net worth composition")
            .animation(.easeInOut(duration: 0.16), value: activeBucket)
        }
    }

    private var centerLabel: some View {
        let amount = activeBucket.map { display.amount(for: $0) } ?? display.total
        return VStack(spacing: 3) {
            Text(activeBucket?.rawValue ?? selectedMode.rawValue)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Text(MoneyFormat.string(code: currencyCode, amount))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if let activeBucket {
                Text(percentText(display.percentage(for: activeBucket)))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 120)
        .allowsHitTesting(false)
    }

    private var rows: some View {
        VStack(spacing: compact ? 4 : 6) {
            ForEach(display.buckets) { bucket in
                bucketRow(bucket, amount: display.amount(for: bucket))
            }

            Divider().padding(.vertical, compact ? 1 : 2)

            if compact {
                detailRow(display.footerTitle, amount: display.total, bold: true)
            } else {
                detailRow("Gross liquidity", amount: composition.grossLiquidity)
                detailRow("Liabilities", amount: composition.totalLiabilities)
                detailRow("Net liquidity", amount: composition.netLiquidity)
                detailRow(display.footerTitle, amount: display.total, bold: true)
            }

            if composition.hasUncategorized {
                warningRow(
                    "Uncategorized",
                    amount: composition.uncategorized,
                    detail: "\(composition.uncategorizedAccounts.count) account\(composition.uncategorizedAccounts.count == 1 ? "" : "s") need review"
                )
            }
        }
    }

    private func bucketRow(_ bucket: NetWorthCompositionBucket, amount: Decimal) -> some View {
        let isActive = activeBucket == bucket
        let hasActive = activeBucket != nil
        return HStack(spacing: 8) {
            Circle()
                .fill(bucket.color)
                .frame(width: 8, height: 8)
            Text(bucket.rawValue)
                .font(.caption.weight(.medium))
            Text(percentText(display.percentage(for: bucket)))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            amountText(amount)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, compact ? 3 : 2)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isActive ? bucket.color.opacity(0.14) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(isActive ? bucket.color.opacity(0.45) : Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .opacity(hasActive && !isActive ? 0.55 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { hovering in
            hoveredBucket = hovering ? bucket : nil
        }
        .help("\(bucket.rawValue): \(MoneyFormat.string(code: currencyCode, amount)), \(percentText(display.percentage(for: bucket)))")
    }

    private func detailRow(_ title: String, amount: Decimal, bold: Bool = false) -> some View {
        HStack {
            Text(title)
                .font(.caption.weight(bold ? .semibold : .regular))
            Spacer()
            amountText(amount, bold: bold)
        }
        .padding(.vertical, 1)
    }

    private func warningRow(_ title: String, amount: Decimal, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Label(title, systemImage: "exclamationmark.triangle")
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            amountText(amount)
        }
        .padding(.vertical, 2)
    }

    private func amountText(_ amount: Decimal, bold: Bool = false) -> some View {
        Text(MoneyFormat.string(code: currencyCode, amount))
            .font((bold ? Font.caption.weight(.semibold) : Font.caption).monospacedDigit())
            .foregroundStyle(amount < 0 ? .red : .secondary)
    }

    private func percentText(_ percentage: Double?) -> String {
        guard let percentage else { return "-" }
        return String(format: "%.1f%%", percentage)
    }

    private var accessibilitySummary: String {
        var parts = [
            "Net worth composition, \(selectedMode.rawValue) view.",
            "\(display.footerTitle) \(MoneyFormat.string(code: currencyCode, display.total)).",
            "Gross liquidity \(MoneyFormat.string(code: currencyCode, composition.grossLiquidity)).",
            "Liabilities \(MoneyFormat.string(code: currencyCode, composition.totalLiabilities))."
        ]
        parts.append(contentsOf: display.buckets.map { bucket in
            "\(bucket.rawValue) \(MoneyFormat.string(code: currencyCode, display.amount(for: bucket)))."
        })
        return parts.joined(separator: " ")
    }

    private func slice(for selectedAngle: Decimal?) -> NetWorthCompositionSlice? {
        guard let selectedAngle, !chartSlices.isEmpty else { return nil }

        var lowerBound = Decimal.zero
        for slice in chartSlices {
            let upperBound = lowerBound + slice.amount
            if selectedAngle >= lowerBound && selectedAngle <= upperBound {
                return slice
            }
            lowerBound = upperBound
        }
        return chartSlices.last
    }
}
