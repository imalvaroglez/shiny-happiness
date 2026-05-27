import Foundation
import SwiftData

enum ManualAccountKind: String, CaseIterable, Identifiable {
    case debit
    case investment
    case creditCard
    case loan

    var id: String { rawValue }

    var accountType: AccountType {
        switch self {
        case .debit: .checking
        case .investment: .investment
        case .creditCard: .creditCard
        case .loan: .loan
        }
    }

    var displayName: String {
        switch self {
        case .debit: "Debit"
        case .investment: "Investment"
        case .creditCard: "Credit Card"
        case .loan: "Loan"
        }
    }

    var isLiability: Bool {
        self == .creditCard || self == .loan
    }
}

enum ManualAccountError: LocalizedError {
    case emptyName
    case emptyInstitution
    case invalidAmount
    case missingAccount

    var errorDescription: String? {
        switch self {
        case .emptyName: "Enter an account name."
        case .emptyInstitution: "Enter an institution or lender."
        case .invalidAmount: "Enter a valid non-negative amount."
        case .missingAccount: "Choose an account."
        }
    }
}

enum ManualTransactionKind: String, CaseIterable, Identifiable {
    case income = "Income"
    case expense = "Expense"
    case charge = "Charge"
    case payment = "Payment"
    case transfer = "Transfer"

    var id: String { rawValue }

    static func availableKinds(for accountType: AccountType) -> [ManualTransactionKind] {
        accountType.isLiability ? [.charge, .payment] : [.income, .expense, .transfer]
    }
}

@MainActor
enum AccountCreationService {
    @discardableResult
    static func create(
        kind: ManualAccountKind,
        name: String,
        institution: String,
        accountNumber: String?,
        currency: String,
        openingAmount: Decimal,
        creditLimit: Decimal?,
        tintHex: String?,
        context: ModelContext
    ) throws -> Account {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedInstitution = institution.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCurrency = currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmedName.isEmpty else { throw ManualAccountError.emptyName }
        guard !trimmedInstitution.isEmpty else { throw ManualAccountError.emptyInstitution }
        guard openingAmount >= 0 else { throw ManualAccountError.invalidAmount }

        let now = Date.now
        let account = Account(
            institution: trimmedInstitution,
            type: kind.accountType,
            currency: trimmedCurrency.isEmpty ? "MXN" : trimmedCurrency,
            nickname: trimmedName,
            accountNumber: normalizedOptional(accountNumber),
            creditLimit: kind == .creditCard ? creditLimit : nil,
            tintHex: tintHex,
            manuallyCreatedAt: now
        )
        context.insert(account)

        let signedAmount = kind.isLiability ? -abs(openingAmount) : abs(openingAmount)
        let snapshot = AccountBalanceSnapshot(
            account: account,
            date: now,
            amount: signedAmount,
            kind: .manualOpening,
            note: "Opening balance"
        )
        context.insert(snapshot)
        try context.save()
        return account
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

@MainActor
enum BalanceSnapshotService {
    @discardableResult
    static func createAdjustment(
        account: Account,
        date: Date,
        displayAmount: Decimal,
        note: String?,
        context: ModelContext
    ) throws -> AccountBalanceSnapshot {
        guard displayAmount >= 0 else { throw ManualAccountError.invalidAmount }
        let signed = account.type.isLiability ? -abs(displayAmount) : abs(displayAmount)
        let snapshot = AccountBalanceSnapshot(
            account: account,
            date: date,
            amount: signed,
            kind: .manualAdjustment,
            note: note?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        context.insert(snapshot)
        try context.save()
        return snapshot
    }
}

@MainActor
enum ManualTransactionService {
    @discardableResult
    static func create(
        account: Account,
        date: Date,
        description: String,
        signedAmount: Decimal,
        category: Category?,
        context: ModelContext
    ) throws -> Transaction {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ManualAccountError.emptyName }
        let tx = Transaction(
            account: account,
            postedAt: date,
            amount: signedAmount,
            currency: account.currency,
            descriptionRaw: trimmed,
            merchantNormalized: trimmed,
            category: category,
            source: .manual
        )
        context.insert(tx)
        try context.save()
        return tx
    }
}

@MainActor
enum ManualTransferService {
    @discardableResult
    static func create(
        from source: Account,
        to destination: Account,
        date: Date,
        amount: Decimal,
        note: String,
        context: ModelContext
    ) throws -> (outflow: Transaction, inflow: Transaction) {
        guard amount >= 0 else { throw ManualAccountError.invalidAmount }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = trimmed.isEmpty ? "Transfer" : trimmed
        let groupID = UUID()
        let cats = transferCategories(source: source, destination: destination, context: context)

        let outflow = Transaction(
            account: source,
            postedAt: date,
            amount: -abs(amount),
            currency: source.currency,
            descriptionRaw: description,
            merchantNormalized: description,
            category: cats.source,
            isTransfer: true,
            source: .manual,
            transferGroupID: groupID
        )
        let inflow = Transaction(
            account: destination,
            postedAt: date,
            amount: abs(amount),
            currency: destination.currency,
            descriptionRaw: description,
            merchantNormalized: description,
            category: cats.destination,
            isTransfer: true,
            source: .manual,
            transferGroupID: groupID
        )
        context.insert(outflow)
        context.insert(inflow)
        try context.save()
        return (outflow, inflow)
    }

    private static func transferCategories(source: Account, destination: Account, context: ModelContext) -> (source: Category?, destination: Category?) {
        let descriptor = FetchDescriptor<Category>(
            predicate: #Predicate<Category> { $0.deletedAt == nil }
        )
        let categories = (try? context.fetch(descriptor)) ?? []

        if destination.type == .creditCard {
            let sent = categories.first { $0.name == "Card Payment Sent" }
                ?? categories.first { $0.kind == .creditCardPayment }
            let received = categories.first { $0.name == "Card Payment Received" }
                ?? categories.first { $0.kind == .creditCardPayment }
            return (sent, received)
        }

        let transfer = categories.first { $0.kind == .transfer && $0.name == "Internal Transfer" }
            ?? categories.first { $0.kind == .transfer }
        return (transfer, transfer)
    }
}

extension AccountType {
    var isLiability: Bool {
        self == .creditCard || self == .loan
    }

    var displayName: String {
        switch self {
        case .checking: "Debit"
        case .savings: "Savings"
        case .creditCard: "Credit Card"
        case .investment: "Investment"
        case .loan: "Loan"
        case .wallet: "Wallet"
        case .retirement: "Retirement"
        case .other: "Other"
        }
    }
}
