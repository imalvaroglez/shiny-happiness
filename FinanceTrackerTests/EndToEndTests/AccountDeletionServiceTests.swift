import Testing
import Foundation
import SwiftData
@testable import FinanceTracker

@Suite("Account Deletion Service")
@MainActor
struct AccountDeletionServiceTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            Account.self,
            Transaction.self,
            Statement.self,
            Category.self,
            CategoryRule.self,
            InstallmentPlan.self,
            PendingImport.self,
            SignRecoveryHint.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    @Test("Deleting an account removes linked statements, transactions, pending imports, and installment plans")
    func testCascadeDeletion() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let account = Account(institution: "Test Bank", type: .creditCard, currency: "MXN", nickname: "Card A")
        context.insert(account)

        let statement = Statement(
            account: account,
            periodStart: .now,
            periodEnd: .now,
            sourceFileHash: "test",
            closingBalance: -5000
        )
        context.insert(statement)

        let tx1 = Transaction(postedAt: .now, amount: -100, descriptionRaw: "STORE 1")
        tx1.account = account
        tx1.statement = statement
        context.insert(tx1)

        let tx2 = Transaction(postedAt: .now, amount: -200, descriptionRaw: "STORE 2")
        tx2.account = account
        tx2.statement = statement
        context.insert(tx2)

        let plan = InstallmentPlan(
            account: account,
            originalPurchase: tx1,
            originalAmount: 1200,
            totalMonths: 12,
            currentMonth: 3,
            monthlyAmount: 100,
            firstChargeDate: .now,
            merchantDescription: "STORE 1 MSI"
        )
        context.insert(plan)

        let pending = PendingImport(
            account: account,
            statement: statement,
            rawText: "UNPARSEABLE LINE",
            reason: "Could not detect amount"
        )
        context.insert(pending)

        try context.save()

        let preview = AccountDeletionService.preview(account: account, context: context)
        #expect(preview.statementCount == 1)
        #expect(preview.transactionCount == 2)
        #expect(preview.pendingImportCount == 1)
        #expect(preview.installmentPlanCount == 1)

        try AccountDeletionService.delete(account: account, context: context)

        #expect(try context.fetch(FetchDescriptor<Account>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<Statement>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<Transaction>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<InstallmentPlan>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<PendingImport>()).isEmpty)
    }

    @Test("Deleting an account does not delete unrelated accounts or transactions")
    func testIsolation() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let accountA = Account(institution: "Bank A", type: .creditCard, currency: "MXN", nickname: "Card A")
        let accountB = Account(institution: "Bank B", type: .checking, currency: "MXN", nickname: "Checking B")
        context.insert(accountA)
        context.insert(accountB)

        let txA = Transaction(postedAt: .now, amount: -100, descriptionRaw: "STORE A")
        txA.account = accountA
        context.insert(txA)

        let txB = Transaction(postedAt: .now, amount: 500, descriptionRaw: "SALARY")
        txB.account = accountB
        context.insert(txB)

        try context.save()

        try AccountDeletionService.delete(account: accountA, context: context)

        let remainingAccounts = try context.fetch(FetchDescriptor<Account>())
        #expect(remainingAccounts.count == 1)
        #expect(remainingAccounts[0].id == accountB.id)

        let remainingTx = try context.fetch(FetchDescriptor<Transaction>())
        #expect(remainingTx.count == 1)
        #expect(remainingTx[0].id == txB.id)
    }

    @Test("Pending import linked by statement is deleted")
    func testPendingImportByStatement() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let account = Account(institution: "Bank", type: .creditCard, currency: "MXN", nickname: "Card")
        context.insert(account)

        let statement = Statement(
            account: account,
            periodStart: .now,
            periodEnd: .now,
            sourceFileHash: "test",
            closingBalance: -1000
        )
        context.insert(statement)

        let pending = PendingImport(
            account: account,
            statement: statement,
            rawText: "BAD LINE",
            reason: "No amount"
        )
        context.insert(pending)

        try context.save()

        try AccountDeletionService.delete(account: account, context: context)
        #expect(try context.fetch(FetchDescriptor<PendingImport>()).isEmpty)
    }

    @Test("Pending import linked by resolved transaction is deleted")
    func testPendingImportByResolvedTransaction() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let account = Account(institution: "Bank", type: .creditCard, currency: "MXN", nickname: "Card")
        context.insert(account)

        let tx = Transaction(postedAt: .now, amount: -100, descriptionRaw: "STORE")
        tx.account = account
        context.insert(tx)

        let pending = PendingImport(
            account: account,
            rawText: "PENDING",
            reason: "Test",
            resolvedTransaction: tx
        )
        context.insert(pending)

        try context.save()

        try AccountDeletionService.delete(account: account, context: context)
        #expect(try context.fetch(FetchDescriptor<PendingImport>()).isEmpty)
    }

    @Test("Installment plan linked by original purchase is deleted")
    func testInstallmentByPurchase() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let account = Account(institution: "Bank", type: .creditCard, currency: "MXN", nickname: "Card")
        context.insert(account)

        let tx = Transaction(postedAt: .now, amount: -1200, descriptionRaw: "STORE MSI")
        tx.account = account
        context.insert(tx)

        let plan = InstallmentPlan(
            account: account,
            originalPurchase: tx,
            originalAmount: 1200,
            totalMonths: 12,
            currentMonth: 1,
            monthlyAmount: 100,
            firstChargeDate: .now,
            merchantDescription: "STORE MSI"
        )
        context.insert(plan)

        try context.save()

        try AccountDeletionService.delete(account: account, context: context)
        #expect(try context.fetch(FetchDescriptor<InstallmentPlan>()).isEmpty)
    }

    @Test("Preview counts match actual deletion counts")
    func testPreviewAccuracy() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let account = Account(institution: "Bank", type: .creditCard, currency: "MXN", nickname: "Card")
        context.insert(account)

        let statement = Statement(
            account: account,
            periodStart: .now,
            periodEnd: .now,
            sourceFileHash: "test",
            closingBalance: -3000
        )
        context.insert(statement)

        for i in 0..<3 {
            let tx = Transaction(postedAt: .now, amount: Decimal(-100 - i * 100), descriptionRaw: "TX \(i)")
            tx.account = account
            tx.statement = statement
            context.insert(tx)
        }

        try context.save()

        let preview = AccountDeletionService.preview(account: account, context: context)
        #expect(preview.statementCount == 1)
        #expect(preview.transactionCount == 3)
        #expect(preview.pendingImportCount == 0)
        #expect(preview.installmentPlanCount == 0)

        try AccountDeletionService.delete(account: account, context: context)

        #expect(try context.fetch(FetchDescriptor<Account>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<Statement>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<Transaction>()).isEmpty)
    }
}
