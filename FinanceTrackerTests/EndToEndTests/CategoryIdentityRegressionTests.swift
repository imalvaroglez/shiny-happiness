import Foundation
import SwiftData
import Testing
@testable import FinanceTracker

@Suite("Category identity regressions")
@MainActor
struct CategoryIdentityRegressionTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: AppSchema.schema,
                           configurations: ModelConfiguration(schema: AppSchema.schema, isStoredInMemoryOnly: true))
    }

    @Test func repeatedRenamesAndParentAliasesPreserveSeedRules() throws {
        let container = try container()
        let context = container.mainContext
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("category-alias-\(UUID())")
        let url = root.appendingPathComponent("CategoryCustomization.json")
        defer { try? FileManager.default.removeItem(at: root) }
        try SeedDataLoader.bootstrapIfNeeded(context: context, customizationURL: url)
        let categories = try context.fetch(FetchDescriptor<FinanceTracker.Category>())
        let groceries = try #require(categories.first { $0.name == "Groceries" })
        let food = try #require(groceries.parent)
        try CategoryManagementActions.rename(groceries, to: "Salary", context: context, customizationURL: url)
        try CategoryManagementActions.rename(groceries, to: "Despensa", context: context, customizationURL: url)
        try CategoryManagementActions.rename(food, to: "Comida", context: context, customizationURL: url)
        let rules = try context.fetch(FetchDescriptor<CategoryRule>()).filter { $0.category?.id == groceries.id }
        #expect(!rules.isEmpty)
        for rule in rules { context.delete(rule) }
        try context.save()
        try SeedDataLoader.bootstrapIfNeeded(context: context, customizationURL: url)
        try SeedDataLoader.bootstrapIfNeeded(context: context, customizationURL: url)
        #expect(try context.fetch(FetchDescriptor<FinanceTracker.Category>()).count == categories.count)
        #expect(try context.fetch(FetchDescriptor<CategoryRule>()).contains { $0.category?.id == groceries.id })
        let entry = try #require(try CategoryCustomizationStore.read(fileURL: url).entries.first { $0.categoryID == groceries.id })
        #expect(entry.seedName == "Groceries")
        #expect(entry.seedParentName == "Food & Drink")
    }

    @Test func renamedSalaryAndInterestKeepFinancialSemantics() throws {
        let container = try container()
        let context = container.mainContext
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("category-semantics-\(UUID())")
        let url = root.appendingPathComponent("CategoryCustomization.json")
        defer { try? FileManager.default.removeItem(at: root) }
        try SeedDataLoader.bootstrapIfNeeded(context: context, customizationURL: url)
        let categories = try context.fetch(FetchDescriptor<FinanceTracker.Category>())
        let salary = try #require(categories.first { $0.name == "Salary" })
        let interest = try #require(categories.first { $0.name == "Interest" })
        let account = Account(institution: "Synthetic", type: .checking, currency: "MXN", nickname: "Test")
        context.insert(account)
        let salaryTx = Transaction(account: account, postedAt: .now, amount: 50_000, descriptionRaw: "Salary", category: salary)
        let interestTx = Transaction(account: account, postedAt: .now, amount: 100, descriptionRaw: "Interest", category: interest)
        context.insert(salaryTx)
        context.insert(interestTx)
        try context.save()
        let before = HouseholdSettlementReportService.build(monthStart: .now, transactions: [salaryTx, interestTx], setup: .empty)
        try CategoryManagementActions.rename(salary, to: "Sueldo", context: context, customizationURL: url)
        try CategoryManagementActions.rename(interest, to: "Intereses", context: context, customizationURL: url)
        CategoryCustomizationState.shared.refresh(fileURL: url)
        let after = HouseholdSettlementReportService.build(monthStart: .now, transactions: [salaryTx, interestTx], setup: .empty)
        #expect(before.detectedUserSalaryIncome == 50_000)
        #expect(after.detectedUserSalaryIncome == before.detectedUserSalaryIncome)
        #expect(BreakdownSheet.includesInInterestBreakdown(interestTx))
        #expect(!BreakdownSheet.includesInInterestBreakdown(salaryTx))
    }

    @Test func renameFailureRestoresBothStoresAndNoOpDoesNotTouch() throws {
        let container = try container()
        let context = container.mainContext
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rename-fault-\(UUID())")
        let url = root.appendingPathComponent("CategoryCustomization.json")
        defer { try? FileManager.default.removeItem(at: root) }
        try SeedDataLoader.bootstrapIfNeeded(context: context, customizationURL: url)
        let category = try #require(try context.fetch(FetchDescriptor<FinanceTracker.Category>()).first { $0.name == "Food & Drink" })
        let modified = category.lastModifiedAt
        try CategoryManagementActions.rename(category, to: category.name, context: context, customizationURL: url)
        #expect(category.lastModifiedAt == modified)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(throws: Error.self) {
            try CategoryManagementActions.rename(category, to: "Comida", context: context, customizationURL: url,
                                                  saveContext: { _ in throw CocoaError(.fileWriteUnknown) })
        }
        #expect(!context.hasChanges)
        #expect(category.name == "Food & Drink")
        #expect(category.lastModifiedAt == modified)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func corruptCustomizationSuspendsBootstrapAndResetRecovers() throws {
        let container = try container()
        let context = container.mainContext
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("corrupt-category-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("CategoryCustomization.json")
        let corrupt = Data("{ invalid json }".utf8)
        try corrupt.write(to: url)
        #expect(throws: SeedDataLoader.BootstrapError.self) {
            try SeedDataLoader.bootstrapIfNeeded(context: context, customizationURL: url)
        }
        #expect(try Data(contentsOf: url) == corrupt)
        #expect(try context.fetchCount(FetchDescriptor<FinanceTracker.Category>()) == 0)
        try AppDataResetService.resetAllData(context: context,
            spendRequirementsURL: root.appendingPathComponent("SpendRequirements.json"),
            promotionLedgerURL: root.appendingPathComponent("PromotionLedger.json"), categoryCustomizationURL: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try context.fetchCount(FetchDescriptor<FinanceTracker.Category>()) == 80)
    }

    @Test func duplicateCanonicalizationMovesOriginAndTintWithRelationships() throws {
        let container = try container()
        let context = container.mainContext
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("category-canonical-\(UUID())")
        let url = root.appendingPathComponent("CategoryCustomization.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let canonical = Category(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Comida")
        let duplicate = Category(id: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!, name: " comida ")
        context.insert(canonical)
        context.insert(duplicate)
        try context.save()
        try CategoryCustomizationStore.setSeedName(categoryID: duplicate.id, seedName: "Food & Drink",
                                                   kindRaw: CategoryKind.expense.rawValue, at: url)
        try CategoryCustomizationStore.setTint(categoryID: duplicate.id, hex: "#112233", at: url)
        try SeedDataLoader.bootstrapIfNeeded(context: context, customizationURL: url)
        let entries = try CategoryCustomizationStore.read(fileURL: url).entries
        let winner = try #require(entries.first { $0.categoryID == canonical.id })
        #expect(winner.seedName == "Food & Drink")
        #expect(winner.tintHex == "#112233")
        #expect(winner.deletedAt == nil)
        #expect(duplicate.deletedAt != nil)
        #expect(try context.fetch(FetchDescriptor<FinanceTracker.Category>()).filter { $0.deletedAt == nil && $0.name == "Food & Drink" }.isEmpty)
        let groceries = try #require(try context.fetch(FetchDescriptor<FinanceTracker.Category>()).first { $0.name == "Groceries" })
        #expect(groceries.parent?.id == canonical.id)
        #expect(throws: CategoryManagementError.self) {
            try CategoryManagementActions.rename(groceries, to: "  RESTAURANTS\n", context: context, customizationURL: url)
        }
        try SeedDataLoader.bootstrapIfNeeded(context: context, customizationURL: url)
        #expect(try context.fetch(FetchDescriptor<FinanceTracker.Category>()).filter { $0.deletedAt == nil }.count == 80)
    }
}
