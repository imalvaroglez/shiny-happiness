import SwiftUI
import SwiftData

struct ApplyToSimilarView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let transaction: Transaction
    let category: Category
    let keyword: String?

    @State private var matchingTransactions: [Transaction] = []
    @State private var selectedIDs: Set<UUID> = []

    private var selectedCount: Int { selectedIDs.count }

    var body: some View {
        VStack(spacing: 0) {
            header
            contentArea
            footer
        }
        .frame(minWidth: 560, minHeight: 520)
        .onAppear {
            loadMatches()
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Text("Apply \"\(category.name)\" to similar transactions?")
                .font(.headline)

            if let keyword {
                HStack(spacing: 6) {
                    Text("Pattern:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("(?i)\(keyword)")
                        .font(.system(.caption, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(Color.primary.opacity(0.06))
                        )
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var contentArea: some View {
        if keyword != nil && !matchingTransactions.isEmpty {
            matchList
        } else if keyword == nil {
            centeredMessage("No extractable merchant keyword found.")
        } else {
            centeredMessage("No other matching transactions found.")
        }
    }

    private var matchList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(matchingTransactions.enumerated()), id: \.element.id) { index, tx in
                    HStack(spacing: 12) {
                        Toggle("", isOn: Binding<Bool>(
                            get: { selectedIDs.contains(tx.id) },
                            set: { isChecked in
                                if isChecked {
                                    selectedIDs.insert(tx.id)
                                } else {
                                    selectedIDs.remove(tx.id)
                                }
                            }
                        ))
                        .toggleStyle(.checkbox)
                        .labelsHidden()

                        Text(tx.postedAt, format: .dateTime.day().month(.abbreviated).year())
                            .font(.system(.caption, design: .monospaced))
                            .frame(width: 80, alignment: .leading)

                        Text(String(tx.descriptionRaw.prefix(80)))
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text(formatMoney(tx.amount))
                            .font(.system(.caption, design: .monospaced).bold())
                            .foregroundStyle(tx.amount >= 0 ? .green : .red)
                            .frame(width: 90, alignment: .trailing)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    if index < matchingTransactions.count - 1 {
                        Divider().padding(.leading, 16)
                    }
                }
            }
        }
    }

    private func centeredMessage(_ text: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack {
            Button("Just This One") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            if keyword != nil && !matchingTransactions.isEmpty {
                Button("Apply to Selected (\(selectedCount))") {
                    applySelected()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(selectedCount == 0)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private func loadMatches() {
        guard let keyword else { return }
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate<Transaction> { $0.deletedAt == nil }
        )
        let all = (try? modelContext.fetch(descriptor)) ?? []
        matchingTransactions = all
            .filter { $0.descriptionRaw.localizedCaseInsensitiveContains(keyword) && $0.id != transaction.id }
            .sorted { $0.postedAt > $1.postedAt }
        selectedIDs = Set(matchingTransactions.map(\.id))
    }

    private func applySelected() {
        guard !selectedIDs.isEmpty else { return }

        let rule = CategoryRule(
            patternRegex: "(?i)\(keyword!)",
            category: category,
            priority: 100,
            source: "user_correction",
            createdFrom: transaction.descriptionRaw
        )
        modelContext.insert(rule)

        for tx in matchingTransactions where selectedIDs.contains(tx.id) {
            tx.category = category
            tx.touch()
        }

        try? modelContext.save()
    }

    private static let _mxnFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "MXN"
        return f
    }()

    private func formatMoney(_ amount: Decimal) -> String {
        Self._mxnFormatter.string(from: amount as NSDecimalNumber) ?? "$0.00"
    }
}
