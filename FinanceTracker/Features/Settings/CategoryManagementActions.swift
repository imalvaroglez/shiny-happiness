import Foundation
import SwiftData

enum CategoryManagementError: LocalizedError {
    case emptyName
    case duplicateName
    case parentHasActiveChildren
    case missingParent

    var errorDescription: String? {
        switch self {
        case .emptyName: return "Category name cannot be empty."
        case .duplicateName: return "A category with this name already exists."
        case .parentHasActiveChildren: return "Cannot delete a parent category that has subcategories."
        case .missingParent: return "Parent category is required for subcategory operations."
        }
    }
}

@MainActor
struct CategoryManagementActions {

    static func activeCategories(context: ModelContext) throws -> [Category] {
        let descriptor = FetchDescriptor<Category>(
            predicate: #Predicate<Category> { $0.deletedAt == nil }
        )
        return try context.fetch(descriptor)
    }

    static func createParent(name: String, kind: CategoryKind, context: ModelContext) throws -> Category {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw CategoryManagementError.emptyName }
        guard !isDuplicate(name: trimmed, kind: kind, parent: nil, context: context) else {
            throw CategoryManagementError.duplicateName
        }
        let category = Category(name: trimmed, kind: kind)
        context.insert(category)
        try context.save()
        return category
    }

    static func createSubcategory(parent: Category, name: String, context: ModelContext) throws -> Category {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw CategoryManagementError.emptyName }
        guard !isDuplicate(name: trimmed, kind: parent.kind, parent: parent, context: context) else {
            throw CategoryManagementError.duplicateName
        }
        let category = Category(name: trimmed, parent: parent, kind: parent.kind)
        context.insert(category)
        try context.save()
        return category
    }

    static func deleteSubcategory(_ subcategory: Category, context: ModelContext) throws {
        guard let parent = subcategory.parent else { throw CategoryManagementError.missingParent }
        let subcategoryId = subcategory.id

        let allTransactions = try context.fetch(FetchDescriptor<Transaction>())
        for tx in allTransactions where tx.category?.id == subcategoryId { tx.category = parent }

        let allRules = try context.fetch(FetchDescriptor<CategoryRule>())
        for rule in allRules where rule.category?.id == subcategoryId { rule.category = parent }

        subcategory.deletedAt = Date.now
        try context.save()
    }

    static func deleteParent(_ parent: Category, context: ModelContext) throws {
        let activeChildren = try activeCategories(context: context)
            .filter { $0.parent?.id == parent.id }
        guard activeChildren.isEmpty else { throw CategoryManagementError.parentHasActiveChildren }
        let parentId = parent.id

        let allTransactions = try context.fetch(FetchDescriptor<Transaction>())
        for tx in allTransactions where tx.category?.id == parentId { tx.category = nil }

        let allRules = try context.fetch(FetchDescriptor<CategoryRule>())
        for rule in allRules where rule.category?.id == parentId { rule.category = nil }

        parent.deletedAt = Date.now
        try context.save()
    }

    static func isDuplicate(name: String, kind: CategoryKind, parent: Category?, context: ModelContext) -> Bool {
        guard let active = try? activeCategories(context: context) else { return false }
        if let parent {
            return active.contains { $0.parent?.id == parent.id && $0.name == name }
        } else {
            return active.contains { $0.parent == nil && $0.name == name && $0.kind == kind }
        }
    }
}
