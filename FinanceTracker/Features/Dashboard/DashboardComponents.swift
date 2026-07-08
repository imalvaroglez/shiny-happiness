import SwiftUI

/// Applies an accessibility hint only when non-nil (`.accessibilityHint`
/// requires a non-optional `LocalizedStringKey`).
private extension View {
    @ViewBuilder
    func optionalAccessibilityHint(_ hint: String?) -> some View {
        if let hint {
            self.accessibilityHint(hint)
        } else {
            self
        }
    }
}

// MARK: - Design tokens

/// Shared numeric/typographic tokens for the redesigned dashboard. Every card
/// and panel routes through these (and `GlassCard`) so the visual language is
/// one system, not a collection of one-offs.
enum DashboardCardTokens {
    static let sectionSpacing: CGFloat = 16
    static let topStackSpacing: CGFloat = 20
    static let compactPadding: CGFloat = 14
    static let heroPadding: CGFloat = 18
    static let innerWellRadius: CGFloat = 8
    static let plotStrokeRadius: CGFloat = 6

    enum Typography {
        static func sectionTitle() -> Font { .caption.weight(.semibold) }
        static func cardTitle() -> Font { .caption.weight(.semibold) }
        static func heroValue() -> Font { .system(size: 34, weight: .bold) }
        static func compactValue() -> Font { .system(size: 21, weight: .bold) }
        static func chartSummary() -> Font { .title3.bold() }
        static func body() -> Font { .callout }
        static func meta() -> Font { .caption2 }
    }
}

/// Semantic tone system for dashboard values. Replaces ad-hoc `.green`/`.red`
/// /`.mint` scattered across cards so meaning is encoded in one place.
enum DashboardTone {
    case positive   // healthy / growth / positive
    case negative   // debt / negative / urgent
    case warning    // due soon / watch
    case neutral    // neutral info / selection
    case yield      // interest / yield
    case secondary  // muted / secondary

    var color: Color {
        switch self {
        case .positive: return DashboardChartSeriesColor.income
        case .negative: return DashboardChartSeriesColor.expense
        case .warning: return Color(red: 0.70, green: 0.42, blue: 0.00) // #B26A00
        case .neutral: return .blue
        case .yield: return .mint
        case .secondary: return .secondary
        }
    }

    /// Tone for a signed monetary value (positive → positive, else negative).
    static func signed(_ value: Decimal) -> DashboardTone {
        value >= 0 ? .positive : .negative
    }
}

// MARK: - Section header

/// Subtle uppercase section divider. Organizes the page without competing with
/// the cards — small, secondary, never heavy (D3).
struct DashboardSectionHeader: View {
    let title: String
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(title.uppercased())
        }
        .font(DashboardCardTokens.Typography.sectionTitle())
        .foregroundStyle(.secondary)
        .tracking(0.5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Metric card (KPI tile)

/// Period-label semantics (D11): point-in-time vs selected-period vs the
/// Credit-Card-Pace calendar-month exception. Encoded as a type so the label
/// can be tested alongside the value.
enum DashboardPeriodLabel: Hashable {
    /// "As of {date}" — net worth, liabilities, available net worth.
    case asOf(Date)
    /// Selected dashboard period range text — cash flow, interest, anomaly.
    case period(String)
    /// Credit Card Pace: selector-independent calendar-month-to-date.
    case calendarMonthToDate(String)   // e.g. "Jul 1 – today"

    var text: String {
        switch self {
        case .asOf(let date):
            return "As of \(Self.shortDate(date))"
        case .period(let label):
            return label
        case .calendarMonthToDate(let label):
            return label
        }
    }

    private static func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}

/// Reusable KPI tile. Compact form for the 2×2 stack; `prominent` form for the
/// hero (adds an optional delta badge, an optional supporting view — e.g. the
/// sparkline — and a richer subtitle region).
struct DashboardMetricCard: View {
    let title: String
    let amount: Decimal
    let currencyCode: String
    let periodLabel: DashboardPeriodLabel
    var systemImage: String
    var tone: DashboardTone
    var subtitle: String? = nil
    var prominent: Bool = false
    var deltaPercent: Double? = nil           // hero badge (signed)
    var deltaTone: DashboardTone = .positive
    /// Hero-only supporting content rendered under the value (sparkline, split).
    var accessory: AnyView? = nil
    var onTap: (() -> Void)? = nil

    @State private var hovering = false

    var body: some View {
        Button {
            onTap?()
        } label: {
            GlassCard(role: prominent ? .hero : .card, interactive: onTap != nil) {
                HStack(alignment: .top, spacing: 12) {
                    iconBubble

                    VStack(alignment: .leading, spacing: prominent ? 10 : 6) {
                        headerRow

                        Text(MoneyFormat.string(code: currencyCode, amount))
                            .font(prominent
                                  ? DashboardCardTokens.Typography.heroValue()
                                  : DashboardCardTokens.Typography.compactValue())
                            .monospacedDigit()
                            .foregroundStyle(tone.color)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)

                        if let subtitle {
                            Text(subtitle)
                                .font(prominent ? .subheadline : .caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        if let accessory {
                            accessory
                        }

                        Text(periodLabel.text)
                            .font(DashboardCardTokens.Typography.meta().monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(prominent ? DashboardCardTokens.heroPadding : DashboardCardTokens.compactPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scaleEffect(hovering && onTap != nil ? 1.01 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .optionalAccessibilityHint(onTap != nil ? "Open breakdown" : nil)
    }

    /// VoiceOver-friendly summary: title, amount, period, optional delta.
    private var accessibilityDescription: String {
        let amountText = MoneyFormat.string(code: currencyCode, amount)
        var parts = ["\(title)", amountText, periodLabel.text]
        if let subtitle { parts.append(subtitle) }
        if prominent, let deltaPercent {
            parts.append(String(format: "%+.1f%% versus previous period", deltaPercent))
        }
        return parts.joined(separator: ", ")
    }

    private var iconBubble: some View {
        Image(systemName: systemImage)
            .font(.system(size: prominent ? 19 : 15, weight: .semibold))
            .foregroundStyle(tone.color)
            .frame(width: prominent ? 38 : 30, height: prominent ? 38 : 30)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(prominent ? .headline : DashboardCardTokens.Typography.cardTitle())
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if prominent, let deltaPercent {
                DeltaBadge(percent: deltaPercent, tone: deltaTone)
            }
        }
    }
}

/// Hero delta badge: ▲/▼ ±X%.
struct DeltaBadge: View {
    let percent: Double
    let tone: DashboardTone

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: percent >= 0 ? "arrow.up.right" : "arrow.down.right")
            Text(String(format: "%+.1f%%", percent))
        }
        .font(.caption.weight(.semibold).monospacedDigit())
        .foregroundStyle(tone.color)
    }
}

// MARK: - Insight card

/// Status drives tone + copy. Calm is the neutral default so the dashboard is
/// not perpetually alarming (D4).
enum InsightStatus: Hashable {
    case calm
    case watch
    case critical

    var tone: DashboardTone {
        switch self {
        case .calm: return .secondary
        case .watch: return .warning
        case .critical: return .negative
        }
    }
}

/// Reusable actionable-insight tile. `primary`, `secondary`, and an optional
/// status pill; supports an empty/calm body via `calmMessage`.
struct DashboardInsightCard<Accessory: View>: View {
    let title: String
    let systemImage: String
    var status: InsightStatus = .calm
    var statusText: String? = nil
    let primary: String           // e.g. "$89,980 spent"
    var secondaryLines: [String] = []
    var periodLabel: DashboardPeriodLabel
    /// When non-nil, replaces the value body with a calm message line.
    var calmMessage: String? = nil
    var onTap: (() -> Void)? = nil
    @ViewBuilder var accessory: () -> Accessory

    init(
        title: String,
        systemImage: String,
        status: InsightStatus = .calm,
        statusText: String? = nil,
        primary: String,
        secondaryLines: [String] = [],
        periodLabel: DashboardPeriodLabel,
        calmMessage: String? = nil,
        onTap: (() -> Void)? = nil,
        @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }
    ) {
        self.title = title
        self.systemImage = systemImage
        self.status = status
        self.statusText = statusText
        self.primary = primary
        self.secondaryLines = secondaryLines
        self.periodLabel = periodLabel
        self.calmMessage = calmMessage
        self.onTap = onTap
        self.accessory = accessory
    }

    var body: some View {
        GlassCard(role: .card, interactive: onTap != nil) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: systemImage)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(status.tone.color)
                    Text(title)
                        .font(DashboardCardTokens.Typography.cardTitle())
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if let statusText {
                        StatusPill(text: statusText, status: status)
                    }
                }

                if let calmMessage {
                    Text(calmMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text(primary)
                        .font(.title3.bold().monospacedDigit())
                        .foregroundStyle(status.tone.color == .secondary ? .primary : status.tone.color)
                    ForEach(secondaryLines, id: \.self) { line in
                        Text(line)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                accessory()

                Text(periodLabel.text)
                    .font(DashboardCardTokens.Typography.meta().monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(DashboardCardTokens.compactPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(RoundedRectangle(cornerRadius: GlassRadius.card, style: .continuous))
        .onTapGesture { onTap?() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .optionalAccessibilityHint(onTap != nil ? "Open details" : nil)
    }

    private var accessibilityDescription: String {
        var parts = [title]
        if let calmMessage {
            parts.append(calmMessage)
        } else {
            parts.append(primary)
            parts.append(contentsOf: secondaryLines)
        }
        return parts.joined(separator: ", ")
    }
}

struct StatusPill: View {
    let text: String
    let status: InsightStatus

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(status.tone.color, in: Capsule())
    }
}

// MARK: - Chart / breakdown panel

/// Chart wrapper with a title, optional subtitle, and a header accessory slot
/// (used by Net Worth Composition's Total/Available toggle, D8). Routes content
/// through `GlassCard`; the plot stroke is opt-in via `strokePlot`.
struct DashboardChartPanel<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    var headerAccessory: AnyView? = nil
    var strokePlot: Bool = true
    @ViewBuilder var content: () -> Content
    @Environment(\.scopedTint) private var scopedTint

    var body: some View {
        GlassCard(role: .card, interactive: false) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.headline)
                        if let subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    if let headerAccessory {
                        headerAccessory
                    }
                }
                content()
                    .padding(strokePlot ? 8 : 0)
                    .background(
                        Group {
                            if strokePlot {
                                RoundedRectangle(cornerRadius: DashboardCardTokens.plotStrokeRadius, style: .continuous)
                                    .stroke(scopedTint.opacity(0.20), lineWidth: 1)
                                    .padding(-2)
                            }
                        }
                    )
            }
            .padding()
        }
    }
}

/// Breakdown panels are chart panels without the plot stroke (their content is
/// rows, not a chart canvas).
typealias DashboardBreakdownPanel<Content: View> = DashboardChartPanel<Content>
