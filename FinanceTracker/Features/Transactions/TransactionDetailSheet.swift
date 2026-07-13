import SwiftData
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
    var onSaved: (() -> Void)? = nil

    @State private var draftDate: Date
    @State private var draftDescription: String
    @State private var draftAbsoluteAmount: Decimal
    @State private var draftSignedAmount: Decimal
    @State private var draftFlowKind: TransactionFlowKind
    @State private var draftTreatmentKind: TransactionTreatmentKind
    @State private var draftExpenseAssignment: ExpenseAssignment
    @State private var draftCustomFerAmount: Decimal?
    @State private var draftSettlementNotes: String
    @State private var draftIncluded: Bool
    @State private var draftCategory: Category?
    @State private var showingCategoryPicker = false

    @State private var pendingKeyword: String?
    @State private var categoryDidChange = false

    private var isKindEditable: Bool {
        transaction.source == .manual
        && !transaction.isTransfer
        && transaction.account?.type == .creditCard
        && !isBalanceMirror
    }

    private var isBalanceMirror: Bool {
        BalanceSnapshotService.mirroredSnapshot(for: transaction, context: modelContext) != nil
    }

    private var isSettlementEditable: Bool {
        !isBalanceMirror && HouseholdSettlementReportService.isSettlementEligible(transaction)
    }

    private var customSplitInvalid: Bool {
        draftExpenseAssignment == .custom && customSplitError != nil
    }

    private var customSplitError: String? {
        guard isSettlementEditable, draftExpenseAssignment == .custom else { return nil }
        guard let amount = draftCustomFerAmount else { return "Enter Fer's portion." }
        if amount < 0 { return "Fer’s portion cannot be negative." }
        if amount > abs(displayAmount) { return "Fer’s portion cannot exceed the original amount." }
        if amount != amount.currencyRounded { return "Use no more than two decimal places." }
        return nil
    }

    private var customUserAmount: Decimal? {
        guard customSplitError == nil, let ferAmount = draftCustomFerAmount else { return nil }
        return abs(displayAmount) - ferAmount
    }

    init(transaction: Transaction, onCategoryAssigned: @escaping (CategoryChange) -> Void, onSaved: (() -> Void)? = nil) {
        self.transaction = transaction
        self.onCategoryAssigned = onCategoryAssigned
        self.onSaved = onSaved
        _draftDate = State(initialValue: transaction.postedAt)
        _draftDescription = State(initialValue: transaction.descriptionRaw)
        _draftAbsoluteAmount = State(initialValue: abs(transaction.amount))
        _draftSignedAmount = State(initialValue: transaction.amount)
        _draftFlowKind = State(initialValue: transaction.flowKind)
        _draftTreatmentKind = State(initialValue: transaction.treatmentKind)
        _draftExpenseAssignment = State(initialValue: transaction.expenseAssignment)
        _draftCustomFerAmount = State(initialValue: transaction.customFerAmount)
        _draftSettlementNotes = State(initialValue: transaction.settlementNotes ?? "")
        _draftCategory = State(initialValue: transaction.category)
        _draftIncluded = State(initialValue: transaction.isIncludedInHouseholdSettlement)
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
        .onChange(of: draftExpenseAssignment) {
            if draftExpenseAssignment == .custom, draftCustomFerAmount == nil {
                draftCustomFerAmount = (abs(displayAmount) / 2).currencyRounded
            }
        }
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

    private var displayAmount: Decimal {
        if isKindEditable {
            return kindDerivedSignedAmount
        }
        return draftSignedAmount
    }

    private var kindDerivedSignedAmount: Decimal {
        switch draftFlowKind {
        case .charge, .expense: return -abs(draftAbsoluteAmount)
        default: return abs(draftAbsoluteAmount)
        }
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

            Text(MoneyFormat.string(displayAmount, code: transaction.currency))
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(displayAmount >= 0 ? .green : .red)
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

            if isKindEditable {
                kindRow
                panelDivider
            }

            editRow("Amount") {
                HStack(spacing: 8) {
                    if isKindEditable {
                        TextField("Amount", value: $draftAbsoluteAmount, format: .number)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                    } else {
                        TextField("Amount", value: $draftSignedAmount, format: .number)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                    }
                    Text(transaction.currency)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            panelDivider

            if transaction.source == .manual && !isBalanceMirror {
                treatmentRow
                panelDivider
            }

            if !isBalanceMirror {
                categoryRow
                panelDivider
            }

            if isSettlementEditable {
                settlementRows
                panelDivider
            }

            if let account = transaction.account {
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

    @ViewBuilder
    private var kindRow: some View {
        editRow("Kind") {
            Picker("Kind", selection: $draftFlowKind) {
                Text("Charge").tag(TransactionFlowKind.charge)
                Text("Card Credit").tag(TransactionFlowKind.cardCredit)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var treatmentRow: some View {
        VStack(spacing: 6) {
            editRow("Treatment") {
                Picker("Treatment", selection: $draftTreatmentKind) {
                    ForEach(TransactionTreatmentKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            VStack(alignment: .trailing, spacing: 2) {
                Text("Treatment changes how this transaction is counted in Income, Expenses, and Cash Flow reporting. It does not change the underlying account movement or transfer status.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.trailing)
                if transaction.isTransfer {
                    Text("This transaction remains a transfer for Income, Expenses, and Cash Flow.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.trailing)
                }
            }
            .padding(.horizontal, 14)
        }
    }

    @ViewBuilder
    private var settlementRows: some View {
        editRow("Include in Household Settlement") {
            Toggle("", isOn: $draftIncluded)
                .labelsHidden()
                .accessibilityIdentifier("transaction.household.includeToggle")
        }
        if draftIncluded {
            panelDivider
            editRow("Assignment") {
                Picker("Assignment", selection: $draftExpenseAssignment) {
                    ForEach(ExpenseAssignment.allCases) { assignment in
                        Text(assignment == .user ? "Mine" : assignment.displayName)
                            .accessibilityIdentifier("transaction.assignment.\(assignment.rawValue)")
                            .tag(assignment)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityIdentifier("transaction.assignment.picker")
            }
            if draftExpenseAssignment == .custom {
            panelDivider
            editRow("Fer’s portion") {
                HStack(spacing: 8) {
                    TextField(
                        "0.00",
                        value: $draftCustomFerAmount,
                        format: .number.precision(.fractionLength(0...2))
                    )
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .accessibilityIdentifier("transaction.customSplit.ferAmount")
                    Text(transaction.currency)
                        .foregroundStyle(.secondary)
                }
            }
            panelDivider
            editRow("Your portion") {
                Text(customUserAmount.map { MoneyFormat.string($0, code: transaction.currency) } ?? "—")
                    .monospacedDigit()
                    .accessibilityIdentifier("transaction.customSplit.userAmount")
            }
            if let userAmount = customUserAmount,
               let ferAmount = draftCustomFerAmount,
               abs(displayAmount) > 0 {
                Text("You \(HouseholdSettlementReport.percent(userAmount / abs(displayAmount))) / Fer \(HouseholdSettlementReport.percent(ferAmount / abs(displayAmount)))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
                    .accessibilityLabel("You \(HouseholdSettlementReport.percent(userAmount / abs(displayAmount))), Fer \(HouseholdSettlementReport.percent(ferAmount / abs(displayAmount)))")
            }
            if let customSplitError {
                Text(customSplitError)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
            }
        }
        } else {
            Text("Only included transactions appear in Household Settlement and affect the amount to recover from Fer.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
        }
        panelDivider
        editRow("Settlement Notes") {
            TextField("Optional", text: $draftSettlementNotes, axis: .vertical)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .lineLimit(1...3)
        }
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
        if isBalanceMirror {
            return .secondary
        }
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
            .disabled(customSplitInvalid)
            .accessibilityIdentifier("transaction.save.button")
            .accessibilityValue(customSplitInvalid ? "Disabled: invalid custom split" : "Enabled")
        }
    }

    private func save() {
        let isBalanceMirror = BalanceSnapshotService.mirroredSnapshot(for: transaction, context: modelContext) != nil
        let amountToStore: Decimal
        if isBalanceMirror, let account = transaction.account {
            amountToStore = account.type.isLiability ? -abs(draftSignedAmount) : abs(draftSignedAmount)
            transaction.isDuplicate = true
            transaction.movementKindRaw = TransactionMovementKind.adjustment.rawValue
            transaction.treatmentKindRaw = TransactionTreatmentKind.valuationAdjustment.rawValue
        } else if isKindEditable {
            switch draftFlowKind {
            case .charge: amountToStore = -abs(draftAbsoluteAmount)
            default: amountToStore = abs(draftAbsoluteAmount)
            }
            transaction.flowKindRaw = draftFlowKind.rawValue
            transaction.movementKindRaw = Transaction.movementKind(
                from: draftFlowKind,
                amount: amountToStore,
                isTransfer: transaction.isTransfer
            ).rawValue
        } else {
            amountToStore = draftSignedAmount
        }

        transaction.postedAt = draftDate
        transaction.descriptionRaw = draftDescription
        transaction.merchantNormalized = draftDescription
        transaction.amount = amountToStore
        // Treatment is reporting-only: store `.regular` as nil to keep data quiet,
        // and never touch flow/movement/transfer here.
        if !isBalanceMirror {
            transaction.setReportingTreatment(draftTreatmentKind)
        }
        if isSettlementEditable {
            // Write the assignment/custom first; only persist scope once that
            // succeeds so a validation error can't leave a half-mutated row.
            if draftIncluded {
                if draftExpenseAssignment == .custom, let ferAmount = draftCustomFerAmount {
                    do {
                        try transaction.setCustomFerAmount(ferAmount)
                    } catch {
                        return
                    }
                } else {
                    transaction.setExpenseAssignment(draftExpenseAssignment)
                }
            }
            // Scope is always persisted explicitly. Exclusion preserves any latent
            // assignment/custom as inactive metadata (do not clear them here).
            transaction.setHouseholdScope(draftIncluded ? .included : .excluded)
            let notes = draftSettlementNotes.trimmingCharacters(in: .whitespacesAndNewlines)
            transaction.settlementNotes = notes.isEmpty ? nil : notes
        }

        if !isBalanceMirror, categoryDidChange, let newCategory = draftCategory {
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
        BalanceSnapshotService.syncMirroredSnapshot(for: transaction, context: modelContext)
        try? modelContext.save()

        if !isBalanceMirror, categoryDidChange, let cat = draftCategory {
            onCategoryAssigned(
                CategoryChange(transaction: transaction, category: cat, keyword: pendingKeyword)
            )
        }

        onSaved?()
        dismiss()
    }
}
