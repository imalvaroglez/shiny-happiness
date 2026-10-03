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

    /// Renombra sin perder vínculos (transacciones y reglas van por relación/id).
    /// Si la categoría provenía del seed, registra su nombre original en el
    /// store de personalización para que el bootstrap de cada arranque NO la
    /// resucite como duplicado.
    @discardableResult
    static func rename(_ category: Category, to newName: String, context: ModelContext,
                       customizationURL: URL? = nil,
                       saveContext: ((ModelContext) throws -> Void)? = nil) throws -> Category {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CategoryManagementError.emptyName }
        guard trimmed != category.name else { return category }
        let normalized = trimmed.lowercased()
        let duplicates = try activeCategories(context: context).contains {
            $0.id != category.id && $0.parent?.id == category.parent?.id && $0.kind == category.kind
                && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
        }
        guard !duplicates else { throw CategoryManagementError.duplicateName }
        let url = try customizationURL ?? CategoryCustomizationStore.defaultURL()
        let catalog = try CategoryCustomizationStore.read(fileURL: url)
        let origin = try SeedDataLoader.seedOrigin(for: category, customizations: catalog.entries)
        let files = try SidecarFileTransaction(urls: [url])
        let hadPendingChanges = context.hasChanges
        let previousName = category.name
        let previousModified = category.lastModifiedAt
        let autosave = context.autosaveEnabled
        context.autosaveEnabled = false
        defer { context.autosaveEnabled = autosave }
        do {
            if let origin {
                try CategoryCustomizationStore.setSeedName(categoryID: category.id, seedName: origin.name,
                    parentName: origin.parentName, kindRaw: origin.kindRaw, at: files.stagedURL(for: url), notify: false)
            }
            category.name = trimmed
            category.touch()
            if origin != nil { try files.publish(url) }
            if let saveContext { try saveContext(context) } else { try context.save() }
            files.discard()
            CategoryCustomizationState.shared.refresh(fileURL: url)
            NotificationCenter.default.post(name: CategoryCustomizationStore.didChangeNotification, object: url)
            return category
        } catch {
            category.name = previousName
            category.lastModifiedAt = previousModified
            if !hadPendingChanges { context.rollback() }
            let originalError = error
            do { try files.rollback() }
            catch { throw CategoryCustomizationStore.StoreError.invalid([originalError.localizedDescription, error.localizedDescription]) }
            throw originalError
        }
    }

    static func isDuplicate(name: String, kind: CategoryKind, parent: Category?, context: ModelContext) -> Bool {
        guard let active = try? activeCategories(context: context) else { return false }
        if let parent {
            return active.contains { $0.parent?.id == parent.id && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        } else {
            return active.contains { $0.parent == nil && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() && $0.kind == kind }
        }
    }
}
