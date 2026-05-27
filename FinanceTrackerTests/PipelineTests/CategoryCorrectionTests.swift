import Testing
import Foundation
import SwiftData
@testable import FinanceTracker

@Suite("Category Correction")
@MainActor
struct CategoryCorrectionTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            Account.self, AccountBalanceSnapshot.self, Transaction.self,
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

    @Test("User correction creates rule and applies retroactively")
    func testCorrectionCreatesRule() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let entertainment = Category(name: "Entertainment", kind: .expense)
        context.insert(entertainment)
        try context.save()

        let descriptions = [
            "CINEPOLIS0677 000000000 DF",
            "CINEPOLIS0678 000000001 DF",
            "CINEPOLIS0679 000000002 DF",
            "CINEPOLIS0680 000000003 DF",
            "CINEPOLIS0681 000000004 DF",
        ]
        var transactions: [Transaction] = []
        for desc in descriptions {
            let tx = Transaction(postedAt: Date(), amount: -150, descriptionRaw: desc)
            context.insert(tx)
            transactions.append(tx)
        }
        try context.save()

        let keyword = MerchantExtractor.extractMerchant(from: transactions[0].descriptionRaw)
        #expect(keyword == "CINEPOLIS")

        let rule = CategoryRule(
            patternRegex: "(?i)\(keyword!)",
            category: entertainment,
            priority: 100,
            source: "user_correction",
            createdFrom: transactions[0].descriptionRaw
        )
        context.insert(rule)

        let allTxns = try context.fetch(FetchDescriptor<Transaction>())
        let allRules = try context.fetch(FetchDescriptor<CategoryRule>())
        let result = Categorizer.categorize(transactions: allTxns, rules: allRules)

        #expect(result.categorized == 5, "All 5 CINEPOLIS transactions should be categorized")
        for tx in allTxns {
            #expect(tx.category?.name == "Entertainment", "Transaction '\(tx.descriptionRaw)' should be Entertainment")
        }

        let savedRules = try context.fetch(FetchDescriptor<CategoryRule>())
        #expect(savedRules.count == 1)
        #expect(savedRules[0].source == "user_correction")
        #expect(savedRules[0].createdFrom == transactions[0].descriptionRaw)
    }

    @Test("Just this one applies category without creating rule")
    func testJustThisOne() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let food = Category(name: "Food", kind: .expense)
        context.insert(food)

        let tx1 = Transaction(postedAt: Date(), amount: -100, descriptionRaw: "CINEPOLIS0677 000000000 DF")
        let tx2 = Transaction(postedAt: Date(), amount: -100, descriptionRaw: "CINEPOLIS0678 000000001 DF")
        context.insert(tx1)
        context.insert(tx2)
        try context.save()

        tx1.category = food
        try context.save()

        #expect(tx1.category?.name == "Food")
        #expect(tx2.category == nil)

        let rules = try context.fetch(FetchDescriptor<CategoryRule>())
        #expect(rules.isEmpty, "No rules should be created for 'just this one'")
    }
}
