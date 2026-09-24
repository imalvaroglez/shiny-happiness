import Foundation

enum CategoryKindFilter: Hashable, CaseIterable {
    case all
    case income
    case expense
    case transfer
    case investment
    case creditCardPayment

    var kind: CategoryKind? {
        switch self {
        case .all:
            nil
        case .income:
            .income
        case .expense:
            .expense
        case .transfer:
            .transfer
        case .investment:
            .investment
        case .creditCardPayment:
            .creditCardPayment
        }
    }

    var displayName: String {
        switch self {
        case .all:
            "All"
        case .income:
            CategoryKind.income.displayName
        case .expense:
            CategoryKind.expense.displayName
        case .transfer:
            CategoryKind.transfer.displayName
        case .investment:
            CategoryKind.investment.displayName
        case .creditCardPayment:
            CategoryKind.creditCardPayment.displayName
        }
    }
}

struct CategoryManagementTree {
    struct Revision: Equatable {
        let id: UUID
        let parentID: UUID?
        let kind: CategoryKind
        let name: String
        let deletedAt: Date?
    }

    let categories: [Category]
    let parents: [Category]

    private let parentsByID: [UUID: Category]
    private let subcategoriesByParentID: [UUID: [Category]]
    private let subcategoryNamesByParentID: [UUID: Set<String>]

    init(categories: [Category]) {
        let displayCategories = Self.displayCategories(from: categories)
        let parents = displayCategories
            .filter { $0.parent == nil }
            .sorted(by: Self.categoryDisplaySort)

        var childrenByParent: [UUID: [Category]] = [:]
        for category in displayCategories {
            guard let parentID = category.parent?.id else { continue }
            childrenByParent[parentID, default: []].append(category)
        }
        let sortedChildrenByParent = childrenByParent.mapValues {
            $0.sorted(by: Self.categoryDisplaySort)
        }

        self.categories = displayCategories
        self.parents = parents
        self.parentsByID = Dictionary(uniqueKeysWithValues: parents.map { ($0.id, $0) })
        self.subcategoriesByParentID = sortedChildrenByParent
        self.subcategoryNamesByParentID = sortedChildrenByParent.mapValues { Set($0.map(\.name)) }
    }

    var hasCategories: Bool {
        !parents.isEmpty
    }

    static func revision(from categories: [Category]) -> [Revision] {
        categories.map {
            Revision(id: $0.id, parentID: $0.parent?.id, kind: $0.kind, name: $0.name, deletedAt: $0.deletedAt)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    func parent(id: UUID?) -> Category? {
        guard let id else { return nil }
        return parentsByID[id]
    }

    func visibleParents(searchText: String, kindFilter: CategoryKindFilter) -> [Category] {
        let query = Self.normalized(searchText)
        return parents.filter { parent in
            if let kind = kindFilter.kind, parent.kind != kind {
                return false
            }

            guard !query.isEmpty else { return true }

            if Self.normalized(parent.name).contains(query) {
                return true
            }

            return subcategories(for: parent).contains { subcategory in
                Self.normalized(subcategory.name).contains(query)
            }
        }
    }

    func subcategories(for parent: Category) -> [Category] {
        subcategoriesByParentID[parent.id] ?? []
    }

    func resolvedSelectionID(current: UUID?, searchText: String, kindFilter: CategoryKindFilter) -> UUID? {
        let visible = visibleParents(searchText: searchText, kindFilter: kindFilter)
        if let current, visible.contains(where: { $0.id == current }) {
            return current
        }
        return visible.first?.id
    }

    func isDuplicateSubcategoryName(_ name: String, parent: Category) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return subcategoryNamesByParentID[parent.id]?.contains(trimmed) == true
    }

    static func displayCategories(from categories: [Category]) -> [Category] {
        var seen = Set<String>()
        return categories.sorted(by: categoryDisplaySort).filter { category in
            seen.insert(categoryDisplayKey(category)).inserted
        }
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
    }

    private static func categoryDisplayKey(_ category: Category) -> String {
        let parentID = category.parent?.id.uuidString ?? "root"
        let name = normalized(category.name)
        return "\(parentID)|\(category.kind.rawValue)|\(name)"
    }

    private static func categoryDisplaySort(_ lhs: Category, _ rhs: Category) -> Bool {
        let lhsName = normalized(lhs.name)
        let rhsName = normalized(rhs.name)
        if lhsName != rhsName { return lhsName < rhsName }
        if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

extension CategoryKind {
    var displayName: String {
        switch self {
        case .income:
            "Income"
        case .expense:
            "Expense"
        case .transfer:
            "Transfer"
        case .investment:
            "Investment"
        case .creditCardPayment:
            "Credit Card Payment"
        }
    }
}
