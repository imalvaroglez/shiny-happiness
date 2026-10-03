import SwiftUI

/// One column contract for headers and rows, including an empty promotion slot.
private enum TransactionLedgerLayout {
    static let spacing: CGFloat = 10
    static let leading: CGFloat = 54
    static let movement: CGFloat = 120
    static let account: CGFloat = 142
    static let category: CGFloat = 148
    static let household: CGFloat = 24
    static let promotion: CGFloat = 36
    static let amount: CGFloat = 142
}

struct TransactionLedgerRow: View {
    let transaction: Transaction
    let isDeletedMode: Bool
    var isSelectionMode: Bool = false
    var isSelected: Bool = false
    var onToggleSelection: () -> Void = {}
    var wideLayout = false
    var showsAccount = true
    var promotionCount = 0
    let onOpenDetail: () -> Void
    let onOpenCategoryPicker: () -> Void
    let onDelete: () -> Void
    let onRestore: () -> Void
    let onApplyToSimilar: () -> Void
    var onToggleHousehold: () -> Void = {}

    @ViewBuilder
    private var promotionBadge: some View {
        if promotionCount > 0 {
            Text("◆\(promotionCount)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.blue)
                .help("Adjudicada a \(promotionCount) promoción(\(promotionCount == 1 ? "" : "es"))")
        }
    }

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
        HStack(spacing: TransactionLedgerLayout.spacing) {
            leadingMark
                .frame(width: TransactionLedgerLayout.leading, alignment: .leading)

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
            .frame(minWidth: TransactionLedgerLayout.movement, maxWidth: .infinity, alignment: .leading)

            if showsAccount {
                Text(transaction.account?.displayName ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: TransactionLedgerLayout.account, alignment: .leading)
            }

            categoryChip
                .frame(width: TransactionLedgerLayout.category, alignment: .leading)

            householdIndicator
                .frame(width: TransactionLedgerLayout.household)

            promotionBadge
                .frame(width: TransactionLedgerLayout.promotion)

            amountLabel
                .frame(width: TransactionLedgerLayout.amount, alignment: .trailing)
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
                    promotionBadge
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
            return CategoryBadgeColor.color(for: category)
        }
        return .secondary
    }

    @ViewBuilder
    private var categoryChip: some View {
        if let category = transaction.category {
            Text(category.localizedName)
                .font(.caption2)
                .foregroundStyle(CategoryBadgeColor.color(for: category))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(CategoryBadgeColor.color(for: category).opacity(0.12))
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
        HStack(spacing: TransactionLedgerLayout.spacing) {
            Color.clear.frame(width: TransactionLedgerLayout.leading)
            Text("Movement")
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: TransactionLedgerLayout.movement, maxWidth: .infinity, alignment: .leading)
            if showsAccount {
                Text("Account")
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: TransactionLedgerLayout.account, alignment: .leading)
            }
            Text("Category")
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: TransactionLedgerLayout.category, alignment: .leading)
            Image(systemName: "house")
                .accessibilityLabel("Household")
                .frame(width: TransactionLedgerLayout.household)
            // Placeholder del badge de promoción (◆N) para mantener «Amount»
            // alineada con las filas adjudicadas.
            Color.clear.frame(width: TransactionLedgerLayout.promotion)
            Text("Amount")
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: TransactionLedgerLayout.amount, alignment: .trailing)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
    }
}


#Preview("Mixed promotion badges, large text") {
    VStack(spacing: 0) {
        TransactionLedgerColumnHeader(showsAccount: true)
        ForEach([0, 1, 12], id: \.self) { count in
            TransactionLedgerRow(transaction: Transaction(postedAt: .now, amount: -1234,
                descriptionRaw: "Compra con badge \(count)"), isDeletedMode: false,
                wideLayout: true, promotionCount: count,
                onOpenDetail: {}, onOpenCategoryPicker: {}, onDelete: {}, onRestore: {}, onApplyToSimilar: {})
        }
    }
    .dynamicTypeSize(.accessibility2)
    .frame(width: 1050)
    .padding()
}
