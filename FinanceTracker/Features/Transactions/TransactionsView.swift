import SwiftUI
import SwiftData

struct TransactionsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Transaction.postedAt, order: .reverse) private var transactions: [Transaction]
    @State private var searchText = ""

    private var filteredTransactions: [Transaction] {
        guard !searchText.isEmpty else { return transactions }
        return transactions.filter {
            $0.descriptionRaw.localizedCaseInsensitiveContains(searchText) ||
            $0.merchantNormalized.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        List {
            ForEach(filteredTransactions) { tx in
                TransactionListRow(transaction: tx)
            }
        }
        .searchable(text: $searchText, prompt: "Search transactions")
        .navigationTitle("Transactions")
    }
}

private struct TransactionListRow: View {
    let transaction: Transaction

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.merchantNormalized.isEmpty ? transaction.descriptionRaw : transaction.merchantNormalized)
                    .font(.body)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(transaction.postedAt, format: .dateTime.day().month(.abbreviated).year())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let cat = transaction.category {
                        Text(cat.name)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }
            }
            Spacer()
            Text(formatMoney(transaction.amount))
                .font(.body.bold())
                .foregroundStyle(transaction.amount >= 0 ? .green : .primary)
        }
        .padding(.vertical, 2)
    }

    private func formatMoney(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "MXN"
        return formatter.string(from: amount as NSDecimalNumber) ?? "$0.00"
    }
}

#Preview {
    TransactionsView()
        .modelContainer(for: Transaction.self, inMemory: true)
}
