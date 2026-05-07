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
        syncRules(context: context, categoriesByName: categoriesByName)
        try? context.save()
    }

    private static func buildExistingMap(context: ModelContext) -> [String: Category] {
        let existing = (try? context.fetch(FetchDescriptor<Category>())) ?? []
        var map: [String: Category] = [:]
        for cat in existing {
            map[cat.name] = cat
        }
        for cat in existing {
            if let parent = cat.parent {
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
                        let sub = Category(name: subName, parent: parent, kind: kind)
                        context.insert(sub)
                        categoriesByName[key] = sub
                        subsAdded += 1
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
