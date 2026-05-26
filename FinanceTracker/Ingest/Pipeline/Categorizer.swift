import Foundation

struct Categorizer {
    struct Result {
        let categorized: Int
        let uncategorized: Int
        let matchedRules: [UUID: Int]
    }

    static func categorize(
        transactions: [Transaction],
        rules: [CategoryRule]
    ) -> Result {
        let sortedRules = rules.filter { rule in
            guard let category = rule.category else { return false }
            return category.deletedAt == nil
        }.sorted { $0.priority > $1.priority }

        var categorized = 0
        var uncategorized = 0
        var matchedRules: [UUID: Int] = [:]

        for tx in transactions {
            var matched = false
            for rule in sortedRules {
                if matchesRule(tx, rule) {
                    tx.category = rule.category
                    matchedRules[rule.id, default: 0] += 1
                    matched = true
                    break
                }
            }
            if matched {
                categorized += 1
            } else {
                uncategorized += 1
            }
        }

        return Result(categorized: categorized, uncategorized: uncategorized, matchedRules: matchedRules)
    }

    static func matchesRule(_ tx: Transaction, _ rule: CategoryRule) -> Bool {
        guard let regex = try? NSRegularExpression(
            pattern: rule.patternRegex,
            options: .caseInsensitive
        ) else {
            return false
        }
        let range = NSRange(tx.descriptionRaw.startIndex..., in: tx.descriptionRaw)
        return regex.firstMatch(in: tx.descriptionRaw, range: range) != nil
    }
}
