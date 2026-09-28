import Foundation
import SwiftData

@Model
final class Category: LastModifiedTracking {
    var id: UUID
    var name: String
    @Relationship(deleteRule: .nullify) var parent: Category?
    var kind: CategoryKind
    @Relationship(deleteRule: .cascade) var subcategories: [Category] = []
    var deletedAt: Date? = nil
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

extension Category {
    var localizedName: String {
        Self.localizedSeedName(name)
    }

    static func localizedSeedName(_ rawName: String) -> String {
        let normalized = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return esMXBundle.localizedString(forKey: "category.\(normalized)", value: rawName, table: "Localizable")
    }

    private static let esMXBundle: Bundle = {
        guard let url = Bundle.main.url(forResource: "es-MX", withExtension: "lproj"),
              let bundle = Bundle(url: url) else { return .main }
        return bundle
    }()
}
