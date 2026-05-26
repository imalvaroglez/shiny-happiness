import SwiftUI

struct CategoryChange {
    let transaction: Transaction
    let category: Category
    let keyword: String?
}

struct TransactionDetailSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let transaction: Transaction
    let onCategoryAssigned: (CategoryChange) -> Void

    @State private var draftDate: Date
    @State private var draftDescription: String
    @State private var draftAmount: Decimal
    @State private var draftCategory: Category?
    @State private var showingCategoryPicker = false

    @State private var pendingKeyword: String?
    @State private var categoryDidChange = false

    init(transaction: Transaction, onCategoryAssigned: @escaping (CategoryChange) -> Void) {
        self.transaction = transaction
        self.onCategoryAssigned = onCategoryAssigned
        _draftDate = State(initialValue: transaction.postedAt)
        _draftDescription = State(initialValue: transaction.descriptionRaw)
        _draftAmount = State(initialValue: transaction.amount)
        _draftCategory = State(initialValue: transaction.category)
    }

    var body: some View {
        VStack(spacing: 18) {
            header
            summaryHeader
            editPanel
            footer
        }
        .padding(24)
        .frame(width: 600)
        .sheet(isPresented: $showingCategoryPicker) {
            CategoryPickerView(transaction: transaction) { category, keyword in
                draftCategory = category
                pendingKeyword = keyword
                categoryDidChange = true
            }
        }
    }

    private var header: some View {
        Text("Transaction Details")
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private var summaryHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            Circle()
                .fill(categoryColor.opacity(0.18))
                .overlay {
                    Circle()
                        .fill(categoryColor)
                        .frame(width: 8, height: 8)
                }
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 4) {
                Text(primaryLabel)
                    .font(.headline)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !metadataParts.isEmpty {
                    Text(metadataParts.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 16)

            Text(MoneyFormat.string(draftAmount, code: transaction.currency))
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(draftAmount >= 0 ? .green : .red)
                .lineLimit(1)
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    private var editPanel: some View {
        VStack(spacing: 0) {
            editRow("Statement Date") {
                DatePicker("", selection: $draftDate, displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            panelDivider

            editRow("Description") {
                TextField("Description", text: $draftDescription, axis: .vertical)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(1...3)
            }
            panelDivider

            editRow("Amount") {
                HStack(spacing: 8) {
                    TextField("Amount", value: $draftAmount, format: .number)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                    Text(transaction.currency)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            panelDivider

            categoryRow

            if let account = transaction.account {
                panelDivider
                readOnlyRow("Account", value: account.displayName)
            }

            if let card = transaction.cardLast4 {
                panelDivider
                readOnlyRow("Card", value: "••••\(card)")
            }
        }
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    private func editRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.primary)
                .frame(width: 118, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func readOnlyRow(_ label: String, value: String) -> some View {
        editRow(label) {
            Text(value)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var panelDivider: some View {
        Divider()
            .padding(.leading, 132)
    }

    private var primaryLabel: String {
        let merchant = draftDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return merchant.isEmpty ? "Untitled Transaction" : merchant
    }

    private var metadataParts: [String] {
        var parts: [String] = []
        if let account = transaction.account?.displayName {
            parts.append(account)
        }
        if let card = transaction.cardLast4 {
            parts.append("••••\(card)")
        }
        return parts
    }

    private var categoryColor: Color {
        if let category = draftCategory {
            return CategoryPalette.color(for: category.name)
        }
        return .secondary
    }

    @ViewBuilder
    private var categoryValue: some View {
        if let category = draftCategory {
            HStack(spacing: 6) {
                Circle()
                    .fill(CategoryPalette.color(for: category.name))
                    .frame(width: 8, height: 8)
                Text(category.name)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else {
            Text("Uncategorized")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var categoryRow: some View {
        Button {
            showingCategoryPicker = true
        } label: {
            HStack {
                Text("Category")
                    .font(.callout)
                    .frame(width: 118, alignment: .leading)
                Spacer()
                categoryValue
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack {
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Spacer()
            Button("Save") {
                save()
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.defaultAction)
        }
    }

    private func save() {
        transaction.postedAt = draftDate
        transaction.descriptionRaw = draftDescription
        transaction.merchantNormalized = draftDescription
        transaction.amount = draftAmount

        if categoryDidChange, let newCategory = draftCategory {
            transaction.category = newCategory
            let keyword = MerchantExtractor.extractMerchant(from: draftDescription)
            LearningHooks.recordCategorization(
                keyword: keyword,
                category: newCategory,
                sourceDescription: draftDescription,
                in: modelContext
            )
            pendingKeyword = keyword
        }

        transaction.touch()
        try? modelContext.save()

        if categoryDidChange, let cat = draftCategory {
            onCategoryAssigned(
                CategoryChange(transaction: transaction, category: cat, keyword: pendingKeyword)
            )
        }

        dismiss()
    }
}
