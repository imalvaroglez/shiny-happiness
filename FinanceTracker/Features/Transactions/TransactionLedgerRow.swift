import SwiftUI

struct TransactionLedgerRow: View {
    let transaction: Transaction
    let isDeletedMode: Bool
    var isSelectionMode: Bool = false
    var isSelected: Bool = false
    var onToggleSelection: () -> Void = {}
    let onOpenDetail: () -> Void
    let onOpenCategoryPicker: () -> Void
    let onDelete: () -> Void
    let onRestore: () -> Void
    let onApplyToSimilar: () -> Void
    var onToggleHousehold: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            if isSelectionMode {
                Toggle("", isOn: Binding(
                    get: { isSelected },
                    set: { _ in onToggleSelection() }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
            }

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

            if transaction.isIncludedInHouseholdSettlement {
                Image(systemName: "house.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Included in Household Settlement")
                    .accessibilityIdentifier("transaction.row.householdBadge")
            }

            categoryChip

            Text(MoneyFormat.string(transaction.amount, code: transaction.currency))
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(transaction.amount >= 0 ? .green : .red)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelectionMode {
                onToggleSelection()
            } else {
                onOpenDetail()
            }
        }
        .contextMenu {
            if isDeletedMode {
                Button("Restore") { onRestore() }
            } else {
                Button("Edit") { onOpenDetail() }
                Button("Change Category") { onOpenCategoryPicker() }
                Button("Apply to Similar…") { onApplyToSimilar() }
                if isHouseholdEligible {
                    Divider()
                    if transaction.isIncludedInHouseholdSettlement {
                        Button("Remove from Household") { onToggleHousehold() }
                    } else {
                        Button("Add to Household") { onToggleHousehold() }
                    }
                }
                Divider()
                Button("Delete", role: .destructive) { onDelete() }
            }
        }
    }

    private var primaryLabel: String {
        let merchant = transaction.merchantNormalized
        return merchant.isEmpty ? transaction.descriptionRaw : merchant
    }

    private var isHouseholdEligible: Bool {
        HouseholdSettlementReportService.isSettlementEligible(transaction)
    }

    private var metadataParts: [String] {
        var parts: [String] = []
        if let account = transaction.account?.displayName { parts.append(account) }
        if let card = transaction.cardLast4 { parts.append("••••\(card)") }
        if transaction.expenseAssignment != .user {
            parts.append(transaction.expenseAssignment.displayName)
        }
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
