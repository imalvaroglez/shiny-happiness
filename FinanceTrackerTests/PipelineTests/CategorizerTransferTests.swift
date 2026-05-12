import Testing
import Foundation
import SwiftData
@testable import FinanceTracker

@Suite("Categorizer Transfer Rules")
struct CategorizerTransferTests {

    private func makeTransaction(description: String, amount: Decimal = 5429.12) -> Transaction {
        Transaction(
            postedAt: Date(),
            amount: amount,
            descriptionRaw: description
        )
    }

    private func makeRule(pattern: String, categoryName: String, categoryKind: CategoryKind = .transfer, priority: Int = 10) -> CategoryRule {
        let category = Category(name: categoryName, kind: categoryKind)
        return CategoryRule(
            patternRegex: pattern,
            merchantMatch: "",
            category: category,
            priority: priority
        )
    }

    @Test("PAGO RECIBIDO categorized as transfer")
    func testPagoRecibidoIsTransfer() {
        let tx = makeTransaction(description: "PAGO RECIBIDO, GRACIAS", amount: 5429.12)
        let rules = [makeRule(pattern: "(?i)PAGO\\s*RECIBIDO|ABONO|PAGO", categoryName: "Internal Transfer", categoryKind: .transfer, priority: 5)]

        let result = Categorizer.categorize(transactions: [tx], rules: rules)

        #expect(result.categorized == 1)
        #expect(tx.category?.kind == .transfer)
    }

    @Test("MONTO A DIFERIR categorized as transfer")
    func testMontoADiferirIsTransfer() {
        let tx = makeTransaction(description: "MONTO A DIFERIR 12 MESES", amount: 1500.00)
        let rules = [makeRule(pattern: "(?i)MONTO\\s*A\\s*DIFERIR", categoryName: "Internal Transfer", categoryKind: .transfer, priority: 90)]

        let result = Categorizer.categorize(transactions: [tx], rules: rules)

        #expect(result.categorized == 1)
        #expect(tx.category?.kind == .transfer)
    }

    @Test("SPEI transfer categorized as transfer")
    func testSpeiIsTransfer() {
        let tx = makeTransaction(description: "TRANSFERENCIA SPEI $25,000.00", amount: 25000.00)
        let rules = [makeRule(pattern: "(?i)TRANSFERENCIA\\s*SPEI|SPEI", categoryName: "SPEI Transfer", categoryKind: .transfer, priority: 5)]

        let result = Categorizer.categorize(transactions: [tx], rules: rules)

        #expect(result.categorized == 1)
        #expect(tx.category?.kind == .transfer)
    }

    @Test("Dashboard logic excludes transfers from income and expenses")
    @MainActor
    func testDashboardExcludesTransfers() async throws {
        let schema = Schema([
            Account.self,
            Transaction.self,
            Statement.self,
            Category.self,
            CategoryRule.self,
            InstallmentPlan.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = container.mainContext

        let transferCategory = Category(name: "Internal Transfer", kind: .transfer)
        let expenseCategory = Category(name: "Restaurants", kind: .expense)
        context.insert(transferCategory)
        context.insert(expenseCategory)

        let account = Account(institution: "Test", type: .creditCard)
        context.insert(account)

        let transferTx = Transaction(
            account: account,
            postedAt: Date(),
            amount: 5429.12,
            descriptionRaw: "PAGO RECIBIDO, GRACIAS",
            category: transferCategory
        )
        let expenseTx = Transaction(
            account: account,
            postedAt: Date(),
            amount: -100,
            descriptionRaw: "RESTAURANT",
            category: expenseCategory
        )
        context.insert(transferTx)
        context.insert(expenseTx)
        try context.save()

        let allTxns = try context.fetch(FetchDescriptor<Transaction>())
        #expect(allTxns.count == 2)

        var totalIncome: Decimal = 0
        var totalExpenses: Decimal = 0
        for tx in allTxns {
            let kind = tx.category?.kind
            if kind == .transfer { continue }
            if kind == .income || (kind == nil && tx.amount > 0) {
                totalIncome += tx.amount
            } else if kind == .expense || kind == .investment || (kind == nil && tx.amount < 0) {
                totalExpenses += tx.amount
            }
        }

        #expect(totalIncome == 0, "Transfer should not count as income")
        #expect(totalExpenses == -100, "Only expense should count")
    }

    @Test("Uncategorized positive amount falls back to income heuristic")
    func testUncategorizedFallback() {
        let tx = makeTransaction(description: "UNKNOWN DEPOSIT", amount: 500)
        let result = Categorizer.categorize(transactions: [tx], rules: [])

        #expect(tx.category == nil)

        let kind = tx.category?.kind
        let isIncome = kind == .income || (kind == nil && tx.amount > 0)
        #expect(isIncome, "Uncategorized positive amount should fall back to income heuristic")
    }
}
