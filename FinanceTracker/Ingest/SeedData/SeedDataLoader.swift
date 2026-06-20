import Foundation
import SwiftData
import os

struct SeedDataLoader {
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

    static func bootstrapIfNeeded(context: ModelContext) {
        var categoriesByName = buildExistingMap(context: context)
        loadCategoriesIfNeeded(context: context, categoriesByName: &categoriesByName)
        repairStaleCategoryKinds(context: context, categoriesByName: &categoriesByName)
        repairDuplicateActiveCategories(context: context)
        categoriesByName = buildExistingMap(context: context)
        syncRules(context: context, categoriesByName: categoriesByName)
        try? context.save()
    }

    private static func buildExistingMap(context: ModelContext) -> [String: Category] {
        let existing = (try? context.fetch(FetchDescriptor<Category>())) ?? []
        var map: [String: Category] = [:]
        for cat in existing.sorted(by: categoryMapSort) {
            if map[cat.name] == nil {
                map[cat.name] = cat
            }
            if let parent = cat.parent, map["\(parent.name).\(cat.name)"] == nil {
                map["\(parent.name).\(cat.name)"] = cat
            }
        }
        return map
    }

    private static func loadCategoriesIfNeeded(context: ModelContext, categoriesByName: inout [String: Category]) {
        guard let url = Bundle.main.url(forResource: "categories", withExtension: "json") else {
            Logger.app.error("Could not find categories.json in bundle")
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let seed = try JSONDecoder().decode(CategorySeedFile.self, from: data)
            var parentsAdded = 0
            var subsAdded = 0

            for catJSON in seed.categories {
                let kind = CategoryKind(rawValue: catJSON.kind) ?? .expense

                let parent: Category
                if let existing = categoriesByName[catJSON.name] {
                    parent = existing
                } else {
                    parent = Category(name: catJSON.name, kind: kind)
                    context.insert(parent)
                    categoriesByName[catJSON.name] = parent
                    parentsAdded += 1
                }

                for subName in catJSON.subcategories {
                    let key = "\(catJSON.name).\(subName)"
                    if categoriesByName[key] == nil {
                        if let existingSubcategory = categoriesByName[subName] {
                            categoriesByName[key] = existingSubcategory
                        } else {
                            let sub = Category(name: subName, parent: parent, kind: kind)
                            context.insert(sub)
                            categoriesByName[key] = sub
                            subsAdded += 1
                        }
                    }
                }
            }

            if parentsAdded > 0 || subsAdded > 0 {
                Logger.app.info("Seed categories: added \(parentsAdded) parents, \(subsAdded) subcategories")
            }
        } catch {
            Logger.app.error("Failed to load categories: \(error)")
        }
    }

    private static func repairStaleCategoryKinds(context: ModelContext, categoriesByName: inout [String: Category]) {
        let allCategories = (try? context.fetch(FetchDescriptor<Category>())) ?? []
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

        let allTransactions = (try? context.fetch(FetchDescriptor<Transaction>())) ?? []
        let allRules = (try? context.fetch(FetchDescriptor<CategoryRule>())) ?? []

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

    private static func repairDuplicateActiveCategories(context: ModelContext) {
        var softDeletedCount = 0

        while true {
            let activeCategories = (try? context.fetch(FetchDescriptor<Category>()))?
                .filter { $0.deletedAt == nil } ?? []

            guard let duplicateGroup = firstDuplicateGroup(in: activeCategories) else { break }

            let sortedGroup = duplicateGroup.sorted(by: categorySort)
            guard let canonical = sortedGroup.first else { break }
            let duplicates = sortedGroup.dropFirst()
            let duplicateIDs = Set(duplicates.map(\.id))

            let allTransactions = (try? context.fetch(FetchDescriptor<Transaction>())) ?? []
            let allRules = (try? context.fetch(FetchDescriptor<CategoryRule>())) ?? []

            for tx in allTransactions where duplicateIDs.contains(tx.category?.id ?? UUID()) {
                tx.category = canonical
                tx.touch()
            }

            for rule in allRules where duplicateIDs.contains(rule.category?.id ?? UUID()) {
                rule.category = canonical
                rule.touch()
            }

            for duplicate in duplicates {
                for child in activeCategories where child.parent?.id == duplicate.id {
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

    private static func syncRules(context: ModelContext, categoriesByName: [String: Category]) {
        guard let url = Bundle.main.url(forResource: "category_rules", withExtension: "json") else {
            Logger.app.error("Could not find category_rules.json in bundle")
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let seed = try JSONDecoder().decode(RuleSeedFile.self, from: data)

            let existingRules = try? context.fetch(FetchDescriptor<CategoryRule>())
            let existingPatterns = Set((existingRules ?? []).map(\.patternRegex))

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
        } catch {
            Logger.app.error("Failed to load category rules: \(error)")
        }
    }
}
