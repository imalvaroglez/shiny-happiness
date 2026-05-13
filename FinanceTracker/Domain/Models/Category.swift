import Foundation
import SwiftData

@Model
final class Category: LastModifiedTracking {
    var id: UUID
    var name: String
    @Relationship(deleteRule: .nullify) var parent: Category?
    var kind: CategoryKind
    @Relationship(deleteRule: .cascade) var subcategories: [Category] = []
    var lastModifiedAt: Date = Date.now

    init(
        id: UUID = UUID(),
        name: String,
        parent: Category? = nil,
        kind: CategoryKind = .expense
    ) {
        self.id = id
        self.name = name
        self.parent = parent
        self.kind = kind
    }
}
