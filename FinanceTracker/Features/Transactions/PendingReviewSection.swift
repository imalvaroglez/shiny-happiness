import SwiftUI
import SwiftData

struct PendingReviewSection: View {
    @Environment(\.modelContext) private var modelContext
    let pendings: [PendingImport]
    let onResolved: (Transaction) -> Void

    @State private var expanded = true

    var body: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 0) {
                header
                if expanded {
                    Divider()
                    ForEach(Array(pendings.enumerated()), id: \.element.id) { index, pending in
                        PendingReviewRow(pending: pending, onResolved: onResolved)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                        if index < pendings.count - 1 {
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
                .font(.subheadline.weight(.semibold))
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expanded.toggle()
                }
            } label: {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
    @State private var saveError: String?

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

            if let saveError {
                Text(saveError)
                    .font(.caption2)
                    .foregroundStyle(.red)
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
            cardLast4: pending.cardLast4,
            source: .pendingResolution
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
        do {
            try Persistence.save(modelContext)
        } catch {
            saveError = "Couldn't save changes: \(error.localizedDescription)"
            return
        }
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
        do {
            try Persistence.save(modelContext)
        } catch {
            saveError = "Couldn't save changes: \(error.localizedDescription)"
            return
        }
        onResolved(deleted)
    }

    private func keepDeleted() {
        pending.resolvedTransaction = Transaction(
            account: pending.account,
            statement: pending.statement,
            postedAt: .now,
            amount: 0,
            currency: pending.account?.currency ?? "MXN",
            descriptionRaw: "Suppressed — kept deleted",
            source: .pendingResolution
        )
        if let txn = pending.resolvedTransaction {
            modelContext.insert(txn)
            txn.touch()
        }
        pending.touch()
        do {
            try Persistence.save(modelContext)
        } catch {
            saveError = "Couldn't save changes: \(error.localizedDescription)"
            return
        }
    }

    private static let _plainFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        f.usesGroupingSeparator = false
        return f
    }()

    private func amountString(_ amount: Decimal) -> String {
        Self._plainFormatter.string(from: amount as NSDecimalNumber) ?? "\(amount)"
    }
}
