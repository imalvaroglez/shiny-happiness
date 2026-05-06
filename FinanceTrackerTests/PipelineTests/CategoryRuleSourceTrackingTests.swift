import Testing
import Foundation
@testable import FinanceTracker

@Suite("CategoryRule Source Tracking")
struct CategoryRuleSourceTrackingTests {

    @Test("Seed rules have source=seed")
    func testSeedRuleSource() {
        let rules = CategoryRule.loadSeedRulesFromBundle()
        #expect(!rules.isEmpty, "Should load at least one seed rule from bundle")
        #expect(rules.allSatisfy { $0.source == "seed" }, "All seed rules should have source='seed'")
    }

    @Test("Seed rules have matchCount=0")
    func testSeedRuleMatchCountZero() {
        let rules = CategoryRule.loadSeedRulesFromBundle()
        #expect(rules.allSatisfy { $0.matchCount == 0 }, "Seed rules should start with matchCount=0")
    }

    @Test("matchCount increments on categorize")
    func testMatchCountIncrements() {
        let category = Category(name: "Transport", kind: .expense)
        let rule = CategoryRule(
            patternRegex: "(?i)UBER",
            merchantMatch: "Uber",
            category: category,
            priority: 10,
            source: "seed"
        )

        let transactions = [
            Transaction(postedAt: Date(), amount: -100, descriptionRaw: "UBER TRIP 123"),
            Transaction(postedAt: Date(), amount: -50, descriptionRaw: "UBER EATS"),
            Transaction(postedAt: Date(), amount: -75, descriptionRaw: "UBER TRIP 456"),
        ]

        let result = Categorizer.categorize(transactions: transactions, rules: [rule])

        #expect(result.matchedRules[rule.id] == 3, "Rule should have matched 3 times")
        #expect(result.categorized == 3)
    }

    @Test("User correction rule has source=user_correction")
    func testUserCorrectionSource() {
        let category = Category(name: "Entertainment", kind: .expense)
        let rule = CategoryRule(
            patternRegex: "(?i)CINEPOLIS",
            merchantMatch: "",
            category: category,
            priority: 100,
            source: "user_correction",
            createdFrom: "CINEPOLIS0677 000000000 DF"
        )

        #expect(rule.source == "user_correction")
        #expect(rule.priority == 100)
        #expect(rule.createdFrom == "CINEPOLIS0677 000000000 DF")
    }

    @Test("User correction rule takes priority over seed")
    func testUserRulePriority() {
        let seedCategory = Category(name: "Rideshare", kind: .expense)
        let userCategory = Category(name: "Food", kind: .expense)

        let seedRule = CategoryRule(
            patternRegex: "(?i)UBER",
            merchantMatch: "Uber",
            category: seedCategory,
            priority: 10,
            source: "seed"
        )
        let userRule = CategoryRule(
            patternRegex: "(?i)UBER\\s*EATS",
            merchantMatch: "Uber Eats",
            category: userCategory,
            priority: 100,
            source: "user_correction"
        )

        let eatsTx = Transaction(postedAt: Date(), amount: -200, descriptionRaw: "UBER EATS ORDER")
        let tripTx = Transaction(postedAt: Date(), amount: -100, descriptionRaw: "UBER TRIP 789")

        let result = Categorizer.categorize(transactions: [eatsTx, tripTx], rules: [seedRule, userRule])

        #expect(eatsTx.category?.name == "Food", "UBER EATS should match user correction rule")
        #expect(tripTx.category?.name == "Rideshare", "UBER TRIP should match seed rule")
        #expect(result.categorized == 2)
    }
}
