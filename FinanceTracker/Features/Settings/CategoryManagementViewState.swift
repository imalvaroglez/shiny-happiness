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
    let categories: [Category]

    init(categories: [Category]) {
        self.categories = Self.displayCategories(from: categories)
    }

    var parents: [Category] {
        categories
            .filter { $0.parent == nil }
            .sorted(by: Self.categoryDisplaySort)
    }

    var hasCategories: Bool {
        !parents.isEmpty
    }

    var selectionSignature: String {
        categories
            .map { category in
                let parentID = category.parent?.id.uuidString ?? "root"
                return "\(category.id.uuidString)|\(parentID)|\(category.kind.rawValue)|\(category.name)"
            }
            .sorted()
            .joined(separator: "\n")
    }

    func parent(id: UUID?) -> Category? {
        guard let id else { return nil }
        return parents.first { $0.id == id }
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
        categories
            .filter { $0.parent?.id == parent.id }
            .sorted(by: Self.categoryDisplaySort)
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
        return subcategories(for: parent).contains { $0.name == trimmed }
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
