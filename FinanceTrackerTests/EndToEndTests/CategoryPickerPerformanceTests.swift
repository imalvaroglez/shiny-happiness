import Foundation
import SwiftData
import Testing
@testable import FinanceTracker

@Suite("Category Picker Performance")
@MainActor
struct CategoryPickerPerformanceTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([FinanceTracker.Category.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    @Test("Index sorts, nests, deduplicates, and filters category kinds")
    func categoryIndex() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let food = FinanceTracker.Category(
            id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001")),
            name: "Food"
        )
        let duplicateFood = FinanceTracker.Category(
            id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002")),
            name: " food "
        )
        let transport = FinanceTracker.Category(name: "Transport")
        let coffee = FinanceTracker.Category(name: "Coffee", parent: food)
        let bars = FinanceTracker.Category(name: "Bars", parent: food)
        let salary = FinanceTracker.Category(name: "Salary", kind: .income)
        [food, duplicateFood, transport, coffee, bars, salary].forEach(context.insert)
        try context.save()

        let sections = CategoryPickerIndex.build(categories: [salary, transport, coffee, duplicateFood, bars, food], allowedKinds: nil)
        #expect(sections.map(\.kind) == [.expense, .income])
        #expect(sections[0].rows.map(\.category.id) == [food.id, bars.id, coffee.id, transport.id])
        #expect(sections[0].rows.map(\.depth) == [0, 1, 1, 0])

        let incomeOnly = CategoryPickerIndex.build(categories: [salary, food], allowedKinds: [.income])
        #expect(incomeOnly.flatMap(\.rows).map(\.category.id) == [salary.id])
    }

    @Test("Promotion preview key follows only transaction candidate inputs")
    func previewKeyTracksCandidateInputs() {
        let accountID = UUID()
        let date = Date(timeIntervalSince1970: 1_000)
        let base = ManualPromotionPreviewKey(
            accountID: accountID,
            kind: .charge,
            date: date,
            amount: -10,
            description: "Merchant"
        )

        #expect(base == ManualPromotionPreviewKey(
            accountID: accountID,
            kind: .charge,
            date: date,
            amount: -10,
            description: "Merchant"
        ))
        #expect(base != ManualPromotionPreviewKey(accountID: UUID(), kind: .charge, date: date, amount: -10, description: "Merchant"))
        #expect(base != ManualPromotionPreviewKey(accountID: accountID, kind: .expense, date: date, amount: -10, description: "Merchant"))
        #expect(base != ManualPromotionPreviewKey(accountID: accountID, kind: .charge, date: date.addingTimeInterval(1), amount: -10, description: "Merchant"))
        #expect(base != ManualPromotionPreviewKey(accountID: accountID, kind: .charge, date: date, amount: -11, description: "Merchant"))
        #expect(base != ManualPromotionPreviewKey(accountID: accountID, kind: .charge, date: date, amount: -10, description: "Other merchant"))
    }
}
