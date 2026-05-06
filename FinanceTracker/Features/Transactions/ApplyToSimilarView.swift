import SwiftUI
import SwiftData

struct ApplyToSimilarView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let transaction: Transaction
    let category: Category
    let keyword: String?

    @State private var matchingCount = 0

    var body: some View {
        VStack(spacing: 20) {
            Text("Apply to Similar?")
                .font(.headline)

            if let keyword {
                VStack(spacing: 8) {
                    Text("Pattern:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("(?i)\(keyword)")
                        .font(.system(.body, design: .monospaced))
                        .padding(8)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                    Text("\(matchingCount) other transaction(s) match this pattern")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No extractable merchant keyword found.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                Button("Just This One") {
                    applySingle()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                if keyword != nil && matchingCount > 0 {
                    Button("All Matching (\(matchingCount))") {
                        applyAll()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        .frame(width: 360)
        .onAppear {
            countMatches()
        }
    }

    private func countMatches() {
        guard let keyword else { return }
        let descriptor = FetchDescriptor<Transaction>()
        let all = (try? modelContext.fetch(descriptor)) ?? []
        matchingCount = all.filter { $0.descriptionRaw.localizedCaseInsensitiveContains(keyword) && $0.id != transaction.id }.count
    }

    private func applySingle() {
        transaction.category = category
        try? modelContext.save()
    }

    private func applyAll() {
        guard let keyword else { return }

        let rule = CategoryRule(
            patternRegex: "(?i)\(keyword)",
            category: category,
            priority: 100,
            source: "user_correction",
            createdFrom: transaction.descriptionRaw
        )
        modelContext.insert(rule)

        let descriptor = FetchDescriptor<Transaction>()
        let allTransactions = (try? modelContext.fetch(descriptor)) ?? []
        let allRules = (try? modelContext.fetch(FetchDescriptor<CategoryRule>())) ?? []
        let _ = Categorizer.categorize(transactions: allTransactions, rules: allRules)

        try? modelContext.save()
    }
}
