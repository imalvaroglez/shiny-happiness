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
        let existingCategories = try? context.fetch(FetchDescriptor<Category>())

        var categoriesByName: [String: Category]
        if let existingCategories, !existingCategories.isEmpty {
            categoriesByName = [:]
            for cat in existingCategories {
                categoriesByName[cat.name] = cat
            }
            let existingSubcategories = existingCategories.flatMap { cat in
                cat.subcategories.map { sub in ("\(cat.name).\(sub.name)", sub) }
            }
            for (key, sub) in existingSubcategories {
                categoriesByName[key] = sub
            }

            syncCategories(context: context, categoriesByName: &categoriesByName, existingCategories: existingCategories)
        } else {
            Logger.app.info("Bootstrapping seed categories and rules")
            categoriesByName = loadCategories(context: context)
        }

        syncRules(context: context, categoriesByName: categoriesByName)

        try? context.save()
    }

    @discardableResult
    private static func loadCategories(context: ModelContext) -> [String: Category] {
        guard let url = Bundle.main.url(forResource: "categories", withExtension: "json") else {
            Logger.app.error("Could not find categories.json in bundle")
            return [:]
        }

        do {
            let data = try Data(contentsOf: url)
            let seed = try JSONDecoder().decode(CategorySeedFile.self, from: data)
            var map: [String: Category] = [:]

            for catJSON in seed.categories {
                let kind = CategoryKind(rawValue: catJSON.kind) ?? .expense
                let parent = Category(name: catJSON.name, kind: kind)
                context.insert(parent)
                map[catJSON.name] = parent

                for subName in catJSON.subcategories {
                    let sub = Category(name: subName, parent: parent, kind: kind)
                    context.insert(sub)
                    map["\(catJSON.name).\(subName)"] = sub
                }
            }
            return map
        } catch {
            Logger.app.error("Failed to load categories: \(error)")
            return [:]
        }
    }

    private static func syncCategories(context: ModelContext, categoriesByName: inout [String: Category], existingCategories: [Category]) {
        guard let url = Bundle.main.url(forResource: "categories", withExtension: "json") else { return }
        guard let data = try? Data(contentsOf: url) else { return }
        guard let seed = try? JSONDecoder().decode(CategorySeedFile.self, from: data) else { return }

        let existingParents = existingCategories.filter { $0.parent == nil }
        var added = 0

        for catJSON in seed.categories {
            guard let parent = existingParents.first(where: { $0.name == catJSON.name }) else { continue }
            let kind = CategoryKind(rawValue: catJSON.kind) ?? .expense
            let existingSubNames = Set(parent.subcategories.map(\.name))

            for subName in catJSON.subcategories where !existingSubNames.contains(subName) {
                let sub = Category(name: subName, parent: parent, kind: kind)
                context.insert(sub)
                categoriesByName["\(catJSON.name).\(subName)"] = sub
                added += 1
            }
        }

        if added > 0 {
            Logger.app.info("Synced \(added) new subcategories from seed JSON")
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
