import SwiftUI
import Foundation

// Shared chrome used by all three dashboard variants. Money formatting,
// summary tiles, transaction rows, and the category color palette live
// here so the three dashboards don't drift from each other.

enum MoneyFormat {
    static func string(_ amount: Decimal, code: String = "MXN") -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        return formatter.string(from: amount as NSDecimalNumber) ?? "$0.00"
    }
}

struct SummaryCard: View {
    let title: String
    let amount: Decimal
    var tint: Color? = nil
    /// Optional drill-down action. When provided the card is tappable.
    var onTap: (() -> Void)? = nil

    var body: some View {
        let resolvedTint: Color = tint ?? (amount >= 0 ? .green : .red)
        Button {
            onTap?()
        } label: {
            VStack(spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(MoneyFormat.string(amount))
                    .font(.title2.bold())
                    .foregroundStyle(resolvedTint)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .glassEffect(.regular, in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(onTap == nil)
    }
}

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
                .foregroundStyle(transaction.amount >= 0 ? .green : .primary)
        }
        .padding(.vertical, 4)
    }
}

enum CategoryPalette {
    static func color(for name: String) -> Color {
        let map: [String: Color] = [
            "Food & Drink": .orange,
            "Groceries": .orange,
            "Coffee": .orange,
            "Restaurants": .orange,
            "Fast Food": .orange,
            "Bars & Nightlife": .orange,
            "Transport": .blue,
            "Rideshare": .blue,
            "Gas": .blue,
            "Parking": .blue,
            "Public Transit": .blue,
            "Toll": .blue,
            "Shopping": .purple,
            "General Merchandise": .purple,
            "Clothing": .purple,
            "Electronics": .purple,
            "Department Store": .purple,
            "Entertainment": .pink,
            "Streaming": .pink,
            "Movies": .pink,
            "Games": .pink,
            "Music": .pink,
            "Events": .pink,
            "Bills & Utilities": .yellow,
            "Bank Fees": .yellow,
            "Insurance": .yellow,
            "Health": .red,
            "Pharmacy": .red,
            "Doctor": .red,
            "Gym": .red,
            "Wellness": .red,
            "Home": .green,
            "Rent": .green,
            "Travel": .cyan,
            "Flights": .cyan,
            "Hotels": .cyan,
            "Transfers": .gray,
            "Internal Transfer": .gray,
            "To Own Accounts": .gray,
            "Credit Card Payments": .gray,
            "Card Payment Received": .gray,
            "Card Payment Sent": .gray,
            "Taxes": .brown,
            "ISR Retenido": .brown,
            "Income": .mint,
            "Interest": .mint,
            "Salary": .mint,
            "Subscriptions": .indigo,
            "Software": .indigo,
            "Fees & Charges": .yellow,
            "Interest Charges": .yellow,
            "Commissions": .yellow,
        ]
        return map[name] ?? Color(white: 0.3)
    }
}

struct ChartCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content()
        }
        .padding()
        .glassEffect(.regular, in: .rect(cornerRadius: 10))
    }
}
