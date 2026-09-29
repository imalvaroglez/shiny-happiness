import SwiftUI

struct TransactionLedgerRow: View {
    let transaction: Transaction
    let isDeletedMode: Bool
    var isSelectionMode: Bool = false
    var isSelected: Bool = false
    var onToggleSelection: () -> Void = {}
    var wideLayout = false
    var showsAccount = true
    let onOpenDetail: () -> Void
    let onOpenCategoryPicker: () -> Void
    let onDelete: () -> Void
    let onRestore: () -> Void
    let onApplyToSimilar: () -> Void
    var onToggleHousehold: () -> Void = {}

    var body: some View {
        Group {
            if wideLayout {
                wideRow
            } else {
                compactRow
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, wideLayout ? 5 : 6)
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

    private var wideRow: some View {
        HStack(spacing: 10) {
            leadingMark
                .frame(width: 54, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(primaryLabel)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !secondaryMetadataParts.isEmpty {
                    Text(secondaryMetadataParts.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)

            if showsAccount {
                Text(transaction.account?.displayName ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 142, alignment: .leading)
            }

            categoryChip
                .frame(width: 148, alignment: .leading)

            householdIndicator
                .frame(width: 24)

            amountLabel
                .frame(width: 142, alignment: .trailing)
        }
    }

    private var compactRow: some View {
        HStack(spacing: 8) {
            leadingMark

            VStack(alignment: .leading, spacing: 3) {
                Text(primaryLabel)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    categoryChip
                        .frame(maxWidth: 130, alignment: .leading)
                    if showsAccount, let accountName = transaction.account?.displayName {
                        Text(accountName)
                            .lineLimit(1)
                    }
                    if let card = transaction.cardLast4 {
                        Text("••••\(card)").lineLimit(1)
                    }
                    if transaction.expenseAssignment != .user {
                        Text(transaction.expenseAssignment.displayName).lineLimit(1)
                    }
                    householdIndicator
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            amountLabel
                .frame(width: 132, alignment: .trailing)
        }
    }

    private var leadingMark: some View {
        HStack(spacing: 6) {
            if isSelectionMode {
                Toggle("", isOn: Binding(
                    get: { isSelected },
                    set: { _ in onToggleSelection() }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .frame(width: 18)
            } else {
                Color.clear.frame(width: 18)
            }

            Circle()
                .fill(categoryColor.opacity(0.18))
                .overlay {
                    Circle().fill(categoryColor).frame(width: 7, height: 7)
                }
                .frame(width: 28, height: 28)
        }
    }

    private var amountLabel: some View {
        Text(MoneyFormat.string(transaction.amount, code: transaction.currency))
            .font(.callout.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(transaction.amount >= 0 ? .green : .red)
            .lineLimit(1)
    }

    @ViewBuilder
    private var householdIndicator: some View {
        if transaction.isIncludedInHouseholdSettlement {
            Image(systemName: "house.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
                .accessibilityLabel("Included in Household Settlement")
                .accessibilityIdentifier("transaction.row.householdBadge")
        } else {
            Color.clear.frame(width: 12, height: 12)
        }
    }

    private var isHouseholdEligible: Bool {
        HouseholdSettlementReportService.isSettlementEligible(transaction)
    }

    private var secondaryMetadataParts: [String] {
        var parts: [String] = []
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
            Text(category.localizedName)
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

struct TransactionLedgerColumnHeader: View {
    var showsAccount: Bool

    var body: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 54)
            Text("Movement")
                .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
            if showsAccount {
                Text("Account").frame(width: 142, alignment: .leading)
            }
            Text("Category").frame(width: 148, alignment: .leading)
            Image(systemName: "house")
                .accessibilityLabel("Household")
                .frame(width: 24)
            Text("Amount").frame(width: 142, alignment: .trailing)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
    }
}
