import SwiftUI
import SwiftData

/// Inline review panel for unresolved `PendingImport` rows. The user fills in the
/// missing pieces (date, amount, description) and clicks Resolve, which creates a
/// real `Transaction`, links the pending row to it, and runs through the existing
/// dedup/categorize/save path on the model context.
struct PendingReviewSection: View {
    @Environment(\.modelContext) private var modelContext
    let pendings: [PendingImport]
    let onResolved: (Transaction) -> Void

    @State private var expanded = true

    var body: some View {
        GlassCard(role: .card, interactive: true) {
            VStack(alignment: .leading, spacing: 0) {
                header
                if expanded {
                    Divider()
                    ForEach(pendings) { pending in
                        PendingReviewRow(pending: pending, onResolved: onResolved)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                        if pending != pendings.last {
                            Divider().padding(.leading, 12)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("\(pendings.count) row\(pendings.count == 1 ? "" : "s") need review")
                .font(.headline)
            Spacer()
            Button {
                expanded.toggle()
            } label: {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
    }
}

private struct PendingReviewRow: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var pending: PendingImport
    let onResolved: (Transaction) -> Void

    @State private var draftDate: Date = .now
    @State private var draftAmount: String = ""
    @State private var draftDescription: String = ""
    @State private var didSeed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(pending.rawText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(pending.reason)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                DatePicker("", selection: $draftDate, displayedComponents: .date)
                    .labelsHidden()
                    .frame(width: 140)

                TextField("Amount", text: $draftAmount)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)

                TextField("Description", text: $draftDescription)
                    .textFieldStyle(.roundedBorder)

                if pending.matchedDeletedTransactionId != nil {
                    Button("Restore Deleted") { restoreDeleted() }
                        .buttonStyle(.glassProminent)
                    Button("Keep Deleted") { keepDeleted() }
                        .buttonStyle(.bordered)
                } else {
                    Button("Resolve") { resolve() }
                        .buttonStyle(.glassProminent)
                        .disabled(!canResolve)
                }
            }
        }
        .onAppear { seedDraftsIfNeeded() }
    }

    private func seedDraftsIfNeeded() {
        guard !didSeed else { return }
        didSeed = true
        if let d = pending.parsedDate { draftDate = d }
        if let amount = pending.parsedAmount {
            draftAmount = amountString(amount)
        }
        draftDescription = pending.parsedDescription ?? ""
    }

    private var canResolve: Bool {
        decimalAmount() != nil && !draftDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func decimalAmount() -> Decimal? {
        let cleaned = draftAmount
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: " ", with: "")
        return Decimal(string: cleaned)
    }

    private func resolve() {
        guard let amount = decimalAmount() else { return }
        let description = draftDescription.trimmingCharacters(in: .whitespacesAndNewlines)

        let txn = Transaction(
            account: pending.account,
            statement: pending.statement,
            postedAt: draftDate,
            amount: amount,
            currency: pending.account?.currency ?? "MXN",
            descriptionRaw: description,
            merchantNormalized: description,
            cardLast4: pending.cardLast4
        )
        modelContext.insert(txn)
        pending.resolvedTransaction = txn

        let descriptor = FetchDescriptor<CategoryRule>()
        let rules = (try? modelContext.fetch(descriptor)) ?? []
        _ = Categorizer.categorize(transactions: [txn], rules: rules)

        let keyword = MerchantExtractor.extractMerchant(from: description) ?? description
        let resolvedSign: Int = amount >= 0 ? 1 : -1
        LearningHooks.recordSignRecovery(
            rawText: pending.rawText,
            descriptionKeyword: keyword,
            resolvedSign: resolvedSign,
            in: modelContext
        )

        pending.touch()
        txn.touch()
        try? modelContext.save()
        onResolved(txn)
    }

    private func restoreDeleted() {
        guard let deletedId = pending.matchedDeletedTransactionId else { return }
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate<Transaction> { $0.id == deletedId }
        )
        guard let deleted = (try? modelContext.fetch(descriptor))?.first else { return }
        deleted.deletedAt = nil
        deleted.touch()
        pending.resolvedTransaction = deleted
        pending.touch()
        try? modelContext.save()
        onResolved(deleted)
    }

    private func keepDeleted() {
        pending.resolvedTransaction = Transaction(
            account: pending.account,
            statement: pending.statement,
            postedAt: .now,
            amount: 0,
            currency: pending.account?.currency ?? "MXN",
            descriptionRaw: "Suppressed — kept deleted"
        )
        if let txn = pending.resolvedTransaction {
            modelContext.insert(txn)
            txn.touch()
        }
        pending.touch()
        try? modelContext.save()
    }

    private func amountString(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.usesGroupingSeparator = false
        return formatter.string(from: amount as NSDecimalNumber) ?? "\(amount)"
    }
}
