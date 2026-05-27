import Testing
import Foundation
import SwiftData
@testable import FinanceTracker

@Suite("Category Repair")
@MainActor
struct CategoryRepairTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            Account.self, AccountBalanceSnapshot.self, Transaction.self,
            Statement.self,
            FinanceTracker.Category.self,
            CategoryRule.self,
            InstallmentPlan.self,
            PendingImport.self,
            SignRecoveryHint.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    @Test("Old-shape Transfers > Credit Card Payments is repaired to top-level creditCardPayment")
    func repairsOldShapeSubcategory() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let transfers = FinanceTracker.Category(name: "Transfers", kind: .transfer)
        context.insert(transfers)
        let oldCCPay = FinanceTracker.Category(name: "Credit Card Payments", parent: transfers, kind: .transfer)
        context.insert(oldCCPay)
        try context.save()

        SeedDataLoader.bootstrapIfNeeded(context: context)

        let allCategories = try context.fetch(FetchDescriptor<FinanceTracker.Category>())
        let repaired = allCategories.first {
            $0.name == "Credit Card Payments" && $0.deletedAt == nil
        }
        #expect(repaired != nil, "Credit Card Payments should exist")
        #expect(repaired?.kind == .creditCardPayment,
                "Expected kind .creditCardPayment, got \(repaired?.kind.rawValue ?? "nil")")
        #expect(repaired?.parent == nil,
                "Repaired category should be top-level, not a subcategory")

        let subs = allCategories.filter { $0.parent?.id == repaired?.id && $0.deletedAt == nil }
        let subNames = Set(subs.map(\.name))
        #expect(subNames.contains("Card Payment Received"))
        #expect(subNames.contains("Card Payment Sent"))
    }

    @Test("Transactions pointing at old category pick up corrected kind automatically")
    func transactionsInheritRepairedKind() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let transfers = FinanceTracker.Category(name: "Transfers", kind: .transfer)
        context.insert(transfers)
        let oldCCPay = FinanceTracker.Category(name: "Credit Card Payments", parent: transfers, kind: .transfer)
        context.insert(oldCCPay)

        let account = Account(institution: "Test", type: .creditCard, currency: "MXN")
        context.insert(account)
        let tx = Transaction(
            account: account,
            postedAt: .now,
            amount: 25986,
            descriptionRaw: "SU PAGO GRACIAS SPEI",
            category: oldCCPay
        )
        context.insert(tx)
        try context.save()

        SeedDataLoader.bootstrapIfNeeded(context: context)

        #expect(tx.category?.kind == .creditCardPayment,
                "Transaction should see repaired kind .creditCardPayment, got \(tx.category?.kind.rawValue ?? "nil")")
    }

    @Test("Duplicate Credit Card Payments categories are canonicalized")
    func canonicalizesDuplicates() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let transfers = FinanceTracker.Category(name: "Transfers", kind: .transfer)
        context.insert(transfers)
        let oldCCPay = FinanceTracker.Category(name: "Credit Card Payments", parent: transfers, kind: .transfer)
        context.insert(oldCCPay)
        let newCCPay = FinanceTracker.Category(name: "Credit Card Payments", kind: .creditCardPayment)
        context.insert(newCCPay)
        let newSub = FinanceTracker.Category(name: "Card Payment Sent", parent: newCCPay, kind: .creditCardPayment)
        context.insert(newSub)

        let account = Account(institution: "Test", type: .checking, currency: "MXN")
        context.insert(account)
        let txOnOld = Transaction(
            account: account,
            postedAt: .now,
            amount: -5000,
            descriptionRaw: "SPEI enviada a 2now HSBC",
            category: oldCCPay
        )
        context.insert(txOnOld)

        let ruleOnOld = CategoryRule(
            patternRegex: "(?i)test-pattern",
            category: oldCCPay,
            priority: 50
        )
        context.insert(ruleOnOld)
        try context.save()

        SeedDataLoader.bootstrapIfNeeded(context: context)

        let allCategories = try context.fetch(FetchDescriptor<FinanceTracker.Category>())
        let activeCCPay = allCategories.filter {
            $0.name == "Credit Card Payments" && $0.deletedAt == nil
        }
        #expect(activeCCPay.count == 1,
                "Should have exactly one active Credit Card Payments, got \(activeCCPay.count)")
        let canonical = activeCCPay[0]
        #expect(canonical.kind == .creditCardPayment)
        #expect(canonical.parent == nil)

        #expect(txOnOld.category?.id == canonical.id,
                "Transaction should be reassigned to canonical category")
        #expect(ruleOnOld.category?.id == canonical.id,
                "Rule should be reassigned to canonical category")

        let softDeleted = allCategories.filter {
            $0.name == "Credit Card Payments" && $0.deletedAt != nil
        }
        #expect(softDeleted.count == 1,
                "Old duplicate should be soft-deleted")
    }

    @Test("Seed rules resolve to repaired canonical Credit Card Payments category")
    func seedRulesResolveAfterRepair() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let transfers = FinanceTracker.Category(name: "Transfers", kind: .transfer)
        context.insert(transfers)
        let oldCCPay = FinanceTracker.Category(name: "Credit Card Payments", parent: transfers, kind: .transfer)
        context.insert(oldCCPay)
        try context.save()

        SeedDataLoader.bootstrapIfNeeded(context: context)

        let allCategories = try context.fetch(FetchDescriptor<FinanceTracker.Category>())
        let canonical = allCategories.first {
            $0.name == "Credit Card Payments" && $0.deletedAt == nil
        }
        #expect(canonical != nil)

        let allRules = try context.fetch(FetchDescriptor<CategoryRule>())
        let ccRules = allRules.filter {
            $0.category?.parent?.id == canonical?.id || $0.category?.id == canonical?.id
        }
        #expect(!ccRules.isEmpty,
                "Seed rules targeting Credit Card Payments should resolve to the canonical or its subcategories")
        #expect(ccRules.allSatisfy {
            $0.category?.kind == .creditCardPayment || $0.category?.parent?.kind == .creditCardPayment
        },
                "All resolved rules should point to a .creditCardPayment category or subcategory")

        let tx = Transaction(
            postedAt: .now,
            amount: -25986,
            descriptionRaw: "SPEI enviada a 2now 3803, HSBC, 2026010240169176737337285"
        )
        let result = Categorizer.categorize(transactions: [tx], rules: allRules)
        #expect(result.categorized == 1)
        #expect(tx.category?.kind == .creditCardPayment,
                "Categorized transaction should have .creditCardPayment kind")
    }

    @Test("Idempotent: running repair twice does not create duplicates")
    func idempotentRepair() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let transfers = FinanceTracker.Category(name: "Transfers", kind: .transfer)
        context.insert(transfers)
        let oldCCPay = FinanceTracker.Category(name: "Credit Card Payments", parent: transfers, kind: .transfer)
        context.insert(oldCCPay)
        try context.save()

        SeedDataLoader.bootstrapIfNeeded(context: context)
        SeedDataLoader.bootstrapIfNeeded(context: context)

        let allCategories = try context.fetch(FetchDescriptor<FinanceTracker.Category>())
        let activeCCPay = allCategories.filter {
            $0.name == "Credit Card Payments" && $0.deletedAt == nil
        }
        #expect(activeCCPay.count == 1,
                "Idempotent repair should not create duplicates")
    }
}
