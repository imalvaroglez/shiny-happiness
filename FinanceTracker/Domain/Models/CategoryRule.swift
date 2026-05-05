import Foundation
import SwiftData

@Model
final class CategoryRule {
    var id: UUID
    var patternRegex: String
    var merchantMatch: String
    @Relationship(deleteRule: .nullify) var category: Category?
    var priority: Int

    init(
        id: UUID = UUID(),
        patternRegex: String,
        merchantMatch: String = "",
        category: Category? = nil,
        priority: Int = 0
    ) {
        self.id = id
        self.patternRegex = patternRegex
        self.merchantMatch = merchantMatch
        self.category = category
        self.priority = priority
    }
}
