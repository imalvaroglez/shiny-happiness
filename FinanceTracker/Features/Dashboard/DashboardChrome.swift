import SwiftUI
import Foundation
import Charts

// Shared chrome used by all three dashboard variants. Money formatting,
// summary tiles, transaction rows, and the category color palette live
// here so the three dashboards don't drift from each other.

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

/// Hero summary tile used on every dashboard. Pickable for drill-down.
/// The amount text is monospaced-digit so consecutive cards align.
struct SummaryCard: View {
    let title: String
    let amount: Decimal
    var currencyCode: String = "MXN"
    var tint: Color? = nil
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
                    if let card = transaction.cardLast4 {
                        Text("•")
                        Text("••••\(card)")
                            .lineLimit(1)
                    }
                }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(MoneyFormat.string(transaction.amount, code: transaction.currency))
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(transaction.amount >= 0 ? .green : .primary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var categoryColor: Color {
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

struct SpendingCategoryDonut: View {
    let entries: [CategorySpending]
    let currencyCode: String
    let onSelect: (CategorySpending) -> Void

    @State private var selectedAngle: Decimal? = nil
    @State private var hoveredCategoryID: UUID? = nil

    private var visibleEntries: [CategorySpending] { Array(entries.prefix(8)) }
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
            .frame(height: 240)
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

            VStack(spacing: 6) {
                ForEach(visibleEntries) { entry in
                    CategoryBreakdownRow(
                        entry: entry,
                        total: total,
                        currencyCode: currencyCode,
                        isActive: activeCategoryID == entry.id,
                        hasActive: activeCategoryID != nil
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
            .padding(.vertical, 7)
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
