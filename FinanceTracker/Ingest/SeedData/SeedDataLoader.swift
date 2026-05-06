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
        if let existingCategories, !existingCategories.isEmpty { return }

        Logger.app.info("Bootstrapping seed categories and rules")

        let categoriesByName = loadCategories(context: context)
        loadRules(context: context, categoriesByName: categoriesByName)

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

    private static func loadRules(context: ModelContext, categoriesByName: [String: Category]) {
        guard let url = Bundle.main.url(forResource: "category_rules", withExtension: "json") else {
            Logger.app.error("Could not find category_rules.json in bundle")
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let seed = try JSONDecoder().decode(RuleSeedFile.self, from: data)

            for ruleJSON in seed.rules {
                let category = categoriesByName[ruleJSON.category]
                let rule = CategoryRule(
                    patternRegex: ruleJSON.pattern,
                    merchantMatch: ruleJSON.merchant,
                    category: category,
                    priority: ruleJSON.priority,
                    source: "seed"
                )
                context.insert(rule)
            }
        } catch {
            Logger.app.error("Failed to load category rules: \(error)")
        }
    }
}
