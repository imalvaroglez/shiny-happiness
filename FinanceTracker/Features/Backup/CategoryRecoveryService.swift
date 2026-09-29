import Foundation
import SwiftData

@MainActor
enum CategoryRecoveryService {
    struct Preview: Equatable {
        let backupDate: Date
        let categoriesToRestore: Int
        let missingCategories: Int
        let duplicateCategoriesToMerge: Int
        let transactionsToRelink: Int
        let rulesToRelink: Int
        let ambiguousDeletedCategories: [String]
    }

    struct Result: Equatable {
        let categoriesRestored: Int
        let categoriesAdded: Int
        let duplicateCategoriesMerged: Int
        let transactionsRelinked: Int
        let rulesRelinked: Int
    }

    private struct Plan {
        let backupDate: Date
        let canonicalByPath: [String: CategorySnapshot]
        let pathByBackupID: [UUID: String]
    }

    static func preview(backupURL: URL, context: ModelContext) throws -> Preview {
        let plan = try makePlan(backupURL: backupURL)
        let categories = try context.fetch(FetchDescriptor<Category>())
        let transactions = try context.fetch(FetchDescriptor<Transaction>())
        let rules = try context.fetch(FetchDescriptor<CategoryRule>())
        let categoryByID = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
        let pathsByCurrentID = try currentPaths(categories)
        let currentByPath = currentCategoriesByPath(categories, pathsByID: pathsByCurrentID, plan: plan)
        let selectedByPath = selectExistingCategories(plan: plan, categoriesByID: categoryByID, currentByPath: currentByPath)
        let canonicalIDByCurrentID = canonicalCurrentMap(plan: plan, selectedByPath: selectedByPath,
                                                         pathsByCurrentID: pathsByCurrentID)
        let ambiguousPaths = ambiguousDeletions(plan: plan, categories: categories,
            pathsByID: pathsByCurrentID,
            referencedIDs: Set(transactions.compactMap { $0.category?.id } + rules.compactMap { $0.category?.id }))
        return Preview(
            backupDate: plan.backupDate,
            categoriesToRestore: selectedByPath.filter { path, category in
                category.deletedAt != nil && !ambiguousPaths.contains(path)
            }.count,
            missingCategories: plan.canonicalByPath.keys.filter { selectedByPath[$0] == nil }.count,
            duplicateCategoriesToMerge: categories.filter { category in
                category.deletedAt == nil && canonicalIDByCurrentID[category.id].map { $0 != category.id } == true
            }.count,
            transactionsToRelink: transactions.filter { transaction in
                guard let id = transaction.category?.id else { return false }
                return canonicalIDByCurrentID[id].map { $0 != id } == true
            }.count,
            rulesToRelink: rules.filter { rule in
                guard let id = rule.category?.id else { return false }
                return canonicalIDByCurrentID[id].map { $0 != id } == true
            }.count,
            ambiguousDeletedCategories: ambiguousPaths.compactMap { path in
                currentByPath[path]?.sorted { $0.id.uuidString < $1.id.uuidString }.first.map(displayPath)
            }.sorted()
        )
    }

    static func recover(backupURL: URL, context: ModelContext, includeAmbiguousDeletions: Bool = false) throws -> Result {
        let plan = try makePlan(backupURL: backupURL)
        let categories = try context.fetch(FetchDescriptor<Category>())
        let transactions = try context.fetch(FetchDescriptor<Transaction>())
        let rules = try context.fetch(FetchDescriptor<CategoryRule>())
        let categoryByID = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
        let pathsByCurrentID = try currentPaths(categories)
        let currentByPath = currentCategoriesByPath(categories, pathsByID: pathsByCurrentID, plan: plan)
        let selectedByPath = selectExistingCategories(plan: plan, categoriesByID: categoryByID, currentByPath: currentByPath)
        let referencedIDs = Set(transactions.compactMap { $0.category?.id } + rules.compactMap { $0.category?.id })
        let ambiguousPaths = ambiguousDeletions(plan: plan, categories: categories,
            pathsByID: pathsByCurrentID, referencedIDs: referencedIDs)
        var canonicalCategories = selectedByPath
        var restoreParents = Set<String>()
        var restored = 0
        var added = 0
        var merged = 0
        var relinkedTransactions = 0
        var relinkedRules = 0

        try context.transaction {
            for (path, snapshot) in plan.canonicalByPath {
                if let category = canonicalCategories[path] {
                    if category.deletedAt != nil,
                       includeAmbiguousDeletions || !ambiguousPaths.contains(path) {
                        category.deletedAt = nil
                        category.touch()
                        restored += 1
                        restoreParents.insert(path)
                    }
                } else {
                    let category = Category(id: snapshot.id, name: snapshot.name,
                                            kind: CategoryKind(rawValue: snapshot.kind) ?? .expense)
                    context.insert(category)
                    added += 1
                    restoreParents.insert(path)
                    canonicalCategories[path] = category
                }
            }

            for (path, snapshot) in plan.canonicalByPath {
                guard restoreParents.contains(path) else { continue }
                guard let category = canonicalCategories[path] else { continue }
                if let parentID = snapshot.parentId,
                   let parentPath = plan.pathByBackupID[parentID],
                   let parent = canonicalCategories[parentPath] {
                    if category.parent?.id != parent.id { category.parent = parent; category.touch() }
                } else if category.parent != nil {
                    category.parent = nil
                    category.touch()
                }
            }

            func canonicalCategory(for categoryID: UUID) -> Category? {
                let path = pathsByCurrentID[categoryID] ?? plan.pathByBackupID[categoryID]
                guard let path, plan.canonicalByPath[path] != nil else { return nil }
                return canonicalCategories[path]
            }

            for transaction in transactions {
                guard let oldID = transaction.category?.id,
                      let canonical = canonicalCategory(for: oldID), oldID != canonical.id else { continue }
                transaction.category = canonical
                transaction.touch()
                relinkedTransactions += 1
            }
            for rule in rules {
                guard let oldID = rule.category?.id,
                      let canonical = canonicalCategory(for: oldID), oldID != canonical.id else { continue }
                rule.category = canonical
                rule.touch()
                relinkedRules += 1
            }
            for category in categories where category.deletedAt == nil {
                guard let oldParentID = category.parent?.id,
                      let parent = canonicalCategory(for: oldParentID), oldParentID != parent.id else { continue }
                category.parent = parent
                category.touch()
            }
            let canonicalIDByCurrentID = canonicalCurrentMap(plan: plan, selectedByPath: canonicalCategories,
                                                             pathsByCurrentID: pathsByCurrentID)
            for category in categories where category.deletedAt == nil {
                guard canonicalIDByCurrentID[category.id].map({ $0 != category.id }) == true else { continue }
                category.deletedAt = .now
                category.touch()
                merged += 1
            }
        }

        return Result(categoriesRestored: restored, categoriesAdded: added,
                      duplicateCategoriesMerged: merged,
                      transactionsRelinked: relinkedTransactions, rulesRelinked: relinkedRules)
    }

    private static func ambiguousDeletions(plan: Plan, categories: [Category], pathsByID: [UUID: String],
                                           referencedIDs: Set<UUID>) -> Set<String> {
        let backupPaths = Set(plan.canonicalByPath.keys)
        let activePaths = Set(categories.compactMap { category -> String? in
            guard category.deletedAt == nil else { return nil }
            let path = plan.pathByBackupID[category.id] ?? pathsByID[category.id]
            return path.flatMap { backupPaths.contains($0) ? $0 : nil }
        })
        let referencedPaths = Set(referencedIDs.compactMap { id -> String? in
            let path = plan.pathByBackupID[id] ?? pathsByID[id]
            return path.flatMap { backupPaths.contains($0) ? $0 : nil }
        })
        let deletedPaths = Set(categories.compactMap { category -> String? in
            guard category.deletedAt != nil else { return nil }
            let path = plan.pathByBackupID[category.id] ?? pathsByID[category.id]
            return path.flatMap { backupPaths.contains($0) ? $0 : nil }
        })
        return deletedPaths.subtracting(activePaths).subtracting(referencedPaths)
    }

    private static func currentPaths(_ categories: [Category]) throws -> [UUID: String] {
        var paths: [UUID: String] = [:]
        func path(for category: Category, visiting: Set<UUID> = []) throws -> String {
            if let path = paths[category.id] { return path }
            guard !visiting.contains(category.id) else { throw RecoveryError.invalidCategoryTree }
            var next = visiting
            next.insert(category.id)
            let parentPath = try category.parent.map { try path(for: $0, visiting: next) } ?? ""
            let name = category.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = "\(parentPath)/\(category.kind.rawValue)/\(name)"
            paths[category.id] = value
            return value
        }
        for category in categories { _ = try path(for: category) }
        return paths
    }

    private static func currentCategoriesByPath(_ categories: [Category], pathsByID: [UUID: String],
                                                plan: Plan) -> [String: [Category]] {
        let backupPaths = Set(plan.canonicalByPath.keys)
        return Dictionary(grouping: categories.compactMap { category -> (String, Category)? in
            let path = plan.pathByBackupID[category.id] ?? pathsByID[category.id]
            guard let path, backupPaths.contains(path) else { return nil }
            return (path, category)
        }, by: \.0).mapValues { $0.map(\.1) }
    }

    private static func selectExistingCategories(plan: Plan, categoriesByID: [UUID: Category],
                                                  currentByPath: [String: [Category]]) -> [String: Category] {
        var selected: [String: Category] = [:]
        for (path, snapshot) in plan.canonicalByPath {
            if let original = categoriesByID[snapshot.id] {
                selected[path] = original
            } else if let active = currentByPath[path, default: []]
                .filter({ $0.deletedAt == nil }).sorted(by: { $0.id.uuidString < $1.id.uuidString }).first {
                selected[path] = active
            } else if let deleted = currentByPath[path, default: []]
                .sorted(by: { $0.id.uuidString < $1.id.uuidString }).first {
                selected[path] = deleted
            }
        }
        return selected
    }

    private static func canonicalCurrentMap(plan: Plan, selectedByPath: [String: Category],
                                            pathsByCurrentID: [UUID: String]) -> [UUID: UUID] {
        var result = Dictionary(uniqueKeysWithValues: plan.pathByBackupID.map { id, path in
            (id, selectedByPath[path]?.id ?? plan.canonicalByPath[path]!.id)
        })
        let backupPaths = Set(plan.canonicalByPath.keys)
        for (id, path) in pathsByCurrentID where result[id] == nil && backupPaths.contains(path) {
            if let canonical = selectedByPath[path] { result[id] = canonical.id }
        }
        return result
    }

    private static func displayPath(_ category: Category) -> String {
        var names: [String] = []
        var current: Category? = category
        var visited: Set<UUID> = []
        while let item = current, visited.insert(item.id).inserted {
            names.append(item.localizedName)
            current = item.parent
        }
        return names.reversed().joined(separator: " › ")
    }

    private static func makePlan(backupURL: URL) throws -> Plan {
        guard let summary = BackupArchive.summary(at: backupURL) else {
            throw RecoveryError.invalidBackup
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: backupURL.appendingPathComponent("models/Category.json"))
        let snapshots = try decoder.decode([CategorySnapshot].self, from: data)
        var byID: [UUID: CategorySnapshot] = [:]
        for snapshot in snapshots {
            guard CategoryKind(rawValue: snapshot.kind) != nil else { throw RecoveryError.invalidCategoryTree }
            guard byID.updateValue(snapshot, forKey: snapshot.id) == nil else {
                throw RecoveryError.invalidCategoryTree
            }
        }
        var pathCache: [UUID: String] = [:]

        func path(for id: UUID, visiting: Set<UUID> = []) throws -> String {
            if let cached = pathCache[id] { return cached }
            guard !visiting.contains(id), let category = byID[id] else { throw RecoveryError.invalidCategoryTree }
            var nextVisiting = visiting
            nextVisiting.insert(id)
            let parentPath: String
            if let parentID = category.parentId {
                parentPath = try path(for: parentID, visiting: nextVisiting)
            } else {
                parentPath = ""
            }
            let key = "\(parentPath)/\(category.kind)/\(category.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
            pathCache[id] = key
            return key
        }

        let activeSnapshots = snapshots.filter { $0.deletedAt == nil }
        var canonicalByPath: [String: CategorySnapshot] = [:]
        var pathByBackupID: [UUID: String] = [:]
        for snapshot in activeSnapshots {
            if let parentID = snapshot.parentId, byID[parentID]?.deletedAt != nil {
                throw RecoveryError.invalidCategoryTree
            }
            let key = try path(for: snapshot.id)
            pathByBackupID[snapshot.id] = key
            if let existing = canonicalByPath[key] {
                if snapshot.id.uuidString < existing.id.uuidString { canonicalByPath[key] = snapshot }
            } else {
                canonicalByPath[key] = snapshot
            }
        }
        return Plan(backupDate: summary.createdAt, canonicalByPath: canonicalByPath,
                    pathByBackupID: pathByBackupID)
    }

    private enum RecoveryError: LocalizedError {
        case invalidBackup
        case invalidCategoryTree

        var errorDescription: String? {
            switch self {
            case .invalidBackup: "El respaldo no es válido o no contiene un catálogo de categorías verificable."
            case .invalidCategoryTree: "El árbol de categorías del respaldo tiene una relación faltante o circular."
            }
        }
    }
}
