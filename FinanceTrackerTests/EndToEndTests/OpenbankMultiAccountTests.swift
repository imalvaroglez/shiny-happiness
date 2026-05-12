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
        let url = URL(fileURLWithPath: "/Users/developer/Documents/GitHub/shiny-happiness/samples/01.pdf")
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
            let kind = tx.category?.kind
            #expect(
                kind == .transfer || kind == .creditCardPayment,
                "Transfer '\(tx.descriptionRaw)' should be .transfer or .creditCardPayment, got \(tx.category?.name ?? "nil")"
            )
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

    @Test("Cash flow excludes only internal transfers, includes SPEI")
    func testCashFlowExcludesInternalTransfers() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        SeedDataLoader.bootstrapIfNeeded(context: context)
        _ = await ingestOpenbankPDF(context: context)

        let transactions = try context.fetch(FetchDescriptor<Transaction>())

        var totalIncome: Decimal = 0
        var totalExpenses: Decimal = 0
        for tx in transactions {
            if tx.category?.kind == .transfer { continue }
            if tx.amount > 0 {
                totalIncome += tx.amount
            } else {
                totalExpenses += tx.amount
            }
        }

        let internalTransfers = transactions.filter { $0.category?.name == "Internal Transfer" }
        #expect(!internalTransfers.isEmpty, "Should have internal transfer transactions")

        let speiTransfers = transactions.filter { tx in
            guard let cat = tx.category else { return false }
            return cat.kind == .transfer && cat.name != "Internal Transfer"
        }
        #expect(!speiTransfers.isEmpty, "Should have SPEI transfer transactions (To Own Accounts or Credit Card Payments)")

        let speiOutgoing = speiTransfers.filter { $0.amount < 0 }
        #expect(!speiOutgoing.isEmpty, "Should have outgoing SPEI transfers")

        #expect(totalIncome > 0, "Should have income (excluding all transfers)")
        #expect(totalExpenses < 0, "Should have expenses (excluding all transfers)")
    }

    @Test("Reimporting same institution reuses Account — no duplicates")
    func testNoAccountDuplicates() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        SeedDataLoader.bootstrapIfNeeded(context: context)

        let pipeline = IngestPipeline(context: context)
        let url1 = URL(fileURLWithPath: "/Users/developer/Documents/GitHub/shiny-happiness/samples/01.pdf")
        let url2 = URL(fileURLWithPath: "/Users/developer/Documents/GitHub/shiny-happiness/samples/02.pdf")
        _ = await pipeline.ingest(files: [url1, url2])

        let accounts = try context.fetch(FetchDescriptor<Account>())
        #expect(accounts.count == 2, "Should have exactly 2 accounts (Débito + Apartados), got \(accounts.count)")

        let checkingAccounts = accounts.filter { $0.type == .checking }
        let savingsAccounts = accounts.filter { $0.type == .savings }
        #expect(checkingAccounts.count == 1, "Should have exactly 1 checking account")
        #expect(savingsAccounts.count == 1, "Should have exactly 1 savings account")
    }

    @Test("Apartado section parses deposits, interest, and ISR — not just withdrawals")
    func testApartadoDepositTransactions() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        SeedDataLoader.bootstrapIfNeeded(context: context)

        let pipeline = IngestPipeline(context: context)
        let url = URL(fileURLWithPath: "/Users/developer/Documents/GitHub/shiny-happiness/samples/01.pdf")
        _ = await pipeline.ingest(files: [url])

        let transactions = try context.fetch(FetchDescriptor<Transaction>())
        let savingsAccount = try context.fetch(FetchDescriptor<Account>()).first { $0.type == .savings }
        #expect(savingsAccount != nil, "Should have a savings account")

        let apartadoTx = transactions.filter { $0.account?.id == savingsAccount?.id }
        #expect(apartadoTx.count >= 40, "Apartado should have at least 40 transactions (interest + deposits + withdrawals + ISR), got \(apartadoTx.count)")

        let interestTx = apartadoTx.filter { $0.descriptionRaw.localizedCaseInsensitiveContains("intereses") }
        #expect(interestTx.count >= 20, "Should have at least 20 'Abono de intereses' transactions, got \(interestTx.count)")

        let isrTx = apartadoTx.filter { $0.descriptionRaw.localizedCaseInsensitiveContains("ISR") }
        #expect(isrTx.count >= 10, "Should have at least 10 'ISR retenido' transactions, got \(isrTx.count)")

        let depositTx = apartadoTx.filter { $0.descriptionRaw.localizedCaseInsensitiveContains("Abono desde") }
        #expect(depositTx.count >= 10, "Should have at least 10 'Abono desde' deposit transactions, got \(depositTx.count)")

        let interestIncome = interestTx.filter { $0.amount > 0 }.reduce(Decimal.zero) { $0 + $1.amount }
        #expect(interestIncome > 3000, "Interest income should be >$3000 for January, got \(interestIncome)")
    }
}
