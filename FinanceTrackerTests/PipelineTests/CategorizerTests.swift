import Testing
import Foundation
@testable import FinanceTracker

@Suite("Categorizer")
struct CategorizerTests {

    private func makeTransaction(description: String) -> Transaction {
        Transaction(
            postedAt: Date(),
            amount: -100,
            descriptionRaw: description
        )
    }

    private func makeRule(pattern: String, categoryName: String, priority: Int = 10) -> CategoryRule {
        let category = Category(name: categoryName)
        return CategoryRule(
            patternRegex: pattern,
            merchantMatch: "",
            category: category,
            priority: priority
        )
    }

    @Test("Matches transaction to category by regex")
    func matchesByRegex() {
        let tx = makeTransaction(description: "UBER *TRIP 12345")
        let rules = [makeRule(pattern: "(?i)UBER", categoryName: "Transport")]

        let result = Categorizer.categorize(transactions: [tx], rules: rules)

        #expect(result.categorized == 1)
        #expect(result.uncategorized == 0)
        #expect(tx.category?.name == "Transport")
    }

    @Test("Higher priority rule wins")
    func higherPriorityWins() {
        let tx = makeTransaction(description: "Pago recibido SPEI")

        let rules = [
            makeRule(pattern: "(?i)SPEI", categoryName: "Transfer", priority: 5),
            makeRule(pattern: "(?i)PAGO", categoryName: "Payment", priority: 10),
        ]

        let result = Categorizer.categorize(transactions: [tx], rules: rules)

        #expect(result.categorized == 1)
        #expect(tx.category?.name == "Payment")
    }

    @Test("Uncategorized when no rules match")
    func noMatchUncategorized() {
        let tx = makeTransaction(description: "Some random merchant XYZ")
        let rules = [makeRule(pattern: "(?i)UBER", categoryName: "Transport")]

        let result = Categorizer.categorize(transactions: [tx], rules: rules)

        #expect(result.categorized == 0)
        #expect(result.uncategorized == 1)
        #expect(tx.category == nil)
    }

    @Test("Matches multiple transactions against rules")
    func multipleTransactions() {
        let transactions = [
            makeTransaction(description: "UBER *TRIP 123"),
            makeTransaction(description: "OXXO STORE 456"),
            makeTransaction(description: "Unknown purchase"),
        ]

        let rules = [
            makeRule(pattern: "(?i)UBER", categoryName: "Transport"),
            makeRule(pattern: "(?i)OXXO", categoryName: "Shopping"),
        ]

        let result = Categorizer.categorize(transactions: transactions, rules: rules)

        #expect(result.categorized == 2)
        #expect(result.uncategorized == 1)
        #expect(transactions[0].category?.name == "Transport")
        #expect(transactions[1].category?.name == "Shopping")
        #expect(transactions[2].category == nil)
    }

    @Test("Case insensitive matching")
    func caseInsensitive() {
        let tx = makeTransaction(description: "netflix subscription")
        let rules = [makeRule(pattern: "(?i)NETFLIX", categoryName: "Streaming")]

        let result = Categorizer.categorize(transactions: [tx], rules: rules)

        #expect(result.categorized == 1)
        #expect(tx.category?.name == "Streaming")
    }

    @Test("Empty rules leaves all uncategorized")
    func emptyRules() {
        let transactions = [
            makeTransaction(description: "UBER"),
            makeTransaction(description: "OXXO"),
        ]

        let result = Categorizer.categorize(transactions: transactions, rules: [])

        #expect(result.categorized == 0)
        #expect(result.uncategorized == 2)
    }
}
