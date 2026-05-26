import Testing
import Foundation
import SwiftData
@testable import FinanceTracker

typealias FinanceCategory = FinanceTracker.Category

@Suite("Category Management Actions")
@MainActor
struct CategoryManagementActionsTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            Account.self,
            Transaction.self,
            Statement.self,
            FinanceCategory.self,
            CategoryRule.self,
            InstallmentPlan.self,
            PendingImport.self,
            SignRecoveryHint.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    @Test("Create parent category with correct kind")
    func testCreateParent() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let cat = try CategoryManagementActions.createParent(name: "Travel", kind: .expense, context: context)
        #expect(cat.name == "Travel")
        #expect(cat.kind == .expense)
        #expect(cat.parent == nil)
        #expect(cat.deletedAt == nil)

        let active = try CategoryManagementActions.activeCategories(context: context)
        #expect(active.count == 1)
    }

    @Test("Create parent throws on duplicate name within same kind")
    func testDuplicateParentRejected() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        _ = try CategoryManagementActions.createParent(name: "Travel", kind: .expense, context: context)
        #expect(throws: CategoryManagementError.duplicateName) {
            try CategoryManagementActions.createParent(name: "Travel", kind: .expense, context: context)
        }
    }

    @Test("Create parent allows same name in different kind")
    func testSameNameDifferentKind() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        _ = try CategoryManagementActions.createParent(name: "Investment", kind: .expense, context: context)
        let cat2 = try CategoryManagementActions.createParent(name: "Investment", kind: .income, context: context)
        #expect(cat2.kind == .income)
    }

    @Test("Create parent throws on empty name")
    func testEmptyNameRejected() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        #expect(throws: CategoryManagementError.emptyName) {
            try CategoryManagementActions.createParent(name: "  ", kind: .expense, context: context)
        }
    }

    @Test("Create subcategory inherits parent kind")
    func testSubcategoryInheritsKind() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let parent = try CategoryManagementActions.createParent(name: "Transport", kind: .expense, context: context)
        let sub = try CategoryManagementActions.createSubcategory(parent: parent, name: "Rideshare", context: context)

        #expect(sub.name == "Rideshare")
        #expect(sub.kind == .expense)
        #expect(sub.parent?.id == parent.id)
    }

    @Test("Create subcategory rejects duplicate under same parent")
    func testDuplicateSubcategoryRejected() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let parent = try CategoryManagementActions.createParent(name: "Food", kind: .expense, context: context)
        _ = try CategoryManagementActions.createSubcategory(parent: parent, name: "Coffee", context: context)

        #expect(throws: CategoryManagementError.duplicateName) {
            try CategoryManagementActions.createSubcategory(parent: parent, name: "Coffee", context: context)
        }
    }

    @Test("Delete subcategory reassigns transactions and rules to parent")
    func testSubcategoryDeletionReassigns() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let parent = try CategoryManagementActions.createParent(name: "Transport", kind: .expense, context: context)
        let sub = try CategoryManagementActions.createSubcategory(parent: parent, name: "Gas", context: context)

        let tx = Transaction(postedAt: .now, amount: -500, descriptionRaw: "GAS STATION")
        tx.category = sub
        context.insert(tx)

        let rule = CategoryRule(
            patternRegex: "(?i)gas",
            merchantMatch: "Gas",
            category: sub,
            priority: 80,
            source: "seed"
        )
        context.insert(rule)
        try context.save()

        try CategoryManagementActions.deleteSubcategory(sub, context: context)

        #expect(sub.deletedAt != nil, "Subcategory should be soft-deleted")
        #expect(tx.category?.id == parent.id, "Transaction should be reassigned to parent")
        #expect(rule.category?.id == parent.id, "CategoryRule should be reassigned to parent")

        let active = try CategoryManagementActions.activeCategories(context: context)
        #expect(active.contains(where: { $0.id == sub.id }) == false, "Soft-deleted subcategory should not appear in active")
    }

    @Test("Delete parent with active children is blocked")
    func testParentDeletionBlockedWithChildren() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let parent = try CategoryManagementActions.createParent(name: "Food", kind: .expense, context: context)
        _ = try CategoryManagementActions.createSubcategory(parent: parent, name: "Groceries", context: context)

        #expect(throws: CategoryManagementError.parentHasActiveChildren) {
            try CategoryManagementActions.deleteParent(parent, context: context)
        }

        #expect(parent.deletedAt == nil, "Parent should not be deleted")
    }

    @Test("Delete parent without children nullifies transaction and rule references")
    func testParentDeletionClearsReferences() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let parent = try CategoryManagementActions.createParent(name: "Misc", kind: .expense, context: context)

        let tx = Transaction(postedAt: .now, amount: -50, descriptionRaw: "MISC CHARGE")
        tx.category = parent
        context.insert(tx)

        let rule = CategoryRule(
            patternRegex: "(?i)misc",
            merchantMatch: "Misc",
            category: parent,
            priority: 50,
            source: "seed"
        )
        context.insert(rule)
        try context.save()

        try CategoryManagementActions.deleteParent(parent, context: context)

        #expect(parent.deletedAt != nil, "Parent should be soft-deleted")
        #expect(tx.category == nil, "Transaction should become uncategorized")
        #expect(rule.category == nil, "CategoryRule should lose its category reference")
    }

    @Test("Active categories excludes soft-deleted")
    func testActiveCategoriesFiltering() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let cat1 = try CategoryManagementActions.createParent(name: "A", kind: .expense, context: context)
        _ = try CategoryManagementActions.createParent(name: "B", kind: .expense, context: context)

        try CategoryManagementActions.deleteParent(cat1, context: context)

        let active = try CategoryManagementActions.activeCategories(context: context)
        #expect(active.count == 1)
        #expect(active[0].name == "B")
    }

    @Test("Categorizer ignores rules pointing to soft-deleted category")
    func testCategorizerIgnoresDeletedCategory() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let cat = Category(name: "DeletedCat", kind: .expense)
        context.insert(cat)
        try context.save()

        cat.deletedAt = Date.now
        try context.save()

        let rule = CategoryRule(
            patternRegex: "(?i)store",
            merchantMatch: "Store",
            category: cat,
            priority: 80,
            source: "seed"
        )
        context.insert(rule)

        let tx = Transaction(postedAt: .now, amount: -100, descriptionRaw: "STORE PURCHASE")
        context.insert(tx)
        try context.save()

        let allRules = try context.fetch(FetchDescriptor<CategoryRule>())
        let result = Categorizer.categorize(transactions: [tx], rules: allRules)

        #expect(result.categorized == 0, "Should not categorize with deleted category rule")
        #expect(tx.category == nil)
    }

    @Test("Categorizer ignores rules with nil category")
    func testCategorizerIgnoresNilCategoryRules() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let rule = CategoryRule(
            patternRegex: "(?i)store",
            merchantMatch: "Store",
            category: nil,
            priority: 80,
            source: "seed"
        )
        context.insert(rule)

        let tx = Transaction(postedAt: .now, amount: -100, descriptionRaw: "STORE PURCHASE")
        context.insert(tx)
        try context.save()

        let allRules = try context.fetch(FetchDescriptor<CategoryRule>())
        let result = Categorizer.categorize(transactions: [tx], rules: allRules)

        #expect(result.categorized == 0)
        #expect(tx.category == nil)
    }

    @Test("Seed rules are not created for soft-deleted categories")
    func testSeedRuleSkipsDeletedCategory() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let cat = Category(name: "DeletedCat", kind: .expense)
        cat.deletedAt = Date.now
        context.insert(cat)
        try context.save()

        let categoriesByName: [String: FinanceCategory] = ["DeletedCat": cat]

        SeedDataLoader.bootstrapIfNeeded(context: context)

        let rules = try context.fetch(FetchDescriptor<CategoryRule>())
        let rulesForDeleted = rules.filter { $0.category?.id == cat.id }
        #expect(rulesForDeleted.isEmpty, "No seed rules should point to soft-deleted category")
    }

    @Test("Seed bootstrap does not recreate soft-deleted category")
    func testSeedBootstrapSkipsDeletedCategory() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let food = Category(name: "Food & Drink", kind: .expense)
        food.deletedAt = Date.now
        context.insert(food)
        try context.save()

        SeedDataLoader.bootstrapIfNeeded(context: context)

        let allCats = try context.fetch(FetchDescriptor<FinanceCategory>())
        let foodCats = allCats.filter { $0.name == "Food & Drink" }
        #expect(foodCats.count == 1, "Should not recreate soft-deleted category")
        #expect(foodCats[0].deletedAt != nil)
    }

    @Test("isDuplicate detects duplicates among active categories only")
    func testIsDuplicateIgnoresDeleted() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let cat = Category(name: "Travel", kind: .expense)
        cat.deletedAt = Date.now
        context.insert(cat)
        try context.save()

        let isDup = CategoryManagementActions.isDuplicate(name: "Travel", kind: .expense, parent: nil, context: context)
        #expect(isDup == false, "Deleted category should not count as duplicate")
    }
}
