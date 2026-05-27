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
        let context = try makeContainer().mainContext

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
        #expect(checking.manuallyCreatedAt != nil)
        #expect(card.manuallyCreatedAt != nil)
        #expect(card.creditLimit == 10_000)
        #expect(snapshots.first { $0.account?.id == checking.id }?.amount == 1_500)
        #expect(snapshots.first { $0.account?.id == card.id }?.amount == -900)
    }

    @Test("Balance resolver uses latest anchor plus later transactions")
    func balanceResolverRollsForwardLatestAnchor() throws {
        let context = try makeContainer().mainContext
        let account = try AccountCreationService.create(
            kind: .debit,
            name: "Debit",
            institution: "Bank",
            accountNumber: nil,
            currency: "MXN",
            openingAmount: 1_000,
            creditLimit: nil,
            tintHex: nil,
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

    @Test("Manual transfer creates linked outflow and inflow")
    func manualTransferCreatesLinkedPair() throws {
        let context = try makeContainer().mainContext
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
        #expect(pair.inflow.category?.kind == .transfer)
    }

    @Test("Debit income creates positive transaction")
    func debitIncomeCreatesPositive() throws {
        let context = try makeContainer().mainContext
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
        let context = try makeContainer().mainContext
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
        let context = try makeContainer().mainContext
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
        let context = try makeContainer().mainContext
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
        let context = try makeContainer().mainContext
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
        let context = try makeContainer().mainContext
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
        let context = try makeContainer().mainContext
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
}
