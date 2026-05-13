import Foundation
import SwiftData

@Model
final class CategoryRule: LastModifiedTracking {
    var id: UUID
    var patternRegex: String
    var merchantMatch: String
    @Relationship(deleteRule: .nullify) var category: Category?
    var priority: Int
    var source: String
    var matchCount: Int
    var createdFrom: String?
    var lastModifiedAt: Date = Date.now

    init(
        id: UUID = UUID(),
        patternRegex: String,
        merchantMatch: String = "",
        category: Category? = nil,
        priority: Int = 0,
        source: String = "seed",
        matchCount: Int = 0,
        createdFrom: String? = nil
    ) {
        self.id = id
        self.patternRegex = patternRegex
        self.merchantMatch = merchantMatch
        self.category = category
        self.priority = priority
        self.source = source
        self.matchCount = matchCount
        self.createdFrom = createdFrom
    }

    static func loadSeedRulesFromBundle() -> [CategoryRule] {
        guard let url = Bundle.main.url(forResource: "category_rules", withExtension: "json") else {
            return []
        }
        guard let data = try? Data(contentsOf: url) else { return [] }

        struct RuleJSON: Codable {
            let pattern: String
            let merchant: String
            let category: String
            let priority: Int
        }
        struct RuleFile: Codable {
            let rules: [RuleJSON]
        }

        guard let seed = try? JSONDecoder().decode(RuleFile.self, from: data) else { return [] }

        return seed.rules.map { json in
            CategoryRule(
                patternRegex: json.pattern,
                merchantMatch: json.merchant,
                priority: json.priority,
                source: "seed"
            )
        }
    }
}
