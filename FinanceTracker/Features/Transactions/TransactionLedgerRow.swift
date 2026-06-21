import SwiftUI

struct TransactionLedgerRow: View {
    let transaction: Transaction
    let isDeletedMode: Bool
    let onOpenDetail: () -> Void
    let onOpenCategoryPicker: () -> Void
    let onDelete: () -> Void
    let onRestore: () -> Void
    let onApplyToSimilar: () -> Void

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
                Text(primaryLabel)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !metadataParts.isEmpty {
                    Text(metadataParts.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            categoryChip

            if transaction.isDuplicate {
                Text("DUPLICATE")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(Color.orange.opacity(0.12))
                    )
            }

            Text(MoneyFormat.string(transaction.amount, code: transaction.currency))
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(transaction.amount >= 0 ? .green : .red)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture { onOpenDetail() }
        .contextMenu {
            if isDeletedMode {
                Button("Restore") { onRestore() }
            } else {
                Button("Edit") { onOpenDetail() }
                Button("Change Category") { onOpenCategoryPicker() }
                Button("Apply to Similar…") { onApplyToSimilar() }
                Divider()
                Button("Delete", role: .destructive) { onDelete() }
            }
        }
    }

    private var primaryLabel: String {
        let merchant = transaction.merchantNormalized
        return merchant.isEmpty ? transaction.descriptionRaw : merchant
    }

    private var metadataParts: [String] {
        var parts: [String] = []
        if let account = transaction.account?.displayName { parts.append(account) }
        if let card = transaction.cardLast4 { parts.append("••••\(card)") }
        return parts
    }

    private var categoryColor: Color {
        if let category = transaction.category {
            return CategoryPalette.color(for: category.name)
        }
        return .secondary
    }

    @ViewBuilder
    private var categoryChip: some View {
        if let category = transaction.category {
            Text(category.name)
                .font(.caption2)
                .foregroundStyle(CategoryPalette.color(for: category.name))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(CategoryPalette.color(for: category.name).opacity(0.12))
                )
        } else {
            Text("Uncategorized")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(Color.secondary.opacity(0.08))
                )
        }
    }
}
