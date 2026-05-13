import SwiftUI
import Foundation

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
            Text(MoneyFormat.string(transaction.amount, code: transaction.currency))
                .font(.body.bold())
                .monospacedDigit()
                .foregroundStyle(transaction.amount >= 0 ? .green : .primary)
        }
        .padding(.vertical, 4)
    }
}

/// Dark-mode-tuned category palette. Each named role returns a color whose
/// saturation/brightness is appropriate for both color schemes — the previous
/// flat `.yellow` / `.mint` were too saturated in dark mode.
enum CategoryPalette {
    static func color(for name: String) -> Color {
        guard let role = role(forName: name) else { return .gray.opacity(0.6) }
        return role.color
    }

    private enum PaletteRole {
        case food, transport, shopping, entertainment, bills, health, home,
             travel, transfers, taxes, income, subscriptions, fees

        var color: Color {
            switch self {
            case .food:
                return Color(light: Color(red: 0.95, green: 0.55, blue: 0.20),
                             dark:  Color(red: 0.95, green: 0.65, blue: 0.40))
            case .transport:
                return Color(light: Color(red: 0.20, green: 0.45, blue: 0.85),
                             dark:  Color(red: 0.45, green: 0.65, blue: 0.95))
            case .shopping:
                return Color(light: Color(red: 0.60, green: 0.35, blue: 0.85),
                             dark:  Color(red: 0.70, green: 0.55, blue: 0.95))
            case .entertainment:
                return Color(light: Color(red: 0.90, green: 0.30, blue: 0.55),
                             dark:  Color(red: 0.95, green: 0.50, blue: 0.70))
            case .bills:
                return Color(light: Color(red: 0.85, green: 0.70, blue: 0.20),
                             dark:  Color(red: 0.90, green: 0.80, blue: 0.45))
            case .health:
                return Color(light: Color(red: 0.85, green: 0.25, blue: 0.30),
                             dark:  Color(red: 0.90, green: 0.45, blue: 0.50))
            case .home:
                return Color(light: Color(red: 0.30, green: 0.65, blue: 0.40),
                             dark:  Color(red: 0.50, green: 0.80, blue: 0.55))
            case .travel:
                return Color(light: Color(red: 0.15, green: 0.65, blue: 0.75),
                             dark:  Color(red: 0.40, green: 0.80, blue: 0.85))
            case .transfers:
                return Color(light: Color(white: 0.45), dark: Color(white: 0.65))
            case .taxes:
                return Color(light: Color(red: 0.55, green: 0.40, blue: 0.25),
                             dark:  Color(red: 0.70, green: 0.55, blue: 0.40))
            case .income:
                return Color(light: Color(red: 0.20, green: 0.65, blue: 0.55),
                             dark:  Color(red: 0.40, green: 0.80, blue: 0.70))
            case .subscriptions:
                return Color(light: Color(red: 0.35, green: 0.40, blue: 0.75),
                             dark:  Color(red: 0.55, green: 0.60, blue: 0.90))
            case .fees:
                return Color(light: Color(red: 0.80, green: 0.55, blue: 0.20),
                             dark:  Color(red: 0.90, green: 0.70, blue: 0.40))
            }
        }
    }

    private static func role(forName name: String) -> PaletteRole? {
        let map: [String: PaletteRole] = [
            "Food & Drink": .food, "Groceries": .food, "Coffee": .food,
            "Restaurants": .food, "Fast Food": .food, "Bars & Nightlife": .food,
            "Transport": .transport, "Rideshare": .transport, "Gas": .transport,
            "Parking": .transport, "Public Transit": .transport, "Toll": .transport,
            "Shopping": .shopping, "General Merchandise": .shopping,
            "Clothing": .shopping, "Electronics": .shopping, "Department Store": .shopping,
            "Entertainment": .entertainment, "Streaming": .entertainment,
            "Movies": .entertainment, "Games": .entertainment, "Music": .entertainment,
            "Events": .entertainment,
            "Bills & Utilities": .bills, "Bank Fees": .bills, "Insurance": .bills,
            "Health": .health, "Pharmacy": .health, "Doctor": .health,
            "Gym": .health, "Wellness": .health,
            "Home": .home, "Rent": .home,
            "Travel": .travel, "Flights": .travel, "Hotels": .travel,
            "Transfers": .transfers, "Internal Transfer": .transfers,
            "To Own Accounts": .transfers, "Credit Card Payments": .transfers,
            "Card Payment Received": .transfers, "Card Payment Sent": .transfers,
            "Taxes": .taxes, "ISR Retenido": .taxes,
            "Income": .income, "Interest": .income, "Salary": .income,
            "Subscriptions": .subscriptions, "Software": .subscriptions,
            "Fees & Charges": .fees, "Interest Charges": .fees, "Commissions": .fees,
        ]
        return map[name]
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
        GlassCard(role: .card, interactive: true) {
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
