import SwiftUI
import Foundation
import Charts

// Shared chrome used by all three dashboard variants. Money formatting,
// summary tiles, transaction rows, and the category color palette live
// here so the three dashboards don't drift from each other.

enum DashboardChartSeriesColor {
    static let income = Color(red: 0.10, green: 0.70, blue: 0.34)
    static let expense = Color(red: 0.94, green: 0.20, blue: 0.23)
}

enum MoneyFormat {
    /// Render a Decimal in the given currency code. Always emits monospaced
    /// digits via the formatter; callers should still apply `.monospacedDigit()`
    /// at the Text level for alignment across rows when the digit width matters.
    private static let _formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        return f
    }()

    static func string(_ amount: Decimal, code: String = "MXN") -> String {
        _formatter.currencyCode = code
        return _formatter.string(from: amount as NSDecimalNumber) ?? "$0.00"
    }

    /// Labeled form used by view code that has the currency code on a snapshot
    /// or account: `MoneyFormat.string(code: snap.currencyCode, amount)`.
    static func string(code: String, _ amount: Decimal) -> String {
        string(amount, code: code)
    }
}

extension Text {
    /// Apply monospaced digits universally. Use on any Text rendering a number
    /// or currency to keep columns aligned and to match the visual treatment
    /// across the app.
    func money() -> Text { self.monospacedDigit() }
}

func dashboardTooltipX(_ x: CGFloat, in geo: GeometryProxy, width: CGFloat = 210) -> CGFloat {
    let halfWidth = width / 2
    let margin: CGFloat = 12
    let lowerBound = halfWidth + margin
    let upperBound = max(lowerBound, geo.size.width - halfWidth - margin)
    return min(max(x, lowerBound), upperBound)
}

func dashboardCompactAmount(_ value: Double, code: String) -> String {
    let symbol = code == "MXN" || code == "USD" ? "$" : "\(code) "
    let absolute = abs(value)
    if absolute >= 1_000_000 {
        return "\(symbol)\(String(format: "%.1fM", value / 1_000_000))"
    }
    if absolute >= 1_000 {
        return "\(symbol)\(String(format: "%.0fK", value / 1_000))"
    }
    return "\(symbol)\(String(format: "%.0f", value))"
}

func dashboardAxisLabel(for date: Date, bucket: DashboardBucket) -> String {
    switch bucket {
    case .day:
        return date.formatted(.dateTime.day().month(.abbreviated))
    case .week:
        let week = Calendar(identifier: .gregorian).component(.weekOfYear, from: date)
        return "W\(week)"
    case .month:
        return date.formatted(.dateTime.month(.abbreviated))
    case .year:
        return date.formatted(.dateTime.year())
    }
}

func dashboardBucketLabel(for date: Date, bucket: DashboardBucket) -> String {
    switch bucket {
    case .day:
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.wide).year())
    case .week:
        return "Week of \(date.formatted(.dateTime.day().month(.wide).year()))"
    case .month:
        return date.formatted(.dateTime.month(.wide).year())
    case .year:
        return date.formatted(.dateTime.year())
    }
}

struct DashboardChartHoverOverlay: View {
    let proxy: ChartProxy
    let geometry: GeometryProxy
    let period: DashboardPeriodContext
    @Binding var hoverBucketStart: Date?

    var body: some View {
        Rectangle()
            .fill(.clear)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    updateHover(at: location)
                case .ended:
                    if hoverBucketStart != nil {
                        hoverBucketStart = nil
                    }
                }
            }
    }

    private func updateHover(at location: CGPoint) {
        guard let plotFrame = proxy.plotFrame else {
            if hoverBucketStart != nil { hoverBucketStart = nil }
            return
        }

        let plotRect = geometry[plotFrame]
        guard plotRect.contains(location) else {
            if hoverBucketStart != nil { hoverBucketStart = nil }
            return
        }

        let x = location.x - plotRect.origin.x
        guard let date = proxy.value(atX: x, as: Date.self) else {
            if hoverBucketStart != nil { hoverBucketStart = nil }
            return
        }

        let bucketStart = period.bucketStart(forSelection: date)
        guard period.interval(forBucketStart: bucketStart) != nil else {
            if hoverBucketStart != nil { hoverBucketStart = nil }
            return
        }

        if hoverBucketStart != bucketStart {
            hoverBucketStart = bucketStart
        }
    }
}

struct DashboardChartEmptyState: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 160)
    }
}

struct DashboardBalanceChartDomain: Equatable {
    let lowerBound: Double
    let upperBound: Double

    var range: ClosedRange<Double> { lowerBound...upperBound }
}

enum DashboardBalanceChartScale {
    static func domain(for points: [NetWorthPoint]) -> DashboardBalanceChartDomain {
        let values = points.map { $0.balance.dashboardDoubleValue }.filter(\.isFinite)
        guard let minValue = values.min(), let maxValue = values.max() else {
            return DashboardBalanceChartDomain(lowerBound: 0, upperBound: 1)
        }

        if minValue == maxValue {
            if maxValue > 0 {
                return DashboardBalanceChartDomain(lowerBound: 0, upperBound: niceCeil(maxValue * 1.12))
            }
            if minValue < 0 {
                return DashboardBalanceChartDomain(lowerBound: niceFloor(minValue * 1.12), upperBound: 0)
            }
            return DashboardBalanceChartDomain(lowerBound: 0, upperBound: 1)
        }

        let span = maxValue - minValue
        if minValue >= 0 {
            return DashboardBalanceChartDomain(lowerBound: 0, upperBound: niceCeil(maxValue + span * 0.12))
        }

        return DashboardBalanceChartDomain(
            lowerBound: niceFloor(minValue - span * 0.12),
            upperBound: niceCeil(maxValue + span * 0.12)
        )
    }

    private static func niceCeil(_ value: Double) -> Double {
        guard value > 0 else { return 1 }
        let step = niceStep(for: value)
        return max(step, ceil(value / step) * step)
    }

    private static func niceFloor(_ value: Double) -> Double {
        guard value < 0 else { return 0 }
        let step = niceStep(for: abs(value))
        return floor(value / step) * step
    }

    private static func niceStep(for value: Double) -> Double {
        let exponent = floor(log10(max(value, 1)))
        let base = pow(10, exponent)
        let normalized = value / base
        if normalized <= 2 { return base / 5 }
        if normalized <= 5 { return base / 2 }
        return base
    }
}

struct DashboardBalanceTimeSeriesChart: View {
    let points: [NetWorthPoint]
    let period: DashboardPeriodContext
    let currencyCode: String
    var onPointTap: ((NetWorthPoint) -> Void)? = nil

    @Binding var hoverBucketStart: Date?

    private var selectedPoint: NetWorthPoint? {
        guard let hoverBucketStart else { return nil }
        return point(for: hoverBucketStart)
    }

    var body: some View {
        let domain = DashboardBalanceChartScale.domain(for: points)
        let latestID = points.last?.id

        Chart {
            ForEach(points) { point in
                LineMark(
                    x: .value("Period", point.month, unit: period.bucket.component),
                    y: .value("Balance", point.balance.dashboardDoubleValue)
                )
                .foregroundStyle(.blue)
                .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.stepEnd)

                AreaMark(
                    x: .value("Period", point.month, unit: period.bucket.component),
                    y: .value("Balance", point.balance.dashboardDoubleValue)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [.blue.opacity(0.22), .blue.opacity(0.03)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.stepEnd)

                PointMark(
                    x: .value("Period", point.month, unit: period.bucket.component),
                    y: .value("Balance", point.balance.dashboardDoubleValue)
                )
                .foregroundStyle(.blue.opacity(point.id == latestID ? 0.95 : 0.42))
                .symbolSize(point.id == latestID ? 54 : 14)
            }

            if let selectedPoint {
                RuleMark(x: .value("Selected", selectedPoint.month))
                    .foregroundStyle(.secondary.opacity(0.28))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))

                PointMark(
                    x: .value("Selected period", selectedPoint.month, unit: period.bucket.component),
                    y: .value("Selected balance", selectedPoint.balance.dashboardDoubleValue)
                )
                .foregroundStyle(.blue)
                .symbolSize(88)
            }
        }
        .frame(height: 220)
        .chartBackground { _ in Color.clear }
        .chartPlotStyle { plotArea in
            plotArea
                .padding(.top, 6)
                .padding(.trailing, 10)
                .padding(.bottom, 4)
        }
        .chartXScale(domain: period.plotDomain)
        .chartYScale(domain: domain.range)
        .chartXAxis {
            AxisMarks(values: period.axisMarkValues()) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(.secondary.opacity(0.12))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(dashboardAxisLabel(for: date, bucket: period.bucket))
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(.secondary.opacity(0.12))
                AxisValueLabel {
                    if let amount = value.as(Double.self) {
                        Text(dashboardCompactAmount(amount, code: currencyCode))
                    }
                }
                .foregroundStyle(.tertiary)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                ZStack {
                    DashboardChartHoverOverlay(
                        proxy: proxy,
                        geometry: geo,
                        period: period,
                        hoverBucketStart: $hoverBucketStart
                    )

                    if let selectedPoint,
                       let xPos = proxy.position(forX: selectedPoint.month) {
                        balanceTooltip(for: selectedPoint)
                            .position(x: dashboardTooltipX(xPos, in: geo, width: 224), y: 28)
                    }
                }
            }
        }
        .onTapGesture {
            guard let selectedPoint else { return }
            onPointTap?(selectedPoint)
        }
        .animation(.easeInOut(duration: 0.24), value: points.map(\.id))
        .animation(.easeInOut(duration: 0.18), value: hoverBucketStart)
    }

    private func point(for bucketStart: Date) -> NetWorthPoint? {
        points.first { period.bucketStart(forSelection: $0.month) == bucketStart }
    }

    private func previousPoint(before point: NetWorthPoint) -> NetWorthPoint? {
        guard let index = points.firstIndex(where: { $0.id == point.id }), index > 0 else { return nil }
        return points[index - 1]
    }

    private func balanceTooltip(for point: NetWorthPoint) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(dashboardBucketLabel(for: point.month, bucket: period.bucket))
                .font(.caption.weight(.semibold))
            Text(MoneyFormat.string(code: currencyCode, point.balance))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.primary)

            if let previous = previousPoint(before: point) {
                let change = point.balance - previous.balance
                HStack(spacing: 6) {
                    Text("Change")
                    Text(MoneyFormat.string(code: currencyCode, change))
                        .foregroundStyle(change >= 0 ? DashboardChartSeriesColor.income : DashboardChartSeriesColor.expense)
                    if abs(previous.balance) > 0 {
                        Text(percentChange(from: previous.balance, to: point.balance))
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption2.monospacedDigit())
            }
        }
        .padding(9)
        .frame(width: 224, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.10), radius: 10, y: 4)
    }

    private func percentChange(from previous: Decimal, to current: Decimal) -> String {
        let value = (((current - previous) / abs(previous)) as NSDecimalNumber).doubleValue * 100
        return String(format: "%+.1f%%", value)
    }
}

struct DashboardPeriodBucketDisplayValue: Equatable {
    let bucketStart: Date
    let firstMagnitude: Decimal
    let secondMagnitude: Decimal
}

struct DashboardPeriodBarGroup: Identifiable, Equatable {
    let id: Date
    let bucketStart: Date
    let label: String
    let order: Int
    let firstMagnitude: Decimal
    let secondMagnitude: Decimal
    let isPlaceholder: Bool

}

enum DashboardPeriodBarGroupBuilder {
    static func groups(
        period: DashboardPeriodContext,
        buckets: [DashboardPeriodBucketDisplayValue],
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> [DashboardPeriodBarGroup] {
        let sorted = buckets.sorted { $0.bucketStart < $1.bucketStart }
        let activeIndexes = sorted.indices.filter { index in
            sorted[index].firstMagnitude != 0 || sorted[index].secondMagnitude != 0
        }
        guard let firstActive = activeIndexes.first,
              let lastActive = activeIndexes.last else {
            return []
        }

        let visibleBuckets: [DashboardPeriodBucketDisplayValue]
        if period.kind == .all {
            visibleBuckets = activeIndexes.map { sorted[$0] }
        } else {
            visibleBuckets = Array(sorted[firstActive...lastActive])
        }

        return visibleBuckets.enumerated().map { offset, bucket in
            let isPlaceholder = bucket.firstMagnitude == 0 && bucket.secondMagnitude == 0
            return DashboardPeriodBarGroup(
                id: bucket.bucketStart,
                bucketStart: bucket.bucketStart,
                label: dashboardAxisLabel(for: bucket.bucketStart, bucket: period.bucket),
                order: offset,
                firstMagnitude: bucket.firstMagnitude,
                secondMagnitude: bucket.secondMagnitude,
                isPlaceholder: isPlaceholder
            )
        }
    }
}

struct DashboardGroupedPeriodBarChart: View {
    let groups: [DashboardPeriodBarGroup]
    let firstSeriesName: String
    let secondSeriesName: String
    let firstColor: Color
    let secondColor: Color
    let currencyCode: String
    let emptyMessage: String
    var showsFirstSeries: Bool = true
    var showsSecondSeries: Bool = true
    var footerText: ((DashboardPeriodBarGroup) -> String?)? = nil
    var onGroupTap: ((DashboardPeriodBarGroup) -> Void)? = nil
    var selectedGroupID: Date? = nil

    @State private var hoverGroupID: Date? = nil

    private var activeGroupID: Date? {
        selectedGroupID ?? hoverGroupID
    }

    var body: some View {
        if groups.isEmpty || (!showsFirstSeries && !showsSecondSeries) {
            DashboardChartEmptyState(message: groups.isEmpty ? emptyMessage : "No series selected.")
                .frame(height: 220)
        } else {
            GeometryReader { geo in
                let layout = DashboardGroupedBarLayout(
                    groupCount: groups.count,
                    availableWidth: max(1, geo.size.width - 62),
                    showsFirstSeries: showsFirstSeries,
                    showsSecondSeries: showsSecondSeries
                )
                let chartHeight = max(130, geo.size.height - 38)
                let plotTop: CGFloat = 16
                let plotBottom: CGFloat = 24
                let plotHeight = max(80, chartHeight - plotTop - plotBottom)
                let maxValue = maxRenderedValue
                let gridValues = DashboardGroupedBarLayout.gridValues(maxValue: maxValue)
                let plotWidth = max(1, geo.size.width - 62)
                let contentLeft = max(0, (plotWidth - layout.contentWidth) / 2)

                ZStack(alignment: .topLeading) {
                    chartGrid(
                        gridValues: gridValues,
                        maxValue: maxValue,
                        plotTop: plotTop,
                        plotHeight: plotHeight,
                        chartWidth: geo.size.width
                    )

                    HStack(alignment: .bottom, spacing: layout.groupSpacing) {
                        ForEach(groups) { group in
                            groupView(group: group, layout: layout, maxValue: maxValue, plotHeight: plotHeight)
                                .frame(width: layout.groupWidth, height: plotHeight, alignment: .bottom)
                        }
                    }
                    .frame(width: layout.contentWidth, height: plotHeight, alignment: .bottom)
                    .offset(x: contentLeft, y: plotTop)

                    HStack(alignment: .top, spacing: layout.groupSpacing) {
                        ForEach(groups) { group in
                            Text(group.label)
                                .font(.caption2)
                                .foregroundStyle(group.isPlaceholder ? .tertiary : .secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .frame(width: layout.groupWidth)
                        }
                    }
                    .frame(width: layout.contentWidth)
                    .offset(x: contentLeft, y: plotTop + plotHeight + 7)

                    hoverLayer(layout: layout, contentLeft: contentLeft, plotTop: plotTop, plotHeight: plotHeight, geo: geo)
                }
            }
            .frame(height: 220)
        }
    }

    private var maxRenderedValue: Double {
        let values = groups.flatMap { group -> [Double] in
            [
                showsFirstSeries ? group.firstMagnitude.dashboardDoubleMagnitude : 0,
                showsSecondSeries ? group.secondMagnitude.dashboardDoubleMagnitude : 0
            ]
        }
        return max(values.max() ?? 0, 1)
    }

    private func groupView(
        group: DashboardPeriodBarGroup,
        layout: DashboardGroupedBarLayout,
        maxValue: Double,
        plotHeight: CGFloat
    ) -> some View {
        let isHovered = activeGroupID == group.id
        return ZStack(alignment: .bottom) {
            if group.isPlaceholder {
                Capsule()
                    .fill(.secondary.opacity(0.22))
                    .frame(width: max(16, layout.groupWidth * 0.46), height: 2)
                    .padding(.bottom, 1)
            } else {
                HStack(alignment: .bottom, spacing: layout.intraGroupSpacing) {
                    if showsFirstSeries {
                        bar(
                            value: group.firstMagnitude.dashboardDoubleMagnitude,
                            maxValue: maxValue,
                            plotHeight: plotHeight,
                            width: layout.barWidth,
                            color: firstColor,
                            isHovered: isHovered
                        )
                    }
                    if showsSecondSeries {
                        bar(
                            value: group.secondMagnitude.dashboardDoubleMagnitude,
                            maxValue: maxValue,
                            plotHeight: plotHeight,
                            width: layout.barWidth,
                            color: secondColor,
                            isHovered: isHovered
                        )
                    }
                }
            }
        }
        .contentShape(Rectangle())
    }

    private func bar(
        value: Double,
        maxValue: Double,
        plotHeight: CGFloat,
        width: CGFloat,
        color: Color,
        isHovered: Bool
    ) -> some View {
        let height = max(2, CGFloat(max(0, value) / maxValue) * plotHeight)
        return RoundedRectangle(cornerRadius: min(6, width / 2), style: .continuous)
            .fill(color.opacity(isHovered || activeGroupID == nil ? 1 : 0.42))
            .frame(width: width, height: height)
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: min(6, width / 2), style: .continuous)
                    .stroke(.white.opacity(isHovered ? 0.34 : 0), lineWidth: 1)
            }
    }

    private func chartGrid(
        gridValues: [Double],
        maxValue: Double,
        plotTop: CGFloat,
        plotHeight: CGFloat,
        chartWidth: CGFloat
    ) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(gridValues, id: \.self) { value in
                let y = plotTop + plotHeight - (CGFloat(value / maxValue) * plotHeight)
                Rectangle()
                    .fill(.secondary.opacity(value == 0 ? 0.16 : 0.11))
                    .frame(width: max(1, chartWidth - 58), height: 1)
                    .offset(x: 0, y: y)
                Text(dashboardCompactAmount(value, code: currencyCode))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 54, alignment: .trailing)
                    .offset(x: chartWidth - 54, y: max(0, y - 8))
            }
        }
    }

    private func hoverLayer(
        layout: DashboardGroupedBarLayout,
        contentLeft: CGFloat,
        plotTop: CGFloat,
        plotHeight: CGFloat,
        geo: GeometryProxy
    ) -> some View {
        Rectangle()
            .fill(.clear)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    updateHover(location: location, layout: layout, contentLeft: contentLeft, plotTop: plotTop, plotHeight: plotHeight)
                case .ended:
                    hoverGroupID = nil
                }
            }
            .onTapGesture {
                guard let activeGroupID,
                      let group = groups.first(where: { $0.id == activeGroupID }) else { return }
                onGroupTap?(group)
            }
            .overlay(alignment: .topLeading) {
                if let activeGroupID,
                   let group = groups.first(where: { $0.id == activeGroupID }) {
                    tooltip(for: group)
                        .position(
                            x: dashboardTooltipX(groupCenterX(group: group, layout: layout, contentLeft: contentLeft), in: geo, width: 230),
                            y: 26
                        )
                }
            }
    }

    private func updateHover(
        location: CGPoint,
        layout: DashboardGroupedBarLayout,
        contentLeft: CGFloat,
        plotTop: CGFloat,
        plotHeight: CGFloat
    ) {
        guard location.y >= plotTop,
              location.y <= plotTop + plotHeight + 28,
              location.x >= contentLeft,
              location.x <= contentLeft + layout.contentWidth else {
            if hoverGroupID != nil { hoverGroupID = nil }
            return
        }

        let relativeX = location.x - contentLeft
        let step = layout.groupWidth + layout.groupSpacing
        let estimatedIndex = Int((relativeX / step).rounded(.down))
        let candidateIndexes = [estimatedIndex - 1, estimatedIndex, estimatedIndex + 1]
            .filter { groups.indices.contains($0) }
        guard let nearest = candidateIndexes.min(by: {
            abs(groupCenterX(index: $0, layout: layout) - relativeX) < abs(groupCenterX(index: $1, layout: layout) - relativeX)
        }) else {
            if hoverGroupID != nil { hoverGroupID = nil }
            return
        }

        let group = groups[nearest]
        if hoverGroupID != group.id {
            hoverGroupID = group.id
        }
    }

    private func groupCenterX(group: DashboardPeriodBarGroup, layout: DashboardGroupedBarLayout, contentLeft: CGFloat) -> CGFloat {
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return contentLeft }
        return contentLeft + groupCenterX(index: index, layout: layout)
    }

    private func groupCenterX(index: Int, layout: DashboardGroupedBarLayout) -> CGFloat {
        CGFloat(index) * (layout.groupWidth + layout.groupSpacing) + (layout.groupWidth / 2)
    }

    private func tooltip(for group: DashboardPeriodBarGroup) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(group.label)
                .font(.caption.bold())
            Text("\(firstSeriesName): \(MoneyFormat.string(code: currencyCode, group.firstMagnitude))")
                .font(.caption2)
                .foregroundStyle(firstColor)
            Text("\(secondSeriesName): \(MoneyFormat.string(code: currencyCode, group.secondMagnitude))")
                .font(.caption2)
                .foregroundStyle(secondColor)
            if let footer = footerText?(group) {
                Text(footer)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(width: 230, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

struct DashboardGroupedBarLayout {
    let groupCount: Int
    let availableWidth: CGFloat
    let showsFirstSeries: Bool
    let showsSecondSeries: Bool

    var visibleSeriesCount: Int {
        [showsFirstSeries, showsSecondSeries].filter { $0 }.count
    }

    var maxContentWidth: CGFloat {
        switch groupCount {
        case 0...3: return min(availableWidth, 320)
        case 4...6: return min(availableWidth, 520)
        case 7...12: return min(availableWidth, 760)
        default: return availableWidth
        }
    }

    var intraGroupSpacing: CGFloat {
        groupCount > 18 ? 5 : 6
    }

    var groupSpacing: CGFloat {
        let preferred: CGFloat
        switch groupCount {
        case 0...3: preferred = 24
        case 4...6: preferred = 22
        case 7...12: preferred = 18
        default: preferred = 12
        }
        let preferredWidth = idealContentWidth(barWidth: preferredBarWidth, spacing: preferred)
        guard preferredWidth > maxContentWidth, groupCount > 1 else { return preferred }
        let groupTotal = CGFloat(groupCount) * groupWidth(for: preferredBarWidth)
        return max(8, min(preferred, (maxContentWidth - groupTotal) / CGFloat(groupCount - 1)))
    }

    var preferredBarWidth: CGFloat {
        switch groupCount {
        case 0...3: return 22
        case 4...6: return 20
        case 7...12: return 18
        case 13...24: return 14
        default: return 8
        }
    }

    var barWidth: CGFloat {
        let preferred = preferredBarWidth
        let preferredWidth = idealContentWidth(barWidth: preferred, spacing: groupSpacing)
        guard preferredWidth > maxContentWidth else { return preferred }
        let spacingTotal = CGFloat(max(0, groupCount - 1)) * groupSpacing
        let availablePerGroup = max(4, (maxContentWidth - spacingTotal) / CGFloat(max(groupCount, 1)))
        if visibleSeriesCount <= 1 {
            return max(4, min(preferred, availablePerGroup))
        }
        return max(4, min(preferred, (availablePerGroup - intraGroupSpacing) / 2))
    }

    var groupWidth: CGFloat {
        groupWidth(for: barWidth)
    }

    var contentWidth: CGFloat {
        idealContentWidth(barWidth: barWidth, spacing: groupSpacing)
    }

    private func groupWidth(for barWidth: CGFloat) -> CGFloat {
        if visibleSeriesCount <= 1 { return barWidth }
        return barWidth * 2 + intraGroupSpacing
    }

    private func idealContentWidth(barWidth: CGFloat, spacing: CGFloat) -> CGFloat {
        guard groupCount > 0 else { return 0 }
        return CGFloat(groupCount) * groupWidth(for: barWidth) + CGFloat(groupCount - 1) * spacing
    }

    static func gridValues(maxValue: Double) -> [Double] {
        guard maxValue > 0 else { return [0] }
        return [maxValue, maxValue * 0.5, 0]
    }
}

struct DashboardCashFlowTrendPoint: Identifiable, Equatable {
    let bucketStart: Date
    let income: Decimal
    let expenses: Decimal
    let net: Decimal
    let cumulativeNet: Decimal

    var id: Date { bucketStart }
}

enum DashboardCashFlowTrendBuilder {
    static func usesTrendCard(period: DashboardPeriodContext) -> Bool {
        period.kind == .month
    }

    static func points(from entries: [MonthlyCashFlow]) -> [DashboardCashFlowTrendPoint] {
        var running = Decimal.zero
        return entries.sorted { $0.month < $1.month }.map { entry in
            let net = entry.income + entry.expenses
            running += net
            return DashboardCashFlowTrendPoint(
                bucketStart: entry.month,
                income: entry.income,
                expenses: entry.expenses,
                net: net,
                cumulativeNet: running
            )
        }
    }
}

struct DashboardCashFlowTrendChart: View {
    let entries: [MonthlyCashFlow]
    let period: DashboardPeriodContext
    let currencyCode: String
    var onPointTap: ((DashboardCashFlowTrendPoint) -> Void)? = nil

    @Binding var hoverBucketStart: Date?

    private var points: [DashboardCashFlowTrendPoint] {
        DashboardCashFlowTrendBuilder.points(from: entries)
    }

    private var selectedPoint: DashboardCashFlowTrendPoint? {
        guard let hoverBucketStart else { return nil }
        return points.first { $0.bucketStart == hoverBucketStart }
    }

    private var trendColor: Color {
        (points.last?.cumulativeNet ?? 0) >= 0 ? DashboardChartSeriesColor.income : DashboardChartSeriesColor.expense
    }

    var body: some View {
        if points.isEmpty {
            DashboardChartEmptyState(message: "No cash flow activity for this period.")
                .frame(height: 170)
        } else {
            let domain = cashFlowTrendDomain
            Chart {
                ForEach(points) { point in
                    LineMark(
                        x: .value("Day", point.bucketStart, unit: period.bucket.component),
                        y: .value("Month-to-date net", point.cumulativeNet.dashboardDoubleValue)
                    )
                    .foregroundStyle(trendColor)
                    .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))

                    AreaMark(
                        x: .value("Day", point.bucketStart, unit: period.bucket.component),
                        y: .value("Month-to-date net", point.cumulativeNet.dashboardDoubleValue)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [trendColor.opacity(0.20), trendColor.opacity(0.03)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }

                RuleMark(y: .value("Zero", 0))
                    .foregroundStyle(.secondary.opacity(0.18))

                if let selectedPoint {
                    RuleMark(x: .value("Selected", selectedPoint.bucketStart))
                        .foregroundStyle(.secondary.opacity(0.28))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))

                    PointMark(
                        x: .value("Selected day", selectedPoint.bucketStart, unit: period.bucket.component),
                        y: .value("Selected month-to-date net", selectedPoint.cumulativeNet.dashboardDoubleValue)
                    )
                    .foregroundStyle(trendColor)
                    .symbolSize(82)
                }
            }
            .frame(height: 170)
            .chartBackground { _ in Color.clear }
            .chartPlotStyle { plotArea in
                plotArea
                    .padding(.top, 6)
                    .padding(.trailing, 10)
                    .padding(.bottom, 4)
            }
            .chartXScale(domain: period.plotDomain)
            .chartYScale(domain: domain.range)
            .chartXAxis {
                AxisMarks(values: period.axisMarkValues()) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(.secondary.opacity(0.12))
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(dashboardAxisLabel(for: date, bucket: period.bucket))
                        }
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(.secondary.opacity(0.12))
                    AxisValueLabel {
                        if let amount = value.as(Double.self) {
                            Text(dashboardCompactAmount(amount, code: currencyCode))
                        }
                    }
                    .foregroundStyle(.tertiary)
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    ZStack {
                        DashboardChartHoverOverlay(
                            proxy: proxy,
                            geometry: geo,
                            period: period,
                            hoverBucketStart: $hoverBucketStart
                        )

                        if let selectedPoint,
                           let xPos = proxy.position(forX: selectedPoint.bucketStart) {
                            tooltip(for: selectedPoint)
                                .position(x: dashboardTooltipX(xPos, in: geo, width: 220), y: 30)
                        }
                    }
                }
            }
            .onTapGesture {
                guard let selectedPoint else { return }
                onPointTap?(selectedPoint)
            }
            .animation(.easeInOut(duration: 0.18), value: hoverBucketStart)
        }
    }

    private var cashFlowTrendDomain: DashboardBalanceChartDomain {
        let values = points.map { $0.cumulativeNet.dashboardDoubleValue } + [0]
        let chartPoints = values.map {
            NetWorthPoint(month: Date(timeIntervalSince1970: 0), balance: Decimal($0))
        }
        return DashboardBalanceChartScale.domain(for: chartPoints)
    }

    private func tooltip(for point: DashboardCashFlowTrendPoint) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(dashboardBucketLabel(for: point.bucketStart, bucket: period.bucket))
                .font(.caption.weight(.semibold))
            tooltipRow("Income", amount: point.income, color: DashboardChartSeriesColor.income)
            tooltipRow("Expenses", amount: abs(point.expenses), color: DashboardChartSeriesColor.expense)
            tooltipRow("Net", amount: point.net, color: point.net >= 0 ? DashboardChartSeriesColor.income : DashboardChartSeriesColor.expense)
            Divider()
            tooltipRow("Month to date", amount: point.cumulativeNet, color: .primary)
        }
        .padding(8)
        .frame(width: 220, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func tooltipRow(_ title: String, amount: Decimal, color: Color) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(MoneyFormat.string(code: currencyCode, amount))
                .foregroundStyle(color)
        }
        .font(.caption2.monospacedDigit())
    }
}

private extension Decimal {
    var dashboardDoubleValue: Double {
        (self as NSDecimalNumber).doubleValue
    }

    var dashboardDoubleMagnitude: Double {
        max(0, (self as NSDecimalNumber).doubleValue)
    }
}

/// Hero summary tile used on every dashboard. Pickable for drill-down.
/// The amount text is monospaced-digit so consecutive cards align.
struct SummaryCard: View {
    let title: String
    let amount: Decimal
    var currencyCode: String = "MXN"
    var tint: Color? = nil
    /// Optional compact secondary line under the amount (e.g. the Net Worth
    /// card's "Liquid … · Retirement …" split). `nil` on the other cards.
    var subtitle: String? = nil
    /// Optional drill-down action. When provided the card is tappable.
    var onTap: (() -> Void)? = nil

    @Environment(\.scopedTint) private var scopedTint
    @State private var hovering = false

    var body: some View {
        let resolvedTint: Color = tint ?? (amount >= 0 ? .green : .red)
        Button {
            onTap?()
        } label: {
            GlassCard(role: .hero, interactive: onTap != nil) {
                VStack(spacing: 4) {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(MoneyFormat.string(amount, code: currencyCode))
                        .font(.title2.bold())
                        .monospacedDigit()
                        .foregroundStyle(resolvedTint)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
            }
            .scaleEffect(hovering && onTap != nil ? 1.01 : 1.0)
            .animation(.easeInOut(duration: 0.18), value: hovering)
        }
        .buttonStyle(.plain)
        .disabled(onTap == nil)
        .onHover { hovering = $0 }
    }
}

/// Compact transaction row used on the dashboard "Recent Transactions" cards.
/// Currency follows the transaction's own `currency` (no MXN hardcode).
struct DashboardTransactionRow: View {
    let transaction: Transaction

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(categoryColor.opacity(0.18))
                .overlay {
                    Circle()
                        .fill(categoryColor)
                        .frame(width: 7, height: 7)
                }
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(transaction.merchantNormalized.isEmpty ? transaction.descriptionRaw : transaction.merchantNormalized)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(transaction.postedAt.formatted(date: .abbreviated, time: .omitted))
                    if let accountName = transaction.account?.displayName {
                        Text(".")
                        Text(accountName)
                            .lineLimit(1)
                    }
                    if let category = transaction.category {
                        Text(".")
                        Text(category.name)
                            .lineLimit(1)
                    }
                    if let card = transaction.cardLast4 {
                        Text(".")
                        Text("••••\(card)")
                            .lineLimit(1)
                    }
                    if isTransferLike {
                        Text(".")
                        Text("Transfer")
                            .foregroundStyle(.tertiary)
                    }
                }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(MoneyFormat.string(transaction.amount, code: transaction.currency))
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(amountColor)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var isTransferLike: Bool {
        transaction.isTransfer
            || transaction.movementKind == .transfer
            || transaction.category?.kind == .transfer
            || transaction.category?.kind == .creditCardPayment
    }

    private var amountColor: Color {
        if isTransferLike { return .secondary }
        return transaction.amount >= 0 ? DashboardChartSeriesColor.income : .primary
    }

    private var categoryColor: Color {
        if isTransferLike { return .secondary }
        if let category = transaction.category {
            return CategoryPalette.color(for: category.name)
        }
        return .secondary
    }
}

/// Stable category palette for charts, transaction rows, and category chips.
/// Known seed categories get unique slots; future user categories fall back to
/// a deterministic hash so colors remain consistent across launches and views.
enum CategoryPalette {
    static func color(for name: String) -> Color {
        if name == uncategorizedName {
            return Color(light: Color(white: 0.54), dark: Color(white: 0.64))
        }

        let index = namedIndex[name] ?? fallbackIndex(for: name)
        return swatch(index: index)
    }

    static func colorToken(for name: String) -> String {
        if name == uncategorizedName { return "neutral-uncategorized" }
        let index = namedIndex[name] ?? fallbackIndex(for: name)
        return "categorical-\(index)"
    }

    private static let uncategorizedName = "Uncategorized"

    private static let knownNames: [String] = [
        "Food & Drink", "Restaurants", "Groceries", "Coffee", "Fast Food", "Bars & Nightlife",
        "Transport", "Rideshare", "Gas", "Parking", "Public Transit", "Toll",
        "Shopping", "Clothing", "Electronics", "Department Store", "General Merchandise",
        "Entertainment", "Streaming", "Movies", "Games", "Music", "Events",
        "Bills & Utilities", "Electricity", "Internet", "Phone", "Water", "Insurance",
        "Health", "Pharmacy", "Doctor", "Gym", "Wellness",
        "Home", "Rent", "Maintenance", "Furniture", "Services",
        "Education", "Courses", "Books", "Certifications",
        "Travel", "Flights", "Hotels", "Car Rental", "Travel Insurance",
        "Subscriptions", "Software", "Cloud Services", "Memberships", "News",
        "Fees & Charges", "Bank Fees", "Commissions", "Interest Charges", "Late Fees",
        "Taxes", "ISR Retenido", "IVA", "Other Taxes",
        "Income", "Salary", "Freelance", "Interest", "Refund", "Other Income",
        "Investment", "Securities", "CETES", "Funds", "Crypto",
        "Transfers", "Internal Transfer", "To Own Accounts",
        "Credit Card Payments", "Card Payment Received", "Card Payment Sent",
    ]

    private static let namedIndex: [String: Int] = Dictionary(
        uniqueKeysWithValues: knownNames.enumerated().map { ($0.element, $0.offset) }
    )

    private static func swatch(index: Int) -> Color {
        let hue = Double((index * 137) % 360) / 360.0
        let saturation = [0.70, 0.62, 0.78, 0.66][index % 4]
        let lightBrightness = [0.78, 0.70, 0.74, 0.66][(index / 4) % 4]
        let darkBrightness = min(lightBrightness + 0.16, 0.92)
        return Color(
            light: Color(hue: hue, saturation: saturation, brightness: lightBrightness),
            dark: Color(hue: hue, saturation: max(saturation - 0.08, 0.54), brightness: darkBrightness)
        )
    }

    private static func fallbackIndex(for name: String) -> Int {
        let seedCount = knownNames.count
        return seedCount + Int(stableHash(name) % 360)
    }

    private static func stableHash(_ value: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }
}

struct DashboardSpendingBarRow: Identifiable {
    let id: String
    let categoryID: UUID?
    let name: String
    let amount: Decimal
    let total: Decimal
    let isOther: Bool

    var percentage: Double? {
        guard total > 0 else { return nil }
        return ((amount / total) as NSDecimalNumber).doubleValue * 100
    }
}

enum DashboardSpendingBarBuilder {
    static func rows(from entries: [CategorySpending], limit: Int = 5) -> [DashboardSpendingBarRow] {
        let sorted = entries.sorted { $0.amount > $1.amount }
        let total = sorted.reduce(Decimal.zero) { $0 + $1.amount }
        guard total > 0 else { return [] }

        var rows = sorted.prefix(limit).map { entry in
            DashboardSpendingBarRow(
                id: entry.category.id.uuidString,
                categoryID: entry.category.id,
                name: entry.category.name,
                amount: entry.amount,
                total: total,
                isOther: false
            )
        }

        let otherAmount = sorted.dropFirst(limit).reduce(Decimal.zero) { $0 + $1.amount }
        if otherAmount > 0 {
            rows.append(DashboardSpendingBarRow(
                id: "other",
                categoryID: nil,
                name: "Other",
                amount: otherAmount,
                total: total,
                isOther: true
            ))
        }
        return rows
    }
}

struct DashboardSpendingCategoryBars: View {
    let entries: [CategorySpending]
    let currencyCode: String
    var limit: Int = 5
    let onSelect: (CategorySpending) -> Void

    private var rows: [DashboardSpendingBarRow] {
        DashboardSpendingBarBuilder.rows(from: entries, limit: limit)
    }

    private var maxAmount: Decimal {
        rows.map(\.amount).max() ?? 0
    }

    var body: some View {
        if rows.isEmpty {
            DashboardChartEmptyState(message: "No spending in this period.")
        } else {
            VStack(spacing: 9) {
                ForEach(rows) { row in
                    spendingRow(row)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .contain)
        }
    }

    private func spendingRow(_ row: DashboardSpendingBarRow) -> some View {
        let color = row.isOther ? Color.secondary : CategoryPalette.color(for: row.name)
        let widthRatio = maxAmount > 0 ? ((row.amount / maxAmount) as NSDecimalNumber).doubleValue : 0
        let matchedEntry = row.categoryID.flatMap { id in entries.first { $0.category.id == id } }

        return Button {
            if let matchedEntry {
                onSelect(matchedEntry)
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle()
                        .fill(color)
                        .frame(width: 8, height: 8)
                    Text(row.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text(percentText(row.percentage))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(MoneyFormat.string(code: currencyCode, row.amount))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.secondary.opacity(0.13))
                        Capsule()
                            .fill(color.gradient)
                            .frame(width: max(3, proxy.size.width * CGFloat(widthRatio)))
                    }
                }
                .frame(height: 8)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(matchedEntry == nil)
        .help("\(row.name): \(MoneyFormat.string(code: currencyCode, row.amount)), \(percentText(row.percentage))")
    }

    private func percentText(_ percentage: Double?) -> String {
        guard let percentage else { return "0%" }
        return String(format: "%.1f%%", percentage)
    }
}

struct SpendingCategoryDonut: View {
    let entries: [CategorySpending]
    let currencyCode: String
    var chartHeight: CGFloat = 240
    var visibleEntryLimit: Int = 8
    var compactRows: Bool = false
    let onSelect: (CategorySpending) -> Void

    @State private var selectedAngle: Decimal? = nil
    @State private var hoveredCategoryID: UUID? = nil

    private var visibleEntries: [CategorySpending] { Array(entries.prefix(visibleEntryLimit)) }
    private var total: Decimal {
        visibleEntries.reduce(Decimal.zero) { $0 + $1.amount }
    }
    private var activeEntry: CategorySpending? {
        if let hoveredCategoryID {
            return visibleEntries.first { $0.id == hoveredCategoryID }
        }
        return entry(for: selectedAngle)
    }
    private var activeCategoryID: UUID? { activeEntry?.id }

    var body: some View {
        VStack(spacing: 10) {
            Chart(visibleEntries) { entry in
                let isActive = activeCategoryID == entry.id
                let hasActive = activeCategoryID != nil

                SectorMark(
                    angle: .value("Amount", entry.amount),
                    innerRadius: .ratio(0.56),
                    outerRadius: .ratio(isActive ? 1.0 : (hasActive ? 0.93 : 0.97)),
                    angularInset: 1.6
                )
                .foregroundStyle(CategoryPalette.color(for: entry.category.name))
                .opacity(hasActive && !isActive ? 0.26 : 1)
                .annotation(position: .overlay) {
                    if isActive || (!hasActive && entry.amount > total / 5) {
                        CategorySliceLabel(
                            name: entry.category.name,
                            amount: entry.amount,
                            total: total,
                            currencyCode: currencyCode,
                            compact: !isActive
                        )
                    }
                }
            }
            .frame(height: chartHeight)
            .chartAngleSelection(value: $selectedAngle)
            .chartBackground { _ in Color.clear }
            .overlay {
                if let activeEntry {
                    DonutCenterLabel(
                        name: activeEntry.category.name,
                        amount: activeEntry.amount,
                        total: total,
                        currencyCode: currencyCode
                    )
                    .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                if !hovering {
                    selectedAngle = nil
                }
            }
            .onTapGesture {
                if let activeEntry {
                    onSelect(activeEntry)
                }
            }
            .animation(.easeInOut(duration: 0.16), value: activeCategoryID)

            VStack(spacing: compactRows ? 4 : 6) {
                ForEach(visibleEntries) { entry in
                    CategoryBreakdownRow(
                        entry: entry,
                        total: total,
                        currencyCode: currencyCode,
                        isActive: activeCategoryID == entry.id,
                        hasActive: activeCategoryID != nil,
                        compact: compactRows
                    ) {
                        onSelect(entry)
                    }
                    .onHover { hovering in
                        hoveredCategoryID = hovering ? entry.id : nil
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func entry(for selectedAngle: Decimal?) -> CategorySpending? {
        guard let selectedAngle, !visibleEntries.isEmpty else { return nil }

        var lowerBound = Decimal.zero
        for entry in visibleEntries {
            let upperBound = lowerBound + entry.amount
            if selectedAngle >= lowerBound && selectedAngle <= upperBound {
                return entry
            }
            lowerBound = upperBound
        }
        return visibleEntries.last
    }
}

private struct CategorySliceLabel: View {
    let name: String
    let amount: Decimal
    let total: Decimal
    let currencyCode: String
    let compact: Bool

    var body: some View {
        VStack(spacing: 2) {
            Text(name)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
            Text(MoneyFormat.string(code: currencyCode, amount))
                .font(.caption2)
                .monospacedDigit()
            if !compact {
                Text(percentText)
                    .font(.caption2)
                    .opacity(0.85)
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.45), radius: 1, y: 1)
    }

    private var percentText: String {
        guard total > 0 else { return "0%" }
        let value = ((amount / total) as NSDecimalNumber).doubleValue * 100
        return String(format: "%.1f%%", value)
    }
}

private struct DonutCenterLabel: View {
    let name: String
    let amount: Decimal
    let total: Decimal
    let currencyCode: String

    var body: some View {
        VStack(spacing: 3) {
            Text(name)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Text(MoneyFormat.string(code: currencyCode, amount))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(percentText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .frame(width: 104)
        .padding(.horizontal, 8)
    }

    private var percentText: String {
        guard total > 0 else { return "0% of total" }
        let value = ((amount / total) as NSDecimalNumber).doubleValue * 100
        return String(format: "%.1f%% of total", value)
    }
}

private struct CategoryBreakdownRow: View {
    let entry: CategorySpending
    let total: Decimal
    let currencyCode: String
    let isActive: Bool
    let hasActive: Bool
    let compact: Bool
    let onSelect: () -> Void

    private var color: Color { CategoryPalette.color(for: entry.category.name) }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)

                Text(entry.category.name)
                    .font(.caption.weight(isActive ? .semibold : .regular))
                    .lineLimit(1)

                Text(percentText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)

                Spacer()

                Text(MoneyFormat.string(code: currencyCode, entry.amount))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, compact ? 5 : 7)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isActive ? color.opacity(0.14) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isActive ? color.opacity(0.45) : Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            .opacity(hasActive && !isActive ? 0.55 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("\(entry.category.name): \(MoneyFormat.string(code: currencyCode, entry.amount)), \(percentText) of total")
    }

    private var percentText: String {
        guard total > 0 else { return "0%" }
        let value = ((entry.amount / total) as NSDecimalNumber).doubleValue * 100
        return String(format: "%.1f%%", value)
    }
}

/// Wraps a chart in a glass card with a title and (Item 7) a subtle stroke
/// around the plot area. The stroke uses `scopedTint` at low opacity, which
/// makes the chart feel layered onto the glass instead of painted underneath.
struct ChartCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    @Environment(\.scopedTint) private var scopedTint

    var body: some View {
        GlassCard(role: .card, interactive: false) {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.headline)
                content()
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(scopedTint.opacity(0.20), lineWidth: 1)
                            .padding(-2)
                    )
            }
            .padding()
        }
    }
}

enum DashboardAccountBucket: String, CaseIterable, Identifiable {
    case liquidity = "Liquidity"
    case patrimonial = "Patrimonial"
    case retirement = "Retirement"
    case liabilities = "Liabilities"
    case uncategorized = "Uncategorized"

    var id: String { rawValue }
}

struct DashboardAccountGroup: Identifiable {
    let bucket: DashboardAccountBucket
    let subtotal: Decimal
    let detail: String?
    let accounts: [AccountSummary]

    var id: DashboardAccountBucket { bucket }
}

enum DashboardAccountGroupBuilder {
    static func groups(from composition: NetWorthComposition, currencyCode: String) -> [DashboardAccountGroup] {
        var groups: [DashboardAccountGroup] = []

        if !composition.liquidAssetAccounts.isEmpty || composition.netLiquidity != 0 {
            groups.append(DashboardAccountGroup(
                bucket: .liquidity,
                subtotal: composition.netLiquidity,
                detail: "Gross \(MoneyFormat.string(code: currencyCode, composition.grossLiquidity)) after cards",
                accounts: composition.liquidAssetAccounts
            ))
        }

        if !composition.patrimonialAccounts.isEmpty {
            groups.append(DashboardAccountGroup(
                bucket: .patrimonial,
                subtotal: composition.patrimonial,
                detail: nil,
                accounts: composition.patrimonialAccounts
            ))
        }

        if !composition.retirementAccounts.isEmpty {
            groups.append(DashboardAccountGroup(
                bucket: .retirement,
                subtotal: composition.retirement,
                detail: nil,
                accounts: composition.retirementAccounts
            ))
        }

        if !composition.liabilityAccounts.isEmpty || composition.totalLiabilities != 0 {
            groups.append(DashboardAccountGroup(
                bucket: .liabilities,
                subtotal: -composition.totalLiabilities,
                detail: "Outstanding short-term liabilities",
                accounts: composition.liabilityAccounts
            ))
        }

        if !composition.uncategorizedAccounts.isEmpty {
            groups.append(DashboardAccountGroup(
                bucket: .uncategorized,
                subtotal: composition.uncategorized,
                detail: "\(composition.uncategorizedAccounts.count) account\(composition.uncategorizedAccounts.count == 1 ? "" : "s") need review",
                accounts: composition.uncategorizedAccounts
            ))
        }

        return groups
    }
}

struct DashboardListCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        GlassCard(role: .card, interactive: false) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.headline)
                VStack(spacing: 0) {
                    content()
                }
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
            }
            .padding()
        }
    }
}

struct DashboardSeparator: View {
    var body: some View {
        Divider()
            .padding(.leading, 52)
    }
}
