import Foundation
import SwiftData
import Testing
@testable import FinanceTracker

@Suite("Manual Ledger")
@MainActor
struct ManualLedgerTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            Account.self,
            AccountBalanceSnapshot.self,
            Transaction.self,
            Statement.self,
            FinanceTracker.Category.self,
            CategoryRule.self,
            InstallmentPlan.self,
            PendingImport.self,
            SignRecoveryHint.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    @Test("Manual account creation stores signed opening snapshots")
    func manualAccountCreationSignsOpeningSnapshots() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let checking = try AccountCreationService.create(
            kind: .debit,
            name: "Debit",
            institution: "Bank",
            accountNumber: nil,
            currency: "MXN",
            openingAmount: 1_500,
            creditLimit: nil,
            tintHex: nil,
            context: context
        )
        let card = try AccountCreationService.create(
            kind: .creditCard,
            name: "Card",
            institution: "Issuer",
            accountNumber: "1234",
            currency: "MXN",
            openingAmount: 900,
            creditLimit: 10_000,
            tintHex: nil,
            context: context
        )

        let snapshots = try context.fetch(FetchDescriptor<AccountBalanceSnapshot>())
        let transactions = try context.fetch(FetchDescriptor<Transaction>())
        let checkingSnapshot = try #require(snapshots.first { $0.account?.id == checking.id })
        let cardSnapshot = try #require(snapshots.first { $0.account?.id == card.id })
        let checkingMirror = try #require(transactions.first { $0.id == checkingSnapshot.id })
        let cardMirror = try #require(transactions.first { $0.id == cardSnapshot.id })

        #expect(checking.manuallyCreatedAt != nil)
        #expect(card.manuallyCreatedAt != nil)
        #expect(card.creditLimit == 10_000)
        #expect(checkingSnapshot.amount == 1_500)
        #expect(cardSnapshot.amount == -900)
        #expect(checkingMirror.amount == checkingSnapshot.amount)
        #expect(cardMirror.amount == cardSnapshot.amount)
        #expect(checkingMirror.isDuplicate)
        #expect(cardMirror.treatmentKind == .valuationAdjustment)
    }

    @Test("Balance resolver uses latest anchor plus later transactions")
    func balanceResolverRollsForwardLatestAnchor() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let epoch = Date(timeIntervalSince1970: 0)
        let account = try AccountCreationService.create(
            kind: .debit,
            name: "Debit",
            institution: "Bank",
            accountNumber: nil,
            currency: "MXN",
            openingAmount: 1_000,
            creditLimit: nil,
            tintHex: nil,
            openedAt: epoch,
            context: context
        )
        let day1 = Date(timeIntervalSince1970: 1_000)
        let day2 = Date(timeIntervalSince1970: 2_000)
        let day3 = Date(timeIntervalSince1970: 3_000)

        _ = try BalanceSnapshotService.createAdjustment(
            account: account,
            date: day1,
            displayAmount: 2_000,
            note: nil,
            context: context
        )
        _ = try ManualTransactionService.create(
            account: account,
            date: day2,
            description: "Groceries",
            signedAmount: -150,
            category: nil,
            context: context
        )
        _ = try ManualTransactionService.create(
            account: account,
            date: day3,
            description: "Deposit",
            signedAmount: 500,
            category: nil,
            context: context
        )

        #expect(AccountBalanceResolver.currentBalance(account: account, context: context) == 2_350)
    }

    @Test("Balance adjustment mirror appears without double-counting")
    func balanceAdjustmentMirrorDoesNotDoubleCount() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let epoch = Date(timeIntervalSince1970: 0)
        let day1 = Date(timeIntervalSince1970: 1_000)
        let day2 = Date(timeIntervalSince1970: 2_000)
        let account = try AccountCreationService.create(
            kind: .debit,
            name: "Debit",
            institution: "Bank",
            accountNumber: nil,
            currency: "MXN",
            openingAmount: 1_000,
            creditLimit: nil,
            tintHex: nil,
            openedAt: epoch,
            context: context
        )
        let snapshot = try BalanceSnapshotService.createAdjustment(
            account: account,
            date: day1,
            displayAmount: 2_000,
            note: "Manual balance",
            context: context
        )
        let tx = try mirror(for: snapshot, context: context)
        let mirrorSnapshot = try #require(BalanceSnapshotService.mirroredSnapshot(for: tx, context: context))

        #expect(tx.id == snapshot.id)
        #expect(mirrorSnapshot.id == snapshot.id)
        #expect(AccountBalanceResolver.currentBalance(account: account, context: context) == 2_000)

        let viewModel = DashboardViewModel()
        viewModel.dateRange = DateRange(start: epoch, end: day2)
        viewModel.scope = .account(account.id)
        viewModel.configure(context: context)

        guard case .asset(let snap) = viewModel.snapshot else {
            Issue.record("Expected asset snapshot"); return
        }
        #expect(snap.recentTransactions.contains { $0.id == snapshot.id })
        #expect(snap.totalIncome == 0)
        #expect(snap.totalExpenses == 0)
        #expect(snap.monthlyCashFlow.isEmpty)
    }

    @Test("Editing balance mirror syncs snapshot")
    func editingBalanceMirrorSyncsSnapshot() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = try AccountCreationService.create(
            kind: .debit,
            name: "Debit",
            institution: "Bank",
            accountNumber: nil,
            currency: "MXN",
            openingAmount: 1_000,
            creditLimit: nil,
            tintHex: nil,
            openedAt: Date(timeIntervalSince1970: 0),
            context: context
        )
        let snapshot = try BalanceSnapshotService.createAdjustment(
            account: account,
            date: Date(timeIntervalSince1970: 1_000),
            displayAmount: 2_000,
            note: "Old",
            context: context
        )
        let tx = try mirror(for: snapshot, context: context)
        tx.postedAt = Date(timeIntervalSince1970: 2_000)
        tx.amount = -3_000
        tx.descriptionRaw = "Corrected"

        BalanceSnapshotService.syncMirroredSnapshot(for: tx, context: context)
        try context.save()

        #expect(snapshot.date == Date(timeIntervalSince1970: 2_000))
        #expect(snapshot.amount == 3_000)
        #expect(snapshot.note == "Corrected")
        #expect(tx.amount == 3_000)
        #expect(AccountBalanceResolver.currentBalance(account: account, context: context) == 3_000)
    }

    @Test("Editing balance mirror clears category without learning")
    func editingBalanceMirrorClearsCategoryWithoutLearning() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let category = FinanceTracker.Category(name: "Entertainment", kind: .expense)
        context.insert(category)
        let account = try AccountCreationService.create(
            kind: .debit,
            name: "Debit",
            institution: "Bank",
            accountNumber: nil,
            currency: "MXN",
            openingAmount: 1_000,
            creditLimit: nil,
            tintHex: nil,
            openedAt: Date(timeIntervalSince1970: 0),
            context: context
        )
        let snapshot = try BalanceSnapshotService.createAdjustment(
            account: account,
            date: Date(timeIntervalSince1970: 1_000),
            displayAmount: 2_000,
            note: "Balance",
            context: context
        )
        let tx = try mirror(for: snapshot, context: context)
        tx.category = category

        BalanceSnapshotService.syncMirroredSnapshot(for: tx, context: context)
        try context.save()

        #expect(tx.category == nil)
        #expect(try context.fetch(FetchDescriptor<CategoryRule>()).isEmpty)
    }

    @Test("Deleting balance mirror excludes and restore includes snapshot")
    func deletingBalanceMirrorTogglesSnapshotAnchor() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = try AccountCreationService.create(
            kind: .debit,
            name: "Debit",
            institution: "Bank",
            accountNumber: nil,
            currency: "MXN",
            openingAmount: 1_000,
            creditLimit: nil,
            tintHex: nil,
            openedAt: Date(timeIntervalSince1970: 0),
            context: context
        )
        let snapshot = try BalanceSnapshotService.createAdjustment(
            account: account,
            date: Date(timeIntervalSince1970: 1_000),
            displayAmount: 2_000,
            note: nil,
            context: context
        )
        let tx = try mirror(for: snapshot, context: context)

        tx.deletedAt = Date.now
        try context.save()
        #expect(AccountBalanceResolver.currentBalance(account: account, context: context) == 1_000)

        tx.deletedAt = nil
        try context.save()
        #expect(AccountBalanceResolver.currentBalance(account: account, context: context) == 2_000)
    }

    @Test("Manual transfer creates linked outflow and inflow")
    func manualTransferCreatesLinkedPair() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let transfer = FinanceTracker.Category(name: "Internal Transfer", kind: .transfer)
        context.insert(transfer)
        let checking = Account(institution: "Bank", type: .checking, currency: "MXN", nickname: "Checking")
        let card = Account(institution: "Issuer", type: .creditCard, currency: "MXN", nickname: "Card")
        context.insert(checking)
        context.insert(card)

        let pair = try ManualTransferService.create(
            from: checking,
            to: card,
            date: .now,
            amount: 1_000,
            note: "Pay card",
            context: context
        )

        #expect(pair.outflow.amount == -1_000)
        #expect(pair.inflow.amount == 1_000)
        #expect(pair.outflow.transferGroupID == pair.inflow.transferGroupID)
        #expect(pair.outflow.source == .manual)
        #expect(pair.inflow.source == .manual)
        #expect(pair.outflow.category?.kind == nil, "No seed categories loaded, outflow category should be nil")
        #expect(pair.inflow.category?.kind == nil, "No seed categories loaded, inflow category should be nil")
    }

    @Test("Debit income creates positive transaction")
    func debitIncomeCreatesPositive() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let checking = Account(institution: "Bank", type: .checking, currency: "MXN")
        context.insert(checking)

        let tx = try ManualTransactionService.create(
            account: checking,
            date: .now,
            description: "Salary",
            signedAmount: 50_000,
            category: nil,
            context: context
        )

        #expect(tx.amount == 50_000, "Income should be positive")
        #expect(tx.source == .manual)
    }

    @Test("Debit expense creates negative transaction")
    func debitExpenseCreatesNegative() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let checking = Account(institution: "Bank", type: .checking, currency: "MXN")
        context.insert(checking)

        let tx = try ManualTransactionService.create(
            account: checking,
            date: .now,
            description: "Coffee",
            signedAmount: -85,
            category: nil,
            context: context
        )

        #expect(tx.amount == -85, "Expense should be negative")
    }

    @Test("Credit-card charge creates negative transaction")
    func creditCardChargeCreatesNegative() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let card = Account(institution: "Issuer", type: .creditCard, currency: "MXN")
        context.insert(card)

        let tx = try ManualTransactionService.create(
            account: card,
            date: .now,
            description: "Store purchase",
            signedAmount: -2_500,
            category: nil,
            context: context
        )

        #expect(tx.amount == -2_500, "Charge should be negative")
    }

    @Test("Credit-card payment creates paired transfer with payment categories")
    func creditCardPaymentCreatesPairedWithPaymentCategories() throws {
        let container = try makeContainer()
        let context = container.mainContext
        SeedDataLoader.bootstrapIfNeeded(context: context)

        let checking = Account(institution: "Bank", type: .checking, currency: "MXN")
        let card = Account(institution: "Issuer", type: .creditCard, currency: "MXN")
        context.insert(checking)
        context.insert(card)

        let pair = try ManualTransferService.create(
            from: checking,
            to: card,
            date: .now,
            amount: 5_000,
            note: "Card payment",
            context: context
        )

        #expect(pair.outflow.amount == -5_000, "Source outflow should be negative")
        #expect(pair.inflow.amount == 5_000, "Card inflow should be positive")
        #expect(pair.outflow.transferGroupID == pair.inflow.transferGroupID)
        #expect(pair.outflow.category?.name == "Card Payment Sent",
                "Source should be Card Payment Sent, got \(pair.outflow.category?.name ?? "nil")")
        #expect(pair.inflow.category?.name == "Card Payment Received",
                "Card should be Card Payment Received, got \(pair.inflow.category?.name ?? "nil")")
        #expect(pair.outflow.category?.kind == .creditCardPayment)
        #expect(pair.inflow.category?.kind == .creditCardPayment)
        #expect(pair.outflow.isTransfer == true)
        #expect(pair.inflow.isTransfer == true)
    }

    @Test("Loan payment creates paired transfer with transfer categories")
    func loanPaymentCreatesPairedWithTransferCategories() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let transfer = FinanceTracker.Category(name: "Internal Transfer", kind: .transfer)
        context.insert(transfer)

        let checking = Account(institution: "Bank", type: .checking, currency: "MXN")
        let loan = Account(institution: "Lender", type: .loan, currency: "MXN")
        context.insert(checking)
        context.insert(loan)

        let pair = try ManualTransferService.create(
            from: checking,
            to: loan,
            date: .now,
            amount: 3_000,
            note: "Loan payment",
            context: context
        )

        #expect(pair.outflow.amount == -3_000)
        #expect(pair.inflow.amount == 3_000)
        #expect(pair.outflow.transferGroupID == pair.inflow.transferGroupID)
        #expect(pair.outflow.category?.kind == .transfer)
        #expect(pair.inflow.category?.kind == .transfer)
    }

    @Test("Asset-to-asset transfer uses transfer category")
    func assetToAssetTransferUsesTransferCategory() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let transfer = FinanceTracker.Category(name: "Internal Transfer", kind: .transfer)
        context.insert(transfer)

        let checking = Account(institution: "Bank", type: .checking, currency: "MXN")
        let savings = Account(institution: "Bank", type: .savings, currency: "MXN")
        context.insert(checking)
        context.insert(savings)

        let pair = try ManualTransferService.create(
            from: checking,
            to: savings,
            date: .now,
            amount: 10_000,
            note: "To savings",
            context: context
        )

        #expect(pair.outflow.amount == -10_000)
        #expect(pair.inflow.amount == 10_000)
        #expect(pair.outflow.category?.kind == .transfer)
        #expect(pair.inflow.category?.kind == .transfer)
        #expect(pair.outflow.isTransfer == true)
        #expect(pair.inflow.isTransfer == true)
    }

    @Test("Payment pair excluded from consolidated cash flow")
    func paymentPairExcludedFromCashFlow() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        SeedDataLoader.bootstrapIfNeeded(context: context)

        let checking = Account(institution: "Bank", type: .checking, currency: "MXN")
        let card = Account(institution: "Issuer", type: .creditCard, currency: "MXN")
        context.insert(checking)
        context.insert(card)

        _ = try ManualTransferService.create(
            from: checking,
            to: card,
            date: .now,
            amount: 5_000,
            note: "Payment",
            context: context
        )
        try context.save()

        let viewModel = DashboardViewModel()
        viewModel.dateRange = DateRange(start: .distantPast, end: .distantFuture)
        viewModel.scope = .consolidated
        viewModel.configure(context: context)

        guard case .consolidated(let snap) = viewModel.snapshot else {
            Issue.record("Expected consolidated snapshot"); return
        }

        #expect(snap.totalIncome == 0, "Paired payment should not appear as income, got \(snap.totalIncome)")
        #expect(snap.totalExpenses == 0, "Paired payment should not appear as expense, got \(snap.totalExpenses)")
    }

    @Test("Card credit creates positive transaction with flowKindRaw")
    func cardCreditCreatesPositiveWithFlowKind() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let card = Account(institution: "Issuer", type: .creditCard, currency: "MXN", nickname: "Card")
        context.insert(card)

        let tx = try ManualTransactionService.create(
            account: card,
            date: .now,
            description: "Cashback reward",
            signedAmount: 500,
            category: nil,
            flowKindRaw: TransactionFlowKind.cardCredit.rawValue,
            context: context
        )

        #expect(tx.amount == 500, "Card credit should be positive")
        #expect(tx.flowKindRaw == "cardCredit")
        #expect(tx.flowKind == .cardCredit)
        #expect(tx.source == .manual)
    }

    @Test("Card credit reduces owed balance and utilization")
    func cardCreditReducesOwedBalance() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let apr1 = dateFromComponents(year: 2026, month: 4, day: 1)
        let apr15 = dateFromComponents(year: 2026, month: 4, day: 15)
        let apr20 = dateFromComponents(year: 2026, month: 4, day: 20)

        let card = try AccountCreationService.create(
            kind: .creditCard,
            name: "Card",
            institution: "Issuer",
            accountNumber: nil,
            currency: "MXN",
            openingAmount: 2_000,
            creditLimit: 10_000,
            tintHex: nil,
            openedAt: apr1,
            context: context
        )

        _ = try ManualTransactionService.create(
            account: card,
            date: apr15,
            description: "Store purchase",
            signedAmount: -3_000,
            category: nil,
            flowKindRaw: TransactionFlowKind.charge.rawValue,
            context: context
        )
        #expect(AccountBalanceResolver.currentBalance(account: card, context: context) == -5_000)

        _ = try ManualTransactionService.create(
            account: card,
            date: apr20,
            description: "Cashback",
            signedAmount: 1_000,
            category: nil,
            flowKindRaw: TransactionFlowKind.cardCredit.rawValue,
            context: context
        )

        let balance = AccountBalanceResolver.currentBalance(account: card, context: context)
        #expect(balance == -4_000, "Card credit should reduce owed, got \(balance)")
    }

    @Test("Card credit excluded from consolidated income")
    func cardCreditExcludedFromConsolidatedIncome() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        SeedDataLoader.bootstrapIfNeeded(context: context)

        let card = Account(institution: "Issuer", type: .creditCard, currency: "MXN", nickname: "Card")
        context.insert(card)

        _ = try ManualTransactionService.create(
            account: card,
            date: .now,
            description: "Cashback",
            signedAmount: 500,
            category: nil,
            flowKindRaw: TransactionFlowKind.cardCredit.rawValue,
            context: context
        )
        try context.save()

        let viewModel = DashboardViewModel()
        viewModel.dateRange = DateRange(start: .distantPast, end: .distantFuture)
        viewModel.scope = .consolidated
        viewModel.configure(context: context)

        guard case .consolidated(let snap) = viewModel.snapshot else {
            Issue.record("Expected consolidated snapshot"); return
        }

        #expect(snap.totalIncome == 0, "Card credit should not appear as income, got \(snap.totalIncome)")
    }

    @Test("Backdated charge after openedAt affects current balance")
    func backdatedChargeAfterOpenedAtAffectsBalance() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let apr1 = dateFromComponents(year: 2026, month: 4, day: 1)
        let apr15 = dateFromComponents(year: 2026, month: 4, day: 15)

        let card = try AccountCreationService.create(
            kind: .creditCard,
            name: "Card",
            institution: "Issuer",
            accountNumber: nil,
            currency: "MXN",
            openingAmount: 0,
            creditLimit: 10_000,
            tintHex: nil,
            openedAt: apr1,
            context: context
        )

        _ = try ManualTransactionService.create(
            account: card,
            date: apr15,
            description: "April charge",
            signedAmount: -2_500,
            category: nil,
            context: context
        )

        let balance = AccountBalanceResolver.currentBalance(account: card, context: context)
        #expect(balance == -2_500, "Backdated charge after openedAt should affect balance, got \(balance)")
    }

    @Test("Transaction before openedAt does not roll forward")
    func transactionBeforeOpenedAtExcluded() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let may1 = dateFromComponents(year: 2026, month: 5, day: 1)
        let apr15 = dateFromComponents(year: 2026, month: 4, day: 15)

        let card = try AccountCreationService.create(
            kind: .creditCard,
            name: "Card",
            institution: "Issuer",
            accountNumber: nil,
            currency: "MXN",
            openingAmount: 0,
            creditLimit: 10_000,
            tintHex: nil,
            openedAt: may1,
            context: context
        )

        _ = try ManualTransactionService.create(
            account: card,
            date: apr15,
            description: "Pre-opening charge",
            signedAmount: -1_000,
            category: nil,
            context: context
        )

        let balance = AccountBalanceResolver.currentBalance(account: card, context: context)
        #expect(balance == 0, "Transaction before openedAt should not affect balance, got \(balance)")
    }

    private func dateFromComponents(year: Int, month: Int, day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    private func mirror(for snapshot: AccountBalanceSnapshot, context: ModelContext) throws -> Transaction {
        let id = snapshot.id
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate<Transaction> { $0.id == id }
        )
        return try #require(try context.fetch(descriptor).first)
    }
}
