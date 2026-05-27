import Testing
import Foundation
import SwiftData
@testable import FinanceTracker

@Suite("SPEI Destination Rules")
struct SPEIDestinationRulesTests {

    private func makeTransaction(description: String, amount: Decimal = -5000) -> Transaction {
        Transaction(
            postedAt: Date(),
            amount: amount,
            descriptionRaw: description
        )
    }

    private func makeRules() -> [CategoryRule] {
        let parent = FinanceTracker.Category(name: "Transfers", kind: .transfer)
        let toOwn = FinanceTracker.Category(name: "To Own Accounts", parent: parent, kind: .transfer)
        let ccPay = FinanceTracker.Category(name: "Credit Card Payments", parent: parent, kind: .transfer)
        return [
            CategoryRule(patternRegex: "(?i)SPEI enviada a Priority.*BANAMEX", category: toOwn, priority: 87),
            CategoryRule(patternRegex: "(?i)SPEI enviada a 2now.*HSBC", category: ccPay, priority: 87),
            CategoryRule(patternRegex: "(?i)SPEI enviada a Nu.*NU MEXICO", category: toOwn, priority: 87),
            CategoryRule(patternRegex: "(?i)SPEI enviada a TDC Explora", category: ccPay, priority: 87),
            CategoryRule(patternRegex: "(?i)SPEI enviada a.*INVEX Volaris", category: ccPay, priority: 87),
            CategoryRule(patternRegex: "(?i)SPEI enviada a BBVA 2855", category: toOwn, priority: 87),
            CategoryRule(patternRegex: "(?i)SPEI enviada a Explora.*BANAMEX", category: ccPay, priority: 87),
            CategoryRule(patternRegex: "(?i)SPEI enviada a Moneypool", category: toOwn, priority: 87),
        ]
    }

    @Test("SPEI to 2now categorized as Credit Card Payment")
    func testSpeiTo2now() {
        let rules = makeRules()
        let tx = makeTransaction(description: "SPEI enviada a 2now 3803, HSBC, 2026010240169176737337285")
        _ = Categorizer.categorize(transactions: [tx], rules: rules)

        #expect(tx.category?.name == "Credit Card Payments")
        #expect(tx.category?.parent?.name == "Transfers")
        #expect(tx.category?.kind == .transfer)
    }

    @Test("SPEI to Priority categorized as To Own Accounts")
    func testSpeiToPriority() {
        let rules = makeRules()
        let tx = makeTransaction(description: "SPEI enviada a Priority0728, BANAMEX, 20260309001")
        _ = Categorizer.categorize(transactions: [tx], rules: rules)

        #expect(tx.category?.name == "To Own Accounts")
        #expect(tx.category?.parent?.name == "Transfers")
        #expect(tx.category?.kind == .transfer)
    }

    @Test("SPEI to Nu categorized as To Own Accounts")
    func testSpeiToNu() {
        let rules = makeRules()
        let tx = makeTransaction(description: "SPEI enviada a Nu 7328, NU MEXICO, 20260103001")
        _ = Categorizer.categorize(transactions: [tx], rules: rules)

        #expect(tx.category?.name == "To Own Accounts")
        #expect(tx.category?.kind == .transfer)
    }

    @Test("SPEI to INVEX Volaris categorized as Credit Card Payment")
    func testSpeiToVolaris() {
        let rules = makeRules()
        let tx = makeTransaction(description: "SPEI enviada a INVEX Volaris 0 6330, INVEX, 20260415001")
        _ = Categorizer.categorize(transactions: [tx], rules: rules)

        #expect(tx.category?.name == "Credit Card Payments")
        #expect(tx.category?.kind == .transfer)
    }

    @Test("All transfer subcategories excluded from cash flow")
    @MainActor
    func testTransferSubcategoriesExcluded() async throws {
        let schema = Schema([Account.self, AccountBalanceSnapshot.self, Transaction.self, Statement.self, FinanceTracker.Category.self, CategoryRule.self, InstallmentPlan.self, PendingImport.self, SignRecoveryHint.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = container.mainContext

        let transferParent = FinanceTracker.Category(name: "Transfers", kind: .transfer)
        let toOwn = FinanceTracker.Category(name: "To Own Accounts", parent: transferParent, kind: .transfer)
        let ccPay = FinanceTracker.Category(name: "Credit Card Payments", parent: transferParent, kind: .transfer)
        let internalTx = FinanceTracker.Category(name: "Internal Transfer", parent: transferParent, kind: .transfer)
        let expenseCategory = FinanceTracker.Category(name: "Restaurants", kind: .expense)
        context.insert(transferParent)
        context.insert(toOwn)
        context.insert(ccPay)
        context.insert(internalTx)
        context.insert(expenseCategory)

        let account = Account(institution: "Test", type: .checking)
        context.insert(account)

        context.insert(Transaction(account: account, postedAt: Date(), amount: -5000, descriptionRaw: "SPEI to own", category: toOwn))
        context.insert(Transaction(account: account, postedAt: Date(), amount: -2000, descriptionRaw: "CC payment", category: ccPay))
        context.insert(Transaction(account: account, postedAt: Date(), amount: -1000, descriptionRaw: "Internal", category: internalTx))
        context.insert(Transaction(account: account, postedAt: Date(), amount: -100, descriptionRaw: "Lunch", category: expenseCategory))
        try context.save()

        let allTxns = try context.fetch(FetchDescriptor<Transaction>())

        var totalIncome: Decimal = 0
        var totalExpenses: Decimal = 0
        for tx in allTxns {
            if tx.category?.kind == .transfer { continue }
            if tx.amount > 0 {
                totalIncome += tx.amount
            } else {
                totalExpenses += tx.amount
            }
        }

        #expect(totalIncome == 0, "No income in test data")
        #expect(totalExpenses == -100, "Only the expense should count, not transfers")
    }

    @Test("Unknown SPEI destination falls to Uncategorized")
    func testUnknownSpeiUncategorized() {
        let rules = makeRules()
        let tx = makeTransaction(description: "SPEI enviada a SomeNewBank 1234, UNKNOWN, 20260501001")
        _ = Categorizer.categorize(transactions: [tx], rules: rules)

        #expect(tx.category == nil)
    }
}
