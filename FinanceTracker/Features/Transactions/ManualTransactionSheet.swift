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
    @State private var errorMessage: String?

    private var selectedAccount: Account? {
        accounts.first { $0.id == accountID }
    }

    private var availableKinds: [ManualTransactionKind] {
        guard let account = selectedAccount else {
            return [.income, .expense, .transfer]
        }
        return ManualTransactionKind.availableKinds(for: account.type)
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
            if let acct = selectedAccount {
                if !availableKinds.contains(kind) {
                    kind = availableKinds.first ?? .income
                }
            }
            updateCounterparty()
        }
        .onChange(of: accountID) {
            if let acct = selectedAccount {
                if !ManualTransactionKind.availableKinds(for: acct.type).contains(kind) {
                    kind = ManualTransactionKind.availableKinds(for: acct.type).first ?? .income
                }
            }
            updateCounterparty()
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

    @ViewBuilder
    private var formContent: some View {
        switch kind {
        case .income, .expense:
            singleRows(showCategory: true)
        case .charge:
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
            Picker("Category", selection: $categoryID) {
                Text("Uncategorized").tag(UUID?.none)
                ForEach(categories.filter { $0.parent != nil || $0.kind != .transfer }) { category in
                    Text(category.name).tag(UUID?.some(category.id))
                }
            }
            .labelsHidden()
            .frame(width: 220)
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
                    category: categoryID.flatMap { id in categories.first { $0.id == id } },
                    context: modelContext
                )
            case .expense, .charge:
                guard let account = selectedAccount else { throw ManualAccountError.missingAccount }
                _ = try ManualTransactionService.create(
                    account: account,
                    date: date,
                    description: description,
                    signedAmount: -abs(amount),
                    category: categoryID.flatMap { id in categories.first { $0.id == id } },
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
