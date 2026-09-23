import SwiftData
import SwiftUI

struct ManualTransactionSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \Account.nickname) private var accounts: [Account]
    @Query(filter: #Predicate<Category> { $0.deletedAt == nil },
           sort: \Category.name) private var categories: [Category]

    let defaultAccountID: UUID?
    let lockedAccountID: UUID?
    let onSaved: () -> Void

    init(defaultAccountID: UUID? = nil, lockedAccountID: UUID? = nil, onSaved: @escaping () -> Void) {
        self.defaultAccountID = defaultAccountID
        self.lockedAccountID = lockedAccountID
        self.onSaved = onSaved
    }

    @State private var kind: ManualTransactionKind = .income
    @State private var accountID: UUID?
    @State private var counterpartyAccountID: UUID?
    @State private var date = Date.now
    @State private var description = ""
    @State private var amount: Decimal = 0
    @State private var categoryID: UUID?
    @State private var expenseAssignment: ExpenseAssignment = .user
    @State private var includeInHousehold: Bool = false
    @State private var showingCategoryPicker = false
    @State private var errorMessage: String?

    private var selectedAccount: Account? {
        accounts.first { $0.id == accountID }
    }

    private var selectedCategory: Category? {
        categoryID.flatMap { id in categories.first { $0.id == id } }
    }

    private var availableKinds: [ManualTransactionKind] {
        guard let account = selectedAccount else {
            return [.income, .expense, .transfer]
        }
        return ManualTransactionKind.availableKinds(for: account.type)
    }

    private var allowedCategoryKinds: Set<CategoryKind> {
        switch kind {
        case .income:
            return [.income]
        case .expense, .charge, .cardCredit:
            return [.expense]
        case .payment, .transfer:
            return []
        }
    }

    var body: some View {
        VStack(spacing: 18) {
            Text("Add Transaction")
                .font(.headline)

            if let account = selectedAccount {
                kindPicker(for: account.type)
            }

            VStack(spacing: 0) {
                formContent
            }
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
            )

            promotionPreview

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(accounts.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear {
            accountID = defaultAccountID ?? lockedAccountID ?? accounts.first?.id
            normalizeKindAndCategory()
            updateCounterparty()
        }
        .onChange(of: accountID) {
            normalizeKindAndCategory()
            updateCounterparty()
        }
        .onChange(of: kind) {
            normalizeKindAndCategory()
            updateCounterparty()
        }
        .sheet(isPresented: $showingCategoryPicker) {
            CategoryPickerView(
                selectedCategoryID: categoryID,
                allowedKinds: allowedCategoryKinds
            ) { category in
                categoryID = category.id
            }
        }
    }

    @ViewBuilder
    private func kindPicker(for accountType: AccountType) -> some View {
        let kinds = ManualTransactionKind.availableKinds(for: accountType)
        Picker("Kind", selection: $kind) {
            ForEach(kinds) { k in
                Text(k.rawValue).tag(k)
            }
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Promoción preview (feedback 2026-09-22): evaluación en vivo de la tx candidata
    // contra las promos de la cuenta. Cero persistencia — solo informa al capturar.

    @ViewBuilder
    private var promotionPreview: some View {
        if let account = selectedAccount,
           kind == .charge,
           amount != 0,
           !description.trimmingCharacters(in: .whitespaces).isEmpty {
            let matches = promotionMatches(for: account)
            if !matches.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Cuenta para:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(matches, id: \.definitionID) { promo in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(stateColor(promo))
                                .frame(width: 5, height: 5)
                            Text(promo.displayName)
                                .font(.caption)
                            Spacer()
                            Text(projectionText(promo))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    /// Evalúa la transacción candidata contra las promos de la cuenta (sin persistir nada).
    @MainActor
    private func promotionMatches(for account: Account) -> [PromotionProgress] {
        let catalog = PromotionCatalog.load()
        let bound = catalog.definitions.filter { $0.accountUUID == account.id }
        guard !bound.isEmpty else { return [] }

        // Historial existente de la cuenta (fetch vivo, sin tocar el store).
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate<Transaction> { tx in tx.deletedAt == nil },
            sortBy: [SortDescriptor(\.postedAt)]
        )
        let allLive = (try? modelContext.fetch(descriptor)) ?? []
        let history = allLive.filter { $0.account?.id == account.id }

        // Transacción candidata — NO insertada en el contexto; solo para evaluación.
        let candidate = Transaction(
            account: account,
            postedAt: date,
            amount: amount < 0 ? amount : -abs(amount),  // cargo
            descriptionRaw: description
        )

        return PromotionEvaluator().evaluate(
            definitions: bound, account: account,
            transactions: history + [candidate],
            channelTable: catalog.channelTable, asOf: date
        ).filter { $0.eligibleFirm > 0 || $0.possiblePositiveAddition > 0 }
    }

    private func projectionText(_ promo: PromotionProgress) -> String {
        switch promo.shapeSummary {
        case .spendThreshold(let target, let remaining):
            return remaining > 0
                ? MoneyFormat.string(code: selectedAccount?.currency ?? "MXN", promo.eligibleFirm)
                    + " / " + MoneyFormat.string(code: selectedAccount?.currency ?? "MXN", target)
                : "✓"
        case .cashback(let devengado, _, _):
            return MoneyFormat.string(code: selectedAccount?.currency ?? "MXN", devengado)
        case .tieredPeriods(let periods, let earned, let cap):
            if let current = periods.first(where: { $0.phase == .current }) {
                return MoneyFormat.string(code: selectedAccount?.currency ?? "MXN", current.firm)
                    + " / " + MoneyFormat.string(code: selectedAccount?.currency ?? "MXN", current.threshold)
            }
            _ = periods; _ = earned; _ = cap
            return ""
        }
    }

    private func stateColor(_ promo: PromotionProgress) -> Color {
        switch promo.displayState {
        case .enCurso: return .blue
        case .thresholdReachedPerRecords: return .green
        case .thresholdSuspended, .provisional, .estimated: return .orange
        case .expiredSuspended: return .orange
        case .expired: return .gray
        }
    }

    @ViewBuilder
    private var formContent: some View {
        switch kind {
        case .income, .expense:
            singleRows(showCategory: true)
        case .charge, .cardCredit:
            singleRows(showCategory: true)
        case .payment:
            pairedRows(counterpartyLabel: "From Account")
        case .transfer:
            pairedRows(counterpartyLabel: "To Account")
        }
    }

    @ViewBuilder
    private func singleRows(showCategory: Bool) -> some View {
        if lockedAccountID == nil {
            accountPickerRow("Account", selection: $accountID)
            panelDivider
        }
        row("Date") {
            DatePicker("", selection: $date, displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.compact)
        }
        panelDivider
        row("Description") {
            TextField("Merchant or note", text: $description)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
        }
        panelDivider
        amountRow
        if showCategory {
            panelDivider
            categoryPickerRow
        }
        if kind == .expense || kind == .charge {
            panelDivider
            row("Include in Household") {
                Toggle("", isOn: $includeInHousehold)
                    .labelsHidden()
            }
            if includeInHousehold {
                panelDivider
                expenseAssignmentRow
            }
        }
    }

    @ViewBuilder
    private func pairedRows(counterpartyLabel: String) -> some View {
        if kind == .payment {
            accountPickerRow(counterpartyLabel, selection: $counterpartyAccountID, filter: { !$0.type.isLiability })
            panelDivider
            if lockedAccountID == nil {
                row("Card / Loan") {
                    Text(selectedAccount?.displayName ?? "")
                        .foregroundStyle(.secondary)
                }
                panelDivider
            }
        } else {
            if lockedAccountID == nil {
                accountPickerRow("From", selection: $accountID)
                panelDivider
            }
            accountPickerRow(counterpartyLabel, selection: $counterpartyAccountID)
        }
        panelDivider
        row("Date") {
            DatePicker("", selection: $date, displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.compact)
        }
        panelDivider
        row("Note") {
            TextField("Transfer", text: $description)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
        }
        panelDivider
        amountRow
    }

    private var amountRow: some View {
        row("Amount") {
            TextField("0.00", value: $amount, format: .number)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
        }
    }

    private var categoryPickerRow: some View {
        row("Category") {
            Button {
                showingCategoryPicker = true
            } label: {
                HStack(spacing: 8) {
                    Text(selectedCategory?.name ?? "Uncategorized")
                        .foregroundStyle(selectedCategory == nil ? .secondary : .primary)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .buttonStyle(.plain)
        }
    }

    private var expenseAssignmentRow: some View {
        row("Assignment") {
            Picker("Assignment", selection: $expenseAssignment) {
                ForEach(ExpenseAssignment.quickCases) { assignment in
                    Text(assignment == .user ? "Mine" : assignment.displayName).tag(assignment)
                }
            }
            .labelsHidden()
            .frame(width: 180)
        }
    }

    private func accountPickerRow(_ label: String, selection: Binding<UUID?>, filter: @escaping (Account) -> Bool = { _ in true }) -> some View {
        row(label) {
            Picker(label, selection: selection) {
                ForEach(accounts.filter(filter)) { account in
                    Text(account.displayName).tag(UUID?.some(account.id))
                }
            }
            .labelsHidden()
            .frame(width: 240)
        }
    }

    private var panelDivider: some View {
        Divider().padding(.leading, 132)
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label).frame(width: 116, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func updateCounterparty() {
        if kind == .payment {
            counterpartyAccountID = accounts.first { !$0.type.isLiability && $0.id != accountID }?.id
        } else {
            counterpartyAccountID = accounts.first { $0.id != accountID }?.id
        }
    }

    private func normalizeKindAndCategory() {
        if let account = selectedAccount {
            let kinds = ManualTransactionKind.availableKinds(for: account.type)
            if !kinds.contains(kind) {
                kind = kinds.first ?? .income
            }
        }

        if let category = selectedCategory, !allowedCategoryKinds.contains(category.kind) {
            categoryID = nil
        }
    }

    private func save() {
        do {
            switch kind {
            case .income:
                guard let account = selectedAccount else { throw ManualAccountError.missingAccount }
                _ = try ManualTransactionService.create(
                    account: account,
                    date: date,
                    description: description,
                    signedAmount: abs(amount),
                    category: selectedCategory,
                    flowKindRaw: TransactionFlowKind.income.rawValue,
                    context: modelContext
                )
            case .expense:
                guard let account = selectedAccount else { throw ManualAccountError.missingAccount }
                _ = try ManualTransactionService.create(
                    account: account,
                    date: date,
                    description: description,
                    signedAmount: -abs(amount),
                    category: selectedCategory,
                    flowKindRaw: TransactionFlowKind.expense.rawValue,
                    expenseAssignment: expenseAssignment,
                    householdScope: includeInHousehold ? .included : .excluded,
                    context: modelContext
                )
            case .charge:
                guard let account = selectedAccount else { throw ManualAccountError.missingAccount }
                _ = try ManualTransactionService.create(
                    account: account,
                    date: date,
                    description: description,
                    signedAmount: -abs(amount),
                    category: selectedCategory,
                    flowKindRaw: TransactionFlowKind.charge.rawValue,
                    expenseAssignment: expenseAssignment,
                    householdScope: includeInHousehold ? .included : .excluded,
                    context: modelContext
                )
            case .cardCredit:
                guard let account = selectedAccount else { throw ManualAccountError.missingAccount }
                _ = try ManualTransactionService.create(
                    account: account,
                    date: date,
                    description: description,
                    signedAmount: abs(amount),
                    category: selectedCategory,
                    flowKindRaw: TransactionFlowKind.cardCredit.rawValue,
                    context: modelContext
                )
            case .payment:
                guard let destination = selectedAccount,
                      let source = accounts.first(where: { $0.id == counterpartyAccountID }),
                      source.id != destination.id else {
                    throw ManualAccountError.missingAccount
                }
                _ = try ManualTransferService.create(
                    from: source,
                    to: destination,
                    date: date,
                    amount: abs(amount),
                    note: description,
                    context: modelContext
                )
            case .transfer:
                guard let source = selectedAccount,
                      let destination = accounts.first(where: { $0.id == counterpartyAccountID }),
                      source.id != destination.id else {
                    throw ManualAccountError.missingAccount
                }
                _ = try ManualTransferService.create(
                    from: source,
                    to: destination,
                    date: date,
                    amount: abs(amount),
                    note: description,
                    context: modelContext
                )
            }
            onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
