import Testing
import Foundation
import SwiftData
@testable import FinanceTracker

@Suite("Category Recovery")
@MainActor
struct CategoryRecoveryTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = AppSchema.schema
        return try ModelContainer(for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    @Test("restores semantic categories and reconnects references idempotently")
    func restoresCategoriesAndReferences() async throws {
        let rootA = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let rootB = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let childA = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        let childB = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
        let duplicateRoot = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let duplicateChild = UUID(uuidString: "00000000-0000-0000-0000-000000000013")!
        let backup = FileManager.default.temporaryDirectory
            .appendingPathComponent("category-recovery-\(UUID()).ftbackup", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: backup) }

        let source = try makeContainer()
        let sourceContext = source.mainContext
        let sourceRootA = Category(id: rootA, name: "Food & Drink")
        let sourceRootB = Category(id: rootB, name: "Travel")
        let sourceChildA = Category(id: childA, name: "Groceries", parent: sourceRootA)
        let sourceChildB = Category(id: childB, name: "Groceries", parent: sourceRootB)
        for category in [sourceRootA, sourceRootB, sourceChildA, sourceChildB] { sourceContext.insert(category) }
        try await BackupArchive.export(to: backup, from: sourceContext)

        let target = try makeContainer()
        let context = target.mainContext
        let root1 = Category(id: rootA, name: "Food & Drink")
        let root2 = Category(id: rootB, name: "Travel")
        let groceries1 = Category(id: childA, name: "Groceries", parent: root1)
        let groceries2 = Category(id: childB, name: "Groceries", parent: root2)
        let duplicateRootCategory = Category(id: duplicateRoot, name: "Food & Drink")
        let duplicateChildCategory = Category(id: duplicateChild, name: "Groceries", parent: duplicateRootCategory)
        root1.deletedAt = .now
        groceries1.deletedAt = .now
        let custom = Category(name: "Custom", parent: root2)
        let account = Account(institution: "Test", type: .checking, currency: "MXN")
        let transaction = Transaction(account: account, postedAt: .now, amount: -50,
                                      descriptionRaw: "Groceries", category: duplicateChildCategory)
        let rule = CategoryRule(patternRegex: "GROCERIES", category: duplicateChildCategory)
        for category in [root1, root2, groceries1, groceries2, duplicateRootCategory,
                         duplicateChildCategory, custom] { context.insert(category) }
        context.insert(account)
        context.insert(transaction)
        context.insert(rule)
        try context.save()

        let preview = try CategoryRecoveryService.preview(backupURL: backup, context: context)
        #expect(preview.categoriesToRestore == 2)
        #expect(preview.duplicateCategoriesToMerge == 2)
        #expect(preview.transactionsToRelink == 1)
        #expect(preview.rulesToRelink == 1)

        let result = try CategoryRecoveryService.recover(backupURL: backup, context: context)
        #expect(result.categoriesRestored == 2)
        #expect(result.duplicateCategoriesMerged == 2)
        #expect(result.transactionsRelinked == 1)
        #expect(result.rulesRelinked == 1)
        #expect(root1.deletedAt == nil)
        #expect(groceries1.deletedAt == nil)
        #expect(duplicateRootCategory.deletedAt != nil)
        #expect(duplicateChildCategory.deletedAt != nil)
        #expect(root2.deletedAt == nil)
        #expect(groceries2.deletedAt == nil)
        #expect(transaction.category?.id == childA)
        #expect(rule.category?.id == childA)
        #expect(custom.parent?.id == rootB)

        let repeated = try CategoryRecoveryService.recover(backupURL: backup, context: context)
        #expect(repeated.categoriesRestored == 0)
        #expect(repeated.duplicateCategoriesMerged == 0)
        #expect(repeated.transactionsRelinked == 0)
    }

    @Test("ambiguous deleted categories require an explicit recovery choice")
    func ambiguousDeletionsRequireChoice() async throws {
        let id = UUID()
        let backup = FileManager.default.temporaryDirectory
            .appendingPathComponent("category-recovery-review-\(UUID()).ftbackup", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: backup) }
        let source = try makeContainer()
        source.mainContext.insert(Category(id: id, name: "Custom Budget", kind: .expense))
        try await BackupArchive.export(to: backup, from: source.mainContext)

        let target = try makeContainer()
        let deleted = Category(id: id, name: "Custom Budget", kind: .expense)
        deleted.deletedAt = .now
        target.mainContext.insert(deleted)
        try target.mainContext.save()

        let preview = try CategoryRecoveryService.preview(backupURL: backup, context: target.mainContext)
        #expect(preview.categoriesToRestore == 0)
        #expect(preview.ambiguousDeletedCategories == ["Custom Budget"])
        let defaultResult = try CategoryRecoveryService.recover(backupURL: backup, context: target.mainContext)
        #expect(defaultResult.categoriesRestored == 0)
        #expect(deleted.deletedAt != nil)

        let confirmedResult = try CategoryRecoveryService.recover(backupURL: backup, context: target.mainContext,
            includeAmbiguousDeletions: true)
        #expect(confirmedResult.categoriesRestored == 1)
        #expect(deleted.deletedAt == nil)
    }
}
