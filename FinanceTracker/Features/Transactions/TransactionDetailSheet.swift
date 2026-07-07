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
    @State private var draftSplitMethod: HouseholdSplitMethod
    @State private var draftCustomUserPercent: Decimal
    @State private var draftCustomPartnerPercent: Decimal
    @State private var draftSettlementNotes: String
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
        !isBalanceMirror && !transaction.isTransfer && !transaction.isDuplicate && transaction.amount < 0
    }

    private var customSplitInvalid: Bool {
        isSettlementEditable
            && draftExpenseAssignment == .shared
            && draftSplitMethod == .customPercent
            && (draftCustomUserPercent < 0
                || draftCustomPartnerPercent < 0
                || draftCustomUserPercent + draftCustomPartnerPercent != 100)
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
        _draftSplitMethod = State(initialValue: transaction.splitMethodOverride)
        _draftCustomUserPercent = State(initialValue: transaction.customUserPercent ?? 50)
        _draftCustomPartnerPercent = State(initialValue: transaction.customPartnerPercent ?? 50)
        _draftSettlementNotes = State(initialValue: transaction.settlementNotes ?? "")
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
        editRow("Assignment") {
            Picker("Assignment", selection: $draftExpenseAssignment) {
                ForEach(ExpenseAssignment.allCases) { assignment in
                    Text(assignment.displayName).tag(assignment)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        if draftExpenseAssignment == .shared {
            panelDivider
            editRow("Split") {
                Picker("Split", selection: $draftSplitMethod) {
                    ForEach(HouseholdSplitMethod.allCases) { method in
                        Text(method.displayName).tag(method)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if draftSplitMethod == .customPercent {
                panelDivider
                editRow("User %") {
                    TextField("50", value: $draftCustomUserPercent, format: .number)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                }
                panelDivider
                editRow("Partner %") {
                    TextField("50", value: $draftCustomPartnerPercent, format: .number)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                }
                if customSplitInvalid {
                    Text("Custom split must add to 100%.")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 6)
                }
            }
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
            transaction.setExpenseAssignment(draftExpenseAssignment)
            if draftExpenseAssignment == .shared {
                transaction.setSplitMethodOverride(draftSplitMethod)
                transaction.customUserPercent = draftSplitMethod == .customPercent ? draftCustomUserPercent : nil
                transaction.customPartnerPercent = draftSplitMethod == .customPercent ? draftCustomPartnerPercent : nil
            } else {
                transaction.setSplitMethodOverride(.monthlyDefault)
                transaction.customUserPercent = nil
                transaction.customPartnerPercent = nil
            }
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
