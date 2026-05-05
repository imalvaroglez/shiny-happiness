import Foundation

struct Categorizer {
    struct Result {
        let categorized: Int
        let uncategorized: Int
    }

    static func categorize(
        transactions: [Transaction],
        rules: [CategoryRule]
    ) -> Result {
        let sortedRules = rules.sorted { $0.priority > $1.priority }

        var categorized = 0
        var uncategorized = 0

        for tx in transactions {
            var matched = false
            for rule in sortedRules {
                if matchesRule(tx, rule) {
                    tx.category = rule.category
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

        return Result(categorized: categorized, uncategorized: uncategorized)
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
