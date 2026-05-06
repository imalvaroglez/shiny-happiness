import Testing
import Foundation
import SwiftData
@testable import FinanceTracker

@Suite("Openbank Multi-Account")
@MainActor
struct OpenbankMultiAccountTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            Account.self,
            Transaction.self,
            Statement.self,
            Category.self,
            CategoryRule.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    private func ingestOpenbankPDF(context: ModelContext) async -> IngestReport {
        let pipeline = IngestPipeline(context: context)
        let url = URL(fileURLWithPath: "/Users/imalvaroglez/Documents/GitHub/shiny-happiness/samples/01.pdf")
        let reports = await pipeline.ingest(files: [url])
        return reports[0]
    }

    @Test("Openbank PDF produces two accounts")
    func testTwoAccounts() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        SeedDataLoader.bootstrapIfNeeded(context: context)

        let report = await ingestOpenbankPDF(context: context)
        #expect(report.newTransactions > 0)
        #expect(report.errors.isEmpty)

        let accounts = try context.fetch(FetchDescriptor<Account>())
        #expect(accounts.count == 2, "Should create 2 accounts (Débito + Apartados)")

        let types = Set(accounts.map(\.type))
        #expect(types.contains(.checking), "Should have a checking account")
        #expect(types.contains(.savings), "Should have a savings account")
    }

    @Test("Internal transfers categorized correctly")
    func testInternalTransfersCategorized() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        SeedDataLoader.bootstrapIfNeeded(context: context)
        _ = await ingestOpenbankPDF(context: context)

        let transactions = try context.fetch(FetchDescriptor<Transaction>())

        let transfers = transactions.filter { tx in
            tx.descriptionRaw.localizedCaseInsensitiveContains("Traspaso") ||
            tx.descriptionRaw.localizedCaseInsensitiveContains("Fantasy") ||
            tx.descriptionRaw.localizedCaseInsensitiveContains("Tdc explora") ||
            tx.descriptionRaw.localizedCaseInsensitiveContains("Pago tdc")
        }

        #expect(!transfers.isEmpty, "Should find internal transfer transactions")

        for tx in transfers {
            #expect(tx.category?.kind == .transfer, "Transfer '\(tx.descriptionRaw)' should have transfer category, got \(tx.category?.name ?? "nil")")
        }
    }

    @Test("Interest income categorized correctly")
    func testInterestIncomeCategorized() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        SeedDataLoader.bootstrapIfNeeded(context: context)
        _ = await ingestOpenbankPDF(context: context)

        let transactions = try context.fetch(FetchDescriptor<Transaction>())

        let interest = transactions.filter { tx in
            tx.descriptionRaw.localizedCaseInsensitiveContains("intereses")
        }

        for tx in interest {
            let isIncome = tx.category?.kind == .income || (tx.category == nil && tx.amount > 0)
            #expect(isIncome, "'\(tx.descriptionRaw)' should be income, got \(tx.category?.name ?? "uncategorized")")
        }
    }

    @Test("Cash flow excludes internal transfers")
    func testCashFlowExcludesTransfers() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        SeedDataLoader.bootstrapIfNeeded(context: context)
        _ = await ingestOpenbankPDF(context: context)

        let transactions = try context.fetch(FetchDescriptor<Transaction>())

        var totalIncome: Decimal = 0
        var totalExpenses: Decimal = 0
        for tx in transactions {
            let kind = tx.category?.kind
            if kind == .transfer { continue }
            if kind == .income || (kind == nil && tx.amount > 0) {
                totalIncome += tx.amount
            } else if kind == .expense || kind == .investment || (kind == nil && tx.amount < 0) {
                totalExpenses += tx.amount
            }
        }

        let transfers = transactions.filter { $0.category?.kind == .transfer }
        let transferTotal = transfers.reduce(Decimal.zero) { $0 + $1.amount }

        #expect(transfers.count > 0, "Should have transfer transactions")
        #expect(transferTotal != 0, "Transfers should have non-zero amounts")

        let hasTransferInIncome = transfers.contains { $0.amount > 0 }
        #expect(hasTransferInIncome, "Some transfers are positive (deposits)")

        #expect(totalIncome > 0, "Should have non-transfer income")
    }
}
