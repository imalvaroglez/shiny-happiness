import Foundation
import SwiftData
import os

struct SeedDataLoader {
    enum BootstrapError: LocalizedError {
        case missingResource(String)
        case customizationUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .missingResource(let name): "Required seed file is missing: \(name)"
            case .customizationUnavailable(let detail): "Personalización no disponible: \(detail). Reparación de seeds suspendida."
            }
        }
    }

    struct CategoryJSON: Codable {
        let name: String
        let kind: String
        let subcategories: [String]
    }

    struct CategorySeedFile: Codable {
        let categories: [CategoryJSON]
    }

    struct RuleJSON: Codable {
        let pattern: String
        let merchant: String
        let category: String
        let priority: Int
    }

    struct RuleSeedFile: Codable {
        let rules: [RuleJSON]
    }

    /// Nombres de fábrica de categories.json (padres y subcategorías). El
    /// rename los consulta para saber qué categorías deben registrar su
    /// nombre original y no resucitar en el bootstrap.
    static let seedCategoryNames: Set<String> = {
        guard let url = Bundle.main.url(forResource: "categories", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let seed = try? JSONDecoder().decode(CategorySeedFile.self, from: data) else {
            return []
        }
        var names = Set<String>()
        for category in seed.categories {
            names.insert(category.name)
            names.formUnion(category.subcategories)
        }
        return names
    }()

    static func seedOrigin(for category: Category, customizations: [CategoryCustomization]) throws
        -> (name: String, parentName: String?, kindRaw: String)? {
        if let entry = customizations.first(where: { $0.categoryID == category.id && $0.deletedAt == nil }),
           let name = entry.seedName {
            return (name, entry.seedParentName, entry.seedKindRaw ?? category.kind.rawValue)
        }
        guard let url = Bundle.main.url(forResource: "categories", withExtension: "json") else {
            throw BootstrapError.missingResource("categories.json")
        }
        let seed = try JSONDecoder().decode(CategorySeedFile.self, from: Data(contentsOf: url))
        if let parent = category.parent {
            let parentName = customizations.first { $0.categoryID == parent.id && $0.deletedAt == nil }?.seedName ?? parent.name
            if let definition = seed.categories.first(where: {
                $0.name == parentName && $0.kind == category.kind.rawValue && $0.subcategories.contains(category.name)
            }) { return (category.name, definition.name, definition.kind) }
        } else if let definition = seed.categories.first(where: { $0.name == category.name && $0.kind == category.kind.rawValue }) {
            return (definition.name, nil, definition.kind)
        }
        return nil
    }

    static func bootstrapIfNeeded(context: ModelContext, customizationURL: URL? = nil) throws {
        let url = try customizationURL ?? CategoryCustomizationStore.defaultURL()
        let original: CategoryCustomizationCatalog
        do { original = try CategoryCustomizationStore.read(fileURL: url) }
        catch { throw BootstrapError.customizationUnavailable(error.localizedDescription) }
        var catalog = original
        let files = try SidecarFileTransaction(urls: [url])
        do {
            try context.transaction {
                var categoriesByName = try buildExistingMap(context: context, customizations: catalog.entries)
                try loadCategoriesIfNeeded(context: context, categoriesByName: &categoriesByName)
                try repairStaleCategoryKinds(context: context, categoriesByName: &categoriesByName)
                try repairDuplicateActiveCategories(context: context, customizations: &catalog)
                try repairDanglingCategoryLinks(context: context)
                categoriesByName = try buildExistingMap(context: context, customizations: catalog.entries)
                try syncRules(context: context, categoriesByName: categoriesByName)
                if catalog != original {
                    try CategoryCustomizationStore.replace(with: catalog, at: files.stagedURL(for: url), notify: false)
                    try files.publish(url)
                }
            }
            files.discard()
            if catalog != original { NotificationCenter.default.post(name: CategoryCustomizationStore.didChangeNotification, object: url) }
        } catch {
            let originalError = error
            do { try files.rollback() }
            catch { throw CategoryCustomizationStore.StoreError.invalid([originalError.localizedDescription, error.localizedDescription]) }
            throw originalError
        }
    }

    private static func buildExistingMap(context: ModelContext,
                                         customizations: [CategoryCustomization] = []) throws -> [String: Category] {
        let existing = try context.fetch(FetchDescriptor<Category>())
        var map: [String: Category] = [:]
        // Alias por id: categorías renombradas que provenían del seed indexan
        // SUS claves bajo el nombre original — el loader las encuentra y no
        // re-crea el nombre de fábrica como duplicado.
        let byID = Dictionary(customizations.filter { $0.deletedAt == nil }.map { ($0.categoryID, $0) },
                              uniquingKeysWith: { first, _ in first })
        func insert(_ key: String, _ category: Category) {
            if let existing = map[key] {
                if existing.deletedAt == nil { return }
                if category.deletedAt != nil { return }
            }
            map[key] = category
        }
        for cat in existing.sorted(by: categoryMapSort) {
            let origin = byID[cat.id]?.seedName ?? cat.name
            if let parent = cat.parent {
                let parentOrigin = byID[parent.id]?.seedName ?? parent.name
                insert(lookupKey(parentID: parent.id, name: cat.name, kind: cat.kind), cat)
                insert(lookupKey(parentID: parent.id, name: origin, kind: cat.kind), cat)
                insert("\(parent.name).\(cat.name)", cat)
                insert("\(parentOrigin).\(origin)", cat)
            } else {
                insert(rootKey(name: cat.name, kind: cat.kind), cat)
                insert(rootKey(name: origin, kind: cat.kind), cat)
                insert(cat.name, cat)
                insert(origin, cat)
            }
        }
        return map
    }

    private static func rootKey(name: String, kind: CategoryKind) -> String {
        "root|\(kind.rawValue)|\(normalizedCategoryName(name))"
    }

    private static func lookupKey(parentID: UUID, name: String, kind: CategoryKind) -> String {
        "\(parentID.uuidString)|\(kind.rawValue)|\(normalizedCategoryName(name))"
    }

    private static func loadCategoriesIfNeeded(context: ModelContext, categoriesByName: inout [String: Category]) throws {
        guard let url = Bundle.main.url(forResource: "categories", withExtension: "json") else {
            throw BootstrapError.missingResource("categories.json")
        }

        let data = try Data(contentsOf: url)
        let seed = try JSONDecoder().decode(CategorySeedFile.self, from: data)
        var parentsAdded = 0
        var subsAdded = 0

        for catJSON in seed.categories {
            let kind = CategoryKind(rawValue: catJSON.kind) ?? .expense

            let parent: Category
                let key = rootKey(name: catJSON.name, kind: kind)
                if let existing = categoriesByName[key] {
                    parent = existing
                } else {
                    parent = Category(name: catJSON.name, kind: kind)
                    context.insert(parent)
                    categoriesByName[key] = parent
                    parentsAdded += 1
                }
                categoriesByName[catJSON.name] = parent

            for subName in catJSON.subcategories {
                let key = lookupKey(parentID: parent.id, name: subName, kind: kind)
                if categoriesByName[key] == nil {
                    let sub = Category(name: subName, parent: parent, kind: kind)
                    context.insert(sub)
                    categoriesByName[key] = sub
                    subsAdded += 1
                }
                categoriesByName["\(catJSON.name).\(subName)"] = categoriesByName[key]
            }
        }

        if parentsAdded > 0 || subsAdded > 0 {
            Logger.app.info("Seed categories: added \(parentsAdded) parents, \(subsAdded) subcategories")
        }
    }

    private static func repairStaleCategoryKinds(context: ModelContext, categoriesByName: inout [String: Category]) throws {
        let allCategories = try context.fetch(FetchDescriptor<Category>())
        let ccPaymentsMatches = allCategories.filter { $0.name == "Credit Card Payments" && $0.deletedAt == nil }

        guard !ccPaymentsMatches.isEmpty else { return }

        let canonical: Category
        let duplicates: [Category]

        if let preferred = ccPaymentsMatches.first(where: { $0.kind == .creditCardPayment && $0.parent == nil }) {
            canonical = preferred
            duplicates = ccPaymentsMatches.filter { $0.id != preferred.id }
        } else {
            canonical = ccPaymentsMatches[0]
            duplicates = Array(ccPaymentsMatches.dropFirst())
        }

        if canonical.kind != .creditCardPayment {
            canonical.kind = .creditCardPayment
            canonical.touch()
        }
        if canonical.parent != nil {
            canonical.parent = nil
            canonical.touch()
        }

        let requiredSubs = ["Card Payment Received", "Card Payment Sent"]
        let existingSubNames = Set(allCategories.filter { $0.parent?.id == canonical.id }.map(\.name))
        for subName in requiredSubs where !existingSubNames.contains(subName) {
            let sub = Category(name: subName, parent: canonical, kind: .creditCardPayment)
            context.insert(sub)
            categoriesByName["Credit Card Payments.\(subName)"] = sub
        }

        guard !duplicates.isEmpty else {
            categoriesByName["Credit Card Payments"] = canonical
            return
        }

        let allTransactions = try context.fetch(FetchDescriptor<Transaction>())
        let allRules = try context.fetch(FetchDescriptor<CategoryRule>())

        for dupe in duplicates {
            for tx in allTransactions where tx.category?.id == dupe.id {
                tx.category = canonical
            }
            for rule in allRules where rule.category?.id == dupe.id {
                rule.category = canonical
            }
            for sub in dupe.subcategories {
                sub.parent = canonical
                sub.touch()
            }
            dupe.deletedAt = .now
            dupe.touch()
        }

        categoriesByName["Credit Card Payments"] = canonical
        Logger.app.info("Category repair: canonicalized Credit Card Payments (kind=\(canonical.kind.rawValue)), soft-deleted \(duplicates.count) duplicate(s)")
    }

    private static func repairDuplicateActiveCategories(context: ModelContext, customizations: inout CategoryCustomizationCatalog) throws {
        var softDeletedCount = 0
        let allTransactions = try context.fetch(FetchDescriptor<Transaction>())
        let allRules = try context.fetch(FetchDescriptor<CategoryRule>())

        while true {
            let allCategories = try context.fetch(FetchDescriptor<Category>())
            let activeCategories = allCategories.filter { $0.deletedAt == nil }

            guard let duplicateGroup = firstDuplicateGroup(in: activeCategories) else { break }

            let sortedGroup = duplicateGroup.sorted(by: categorySort)
            guard let canonical = sortedGroup.first else { break }
            let duplicates = sortedGroup.dropFirst()
            let duplicateIDs = Set(duplicates.map(\.id))

            for tx in allTransactions where tx.category.map({ duplicateIDs.contains($0.id) }) == true {
                tx.category = canonical
                tx.touch()
            }

            for rule in allRules where rule.category.map({ duplicateIDs.contains($0.id) }) == true {
                rule.category = canonical
                rule.touch()
            }

            for duplicate in duplicates {
                if let source = customizations.entries.first(where: { $0.categoryID == duplicate.id && $0.deletedAt == nil }) {
                    let index = customizations.entries.firstIndex { $0.categoryID == canonical.id }
                    var target = index.map { customizations.entries[$0] }
                        ?? CategoryCustomization(categoryID: canonical.id, seedName: nil, tintHex: nil,
                                                 updatedAt: .distantPast, deletedAt: nil)
                    target.seedName = target.seedName ?? source.seedName
                    target.seedParentName = target.seedParentName ?? source.seedParentName
                    target.seedKindRaw = target.seedKindRaw ?? source.seedKindRaw
                    target.tintHex = target.tintHex ?? source.tintHex
                    target.deletedAt = nil
                    target.updatedAt = PersistedMutationClock.next(after: max(target.updatedAt, source.updatedAt))
                    customizations.entries.removeAll { $0.categoryID == canonical.id }
                    customizations.entries.append(target)
                    if let sourceIndex = customizations.entries.firstIndex(where: { $0.categoryID == duplicate.id }) {
                        let stamp = PersistedMutationClock.next(after: source.updatedAt)
                        customizations.entries[sourceIndex].deletedAt = stamp
                        customizations.entries[sourceIndex].updatedAt = stamp
                    }
                    customizations.updatedAt = max(customizations.updatedAt, target.updatedAt)
                }
                for child in allCategories where child.parent?.id == duplicate.id {
                    child.parent = canonical
                    child.touch()
                }
                duplicate.deletedAt = .now
                duplicate.touch()
                softDeletedCount += 1
            }
        }

        if softDeletedCount > 0 {
            Logger.app.info("Category repair: soft-deleted \(softDeletedCount) duplicate active category record(s)")
        }
    }

    /// Relinks transactions and rules whose category is soft-deleted to the live
    /// category with the same path (kind + name chain from the root), when one
    /// exists. Links with no live counterpart stay untouched; reviving those is
    /// the manual recovery flow's job (CategoryRecoveryService).
    private static func repairDanglingCategoryLinks(context: ModelContext) throws {
        let allCategories = try context.fetch(FetchDescriptor<Category>())
        guard allCategories.contains(where: { $0.deletedAt != nil }) else { return }

        // Same path scheme as CategoryRecoveryService.currentPaths.
        func path(for category: Category, visiting: Set<UUID> = []) -> String? {
            guard !visiting.contains(category.id) else { return nil }
            var next = visiting
            next.insert(category.id)
            let parentPath = category.parent.flatMap { path(for: $0, visiting: next) } ?? ""
            return "\(parentPath)/\(category.kind.rawValue)/\(normalizedCategoryName(category.name))"
        }

        var liveByPath: [String: Category] = [:]
        for category in allCategories where category.deletedAt == nil {
            guard let key = path(for: category) else { continue }
            if let current = liveByPath[key], current.id.uuidString <= category.id.uuidString { continue }
            liveByPath[key] = category
        }
        guard !liveByPath.isEmpty else { return }

        let danglingByPath: [UUID: String] = allCategories.reduce(into: [:]) { map, category in
            guard category.deletedAt != nil, let key = path(for: category) else { return }
            map[category.id] = key
        }
        guard danglingByPath.values.contains(where: { liveByPath[$0] != nil }) else { return }

        var relinked = 0
        for tx in try context.fetch(FetchDescriptor<Transaction>()) {
            guard let dead = tx.category, dead.deletedAt != nil,
                  let key = danglingByPath[dead.id],
                  let live = liveByPath[key], live.id != dead.id else { continue }
            tx.category = live
            tx.touch()
            relinked += 1
        }
        for rule in try context.fetch(FetchDescriptor<CategoryRule>()) {
            guard let dead = rule.category, dead.deletedAt != nil,
                  let key = danglingByPath[dead.id],
                  let live = liveByPath[key], live.id != dead.id else { continue }
            rule.category = live
            rule.touch()
            relinked += 1
        }
        if relinked > 0 {
            Logger.app.info("Category repair: relinked \(relinked) row(s) from soft-deleted categories to live siblings")
        }
    }

    private static func firstDuplicateGroup(in categories: [Category]) -> [Category]? {
        let grouped = Dictionary(grouping: categories, by: duplicateKey)
        return grouped.values
            .filter { $0.count > 1 }
            .sorted { lhs, rhs in
                guard let lhsFirst = lhs.sorted(by: categorySort).first,
                      let rhsFirst = rhs.sorted(by: categorySort).first else {
                    return lhs.count > rhs.count
                }
                return categorySort(lhsFirst, rhsFirst)
            }
            .first
    }

    private static func duplicateKey(for category: Category) -> String {
        let parentID = category.parent?.id.uuidString ?? "root"
        return "\(parentID)|\(category.kind.rawValue)|\(normalizedCategoryName(category.name))"
    }

    private static func normalizedCategoryName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func categorySort(_ lhs: Category, _ rhs: Category) -> Bool {
        let lhsName = normalizedCategoryName(lhs.name)
        let rhsName = normalizedCategoryName(rhs.name)
        if lhsName != rhsName { return lhsName < rhsName }
        if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func categoryMapSort(_ lhs: Category, _ rhs: Category) -> Bool {
        if (lhs.deletedAt == nil) != (rhs.deletedAt == nil) {
            return lhs.deletedAt == nil
        }
        return categorySort(lhs, rhs)
    }

    private static func syncRules(context: ModelContext, categoriesByName: [String: Category]) throws {
        guard let url = Bundle.main.url(forResource: "category_rules", withExtension: "json") else {
            throw BootstrapError.missingResource("category_rules.json")
        }

        let data = try Data(contentsOf: url)
        let seed = try JSONDecoder().decode(RuleSeedFile.self, from: data)

        let existingRules = try context.fetch(FetchDescriptor<CategoryRule>())
        let existingPatterns = Set(existingRules.map(\.patternRegex))

        var added = 0
        for ruleJSON in seed.rules {
            guard !existingPatterns.contains(ruleJSON.pattern) else { continue }
            let category = categoriesByName[ruleJSON.category]
            guard let category, category.deletedAt == nil else { continue }
            let rule = CategoryRule(
                patternRegex: ruleJSON.pattern,
                merchantMatch: ruleJSON.merchant,
                category: category,
                priority: ruleJSON.priority,
                source: "seed"
            )
            context.insert(rule)
            added += 1
        }

        if added > 0 {
            Logger.app.info("Synced \(added) new category rules from seed JSON")
        }
    }
}
