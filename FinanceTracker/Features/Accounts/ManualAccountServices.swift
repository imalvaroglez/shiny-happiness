import Foundation
import SwiftData

enum ManualAccountKind: String, CaseIterable, Identifiable {
    case debit
    case investment
    case retirement
    case creditCard
    case loan

    var id: String { rawValue }

    var accountType: AccountType {
        switch self {
        case .debit: .checking
        case .investment: .investment
        case .retirement: .retirement
        case .creditCard: .creditCard
        case .loan: .loan
        }
    }

    var displayName: String {
        switch self {
        case .debit: "Debit"
        case .investment: "Investment"
        case .retirement: "Retirement"
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
    case cardCredit = "Card Credit"
    case payment = "Payment"
    case transfer = "Transfer"

    var id: String { rawValue }

    static func availableKinds(for accountType: AccountType) -> [ManualTransactionKind] {
        if accountType == .creditCard {
            return [.charge, .cardCredit, .payment]
        }
        return accountType.isLiability ? [.charge, .payment] : [.income, .expense, .transfer]
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
        retirementKind: RetirementKind? = nil,
        liquidity: AccountLiquidity? = nil,
        includeInNetWorth: Bool? = nil,
        includeInCashFlow: Bool? = nil,
        includeInRegularIncome: Bool? = nil,
        taxTrackingEnabled: Bool? = nil,
        openedAt: Date = .now,
        context: ModelContext
    ) throws -> Account {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedInstitution = institution.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCurrency = currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmedName.isEmpty else { throw ManualAccountError.emptyName }
        guard !trimmedInstitution.isEmpty else { throw ManualAccountError.emptyInstitution }
        guard openingAmount >= 0 else { throw ManualAccountError.invalidAmount }

        let account = Account(
            institution: trimmedInstitution,
            type: kind.accountType,
            currency: trimmedCurrency.isEmpty ? "MXN" : trimmedCurrency,
            nickname: trimmedName,
            accountNumber: normalizedOptional(accountNumber),
            openedAt: openedAt,
            creditLimit: kind == .creditCard ? creditLimit : nil,
            tintHex: tintHex,
            manuallyCreatedAt: .now,
            retirementKindRaw: retirementKind?.rawValue,
            liquidityRaw: liquidity?.rawValue,
            includeInNetWorth: includeInNetWorth,
            includeInCashFlow: includeInCashFlow,
            includeInRegularIncome: includeInRegularIncome,
            taxTrackingEnabled: taxTrackingEnabled
        )
        context.insert(account)

        let signedAmount = kind.isLiability ? -abs(openingAmount) : abs(openingAmount)
        let snapshot = AccountBalanceSnapshot(
            account: account,
            date: openedAt,
            amount: signedAmount,
            kind: .manualOpening,
            note: "Opening balance"
        )
        context.insert(snapshot)
        BalanceSnapshotService.createMirrorTransaction(for: snapshot, account: account, context: context)
        try context.save()
        return account
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension RetirementKind {
    var displayName: String {
        switch self {
        case .ppr: "PPR"
        case .afore: "AFORE"
        case .employerRetirementPlan: "Employer Plan"
        case .other: "Other Retirement"
        }
    }
}

extension AccountLiquidity {
    var displayName: String {
        switch self {
        case .liquid: "Liquid"
        case .restricted: "Restricted"
        case .lockedUntilRetirement: "Locked"
        }
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
        createMirrorTransaction(for: snapshot, account: account, context: context)
        try context.save()
        return snapshot
    }

    static func mirroredSnapshot(for transaction: Transaction, context: ModelContext) -> AccountBalanceSnapshot? {
        let id = transaction.id
        var descriptor = FetchDescriptor<AccountBalanceSnapshot>(
            predicate: #Predicate<AccountBalanceSnapshot> { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    static func syncMirroredSnapshot(for transaction: Transaction, context: ModelContext) {
        guard let snapshot = mirroredSnapshot(for: transaction, context: context),
              let account = transaction.account else { return }
        let signed = account.type.isLiability ? -abs(transaction.amount) : abs(transaction.amount)
        snapshot.date = transaction.postedAt
        snapshot.amount = signed
        snapshot.note = transaction.descriptionRaw
        snapshot.touch()
        transaction.amount = signed
        transaction.category = nil
        transaction.isDuplicate = true
        transaction.movementKindRaw = TransactionMovementKind.adjustment.rawValue
        transaction.treatmentKindRaw = TransactionTreatmentKind.valuationAdjustment.rawValue
    }

    static func createMirrorTransaction(for snapshot: AccountBalanceSnapshot, account: Account, context: ModelContext) {
        let description = snapshot.note.flatMap { $0.isEmpty ? nil : $0 } ?? "Balance"
        let tx = Transaction(
            id: snapshot.id,
            account: account,
            postedAt: snapshot.date,
            amount: snapshot.amount,
            currency: account.currency,
            descriptionRaw: description,
            merchantNormalized: description,
            isDuplicate: true,
            source: .manual,
            movementKindRaw: TransactionMovementKind.adjustment.rawValue,
            treatmentKindRaw: TransactionTreatmentKind.valuationAdjustment.rawValue
        )
        context.insert(tx)
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
        flowKindRaw: String? = nil,
        treatmentKindRaw: String? = nil,
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
            source: .manual,
            flowKindRaw: flowKindRaw,
            movementKindRaw: Transaction.movementKind(
                from: flowKindRaw.flatMap(TransactionFlowKind.init(rawValue:)) ?? (signedAmount >= 0 ? .income : .expense),
                amount: signedAmount,
                isTransfer: false
            ).rawValue,
            treatmentKindRaw: treatmentKindRaw ?? defaultTreatmentKind(account: account, description: trimmed).rawValue
        )
        context.insert(tx)
        try context.save()
        return tx
    }

    private static func defaultTreatmentKind(account: Account, description: String) -> TransactionTreatmentKind {
        guard account.type == .retirement else { return .regular }
        let text = description.lowercased()
        if ["interest", "return", "yield", "gain", "rendimiento", "interes"].contains(where: { text.contains($0) }) {
            return .investmentReturn
        }
        switch account.retirementKind ?? .other {
        case .ppr:
            return .retirementContributionUserFunded
        case .afore:
            return .statutoryRetirementContribution
        case .employerRetirementPlan:
            return .retirementContributionEmployerFunded
        case .other:
            return .retirementContributionUserFunded
        }
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
            transferGroupID: groupID,
            movementKindRaw: TransactionMovementKind.transfer.rawValue,
            treatmentKindRaw: transferTreatment(source: source, destination: destination).rawValue
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
            transferGroupID: groupID,
            movementKindRaw: TransactionMovementKind.transfer.rawValue,
            treatmentKindRaw: transferTreatment(source: source, destination: destination).rawValue
        )
        context.insert(outflow)
        context.insert(inflow)
        try context.save()
        return (outflow, inflow)
    }

    private static func transferTreatment(source: Account, destination: Account) -> TransactionTreatmentKind {
        guard destination.type == .retirement else { return .regular }
        switch destination.retirementKind ?? .other {
        case .ppr:
            return .retirementContributionUserFunded
        case .afore:
            return .statutoryRetirementContribution
        case .employerRetirementPlan:
            return .retirementContributionEmployerFunded
        case .other:
            return .retirementContributionUserFunded
        }
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

@MainActor
enum PaymentMetadataService {
    private static let hashPrefix = "manual-metadata-"

    static func metadataHash(accountId: UUID, year: Int, month: Int) -> String {
        "\(hashPrefix)\(accountId)-\(year)-\(String(format: "%02d", month))"
    }

    static func upsert(
        account: Account,
        billingMonth: Date,
        dueDate: Date,
        paymentForNoInterest: Decimal?,
        context: ModelContext
    ) throws {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month], from: billingMonth)
        guard let monthStart = calendar.date(from: components),
              let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart)?.addingTimeInterval(-1) else {
            return
        }

        let year = calendar.component(.year, from: monthStart)
        let month = calendar.component(.month, from: monthStart)
        let hash = metadataHash(accountId: account.id, year: year, month: month)

        let descriptor = FetchDescriptor<Statement>(
            predicate: #Predicate<Statement> { $0.sourceFileHash == hash }
        )
        let existing = (try? context.fetch(descriptor))?.first

        if let stmt = existing {
            stmt.paymentDueDate = dueDate
            stmt.paymentForNoInterest = paymentForNoInterest
            stmt.lastModifiedAt = .now
        } else {
            let stmt = Statement(
                account: account,
                periodStart: monthStart,
                periodEnd: monthEnd,
                sourceFileHash: hash,
                closingBalance: nil,
                paymentForNoInterest: paymentForNoInterest,
                paymentDueDate: dueDate
            )
            context.insert(stmt)
        }
        try context.save()
    }

    static func fetch(
        accountId: UUID,
        billingMonthStart: Date,
        context: ModelContext
    ) -> Statement? {
        let calendar = Calendar(identifier: .gregorian)
        let year = calendar.component(.year, from: billingMonthStart)
        let month = calendar.component(.month, from: billingMonthStart)
        let hash = metadataHash(accountId: accountId, year: year, month: month)

        let descriptor = FetchDescriptor<Statement>(
            predicate: #Predicate<Statement> { $0.sourceFileHash == hash }
        )
        return (try? context.fetch(descriptor))?.first
    }

    static func isMetadataStatement(_ statement: Statement) -> Bool {
        statement.sourceFileHash.hasPrefix(hashPrefix)
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
