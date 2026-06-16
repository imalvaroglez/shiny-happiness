import Testing
import Foundation
import SwiftData
@testable import FinanceTracker

@Suite("Category Management View State")
@MainActor
struct CategoryManagementViewStateTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([FinanceTracker.Category.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    @discardableResult
    private func insertCategory(
        _ name: String,
        kind: CategoryKind = .expense,
        parent: FinanceTracker.Category? = nil,
        context: ModelContext
    ) throws -> FinanceTracker.Category {
        let category = FinanceTracker.Category(name: name, parent: parent, kind: kind)
        context.insert(category)
        try context.save()
        return category
    }

    @Test("Groups only parent categories and sorts alphabetically")
    func groupsParentsAndSortsAlphabetically() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let transport = try insertCategory("Transport", context: context)
        let food = try insertCategory("Food", context: context)
        _ = try insertCategory("Coffee", parent: food, context: context)
        _ = try insertCategory("Salary", kind: .income, context: context)

        let tree = CategoryManagementTree(categories: [transport, food])
        let visible = tree.visibleParents(searchText: "", kindFilter: .all)

        #expect(visible.map(\.name) == ["Food", "Transport"])
    }

    @Test("Filters by kind")
    func filtersByKind() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let food = try insertCategory("Food", kind: .expense, context: context)
        let salary = try insertCategory("Salary", kind: .income, context: context)
        let investment = try insertCategory("Investment", kind: .investment, context: context)

        let tree = CategoryManagementTree(categories: [food, salary, investment])
        let visible = tree.visibleParents(searchText: "", kindFilter: .income)

        #expect(visible.map(\.name) == ["Salary"])
    }

    @Test("Search includes matching subcategory parents")
    func searchIncludesMatchingSubcategoryParents() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let food = try insertCategory("Food", context: context)
        let transport = try insertCategory("Transport", context: context)
        let coffee = try insertCategory("Coffee", parent: food, context: context)

        let tree = CategoryManagementTree(categories: [food, transport, coffee])
        let visible = tree.visibleParents(searchText: "coffee", kindFilter: .all)

        #expect(visible.map(\.name) == ["Food"])
    }

    @Test("Display guard hides duplicate active category rows")
    func displayGuardHidesDuplicateActiveRows() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let first = try insertCategory("Food", context: context)
        let duplicate = try insertCategory("Food", context: context)
        let income = try insertCategory("Food", kind: .income, context: context)

        let tree = CategoryManagementTree(categories: [first, duplicate, income])

        #expect(tree.parents.count == 2)
        #expect(tree.visibleParents(searchText: "", kindFilter: .expense).count == 1)
        #expect(tree.visibleParents(searchText: "", kindFilter: .income).count == 1)
    }

    @Test("Selection falls back to first visible parent")
    func selectionFallsBackToFirstVisibleParent() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let food = try insertCategory("Food", kind: .expense, context: context)
        let salary = try insertCategory("Salary", kind: .income, context: context)

        let tree = CategoryManagementTree(categories: [food, salary])

        #expect(tree.resolvedSelectionID(current: nil, searchText: "", kindFilter: .all) == food.id)
        #expect(tree.resolvedSelectionID(current: food.id, searchText: "", kindFilter: .income) == salary.id)
        #expect(tree.resolvedSelectionID(current: food.id, searchText: "nope", kindFilter: .all) == nil)
    }

    @Test("Newly created selected parent remains selected")
    func newlyCreatedSelectedParentRemainsSelected() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let food = try insertCategory("Food", context: context)
        let travel = try insertCategory("Travel", context: context)

        let tree = CategoryManagementTree(categories: [food, travel])
        let resolved = tree.resolvedSelectionID(current: travel.id, searchText: "", kindFilter: .all)

        #expect(resolved == travel.id)
    }

    @Test("Right pane model updates with selected parent")
    func rightPaneModelUpdatesWithSelectedParent() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let food = try insertCategory("Food", context: context)
        let transport = try insertCategory("Transport", context: context)
        let coffee = try insertCategory("Coffee", parent: food, context: context)
        let gas = try insertCategory("Gas", parent: transport, context: context)

        let tree = CategoryManagementTree(categories: [food, transport, coffee, gas])

        #expect(tree.parent(id: food.id)?.name == "Food")
        #expect(tree.subcategories(for: food).map(\.name) == ["Coffee"])
        #expect(tree.parent(id: transport.id)?.name == "Transport")
        #expect(tree.subcategories(for: transport).map(\.name) == ["Gas"])
    }

    @Test("Empty category state has no visible parents")
    func emptyStateHasNoVisibleParents() async throws {
        let tree = CategoryManagementTree(categories: [])

        #expect(tree.hasCategories == false)
        #expect(tree.visibleParents(searchText: "", kindFilter: .all).isEmpty)
        #expect(tree.resolvedSelectionID(current: nil, searchText: "", kindFilter: .all) == nil)
    }
}
