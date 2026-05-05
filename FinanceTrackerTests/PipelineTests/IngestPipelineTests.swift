import Testing
import Foundation
import SwiftData
@testable import FinanceTracker

@Suite("Ingest Pipeline")
@MainActor
struct IngestPipelineTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            Account.self,
            Transaction.self,
            Statement.self,
            Category.self,
            CategoryRule.self,
        ])
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true
        )
        return try ModelContainer(for: schema, configurations: [config])
    }

    @Test("Ingests Openbank PDF and creates transactions")
    func ingestsOpenbankPDF() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let pipeline = IngestPipeline(context: context)

        let url = URL(fileURLWithPath: "/Users/developer/Documents/GitHub/shiny-happiness/samples/202508.pdf")
        let reports = await pipeline.ingest(files: [url])

        #expect(reports.count == 1)
        let report = reports[0]
        #expect(report.fileName == "202508.pdf")
        #expect(report.newTransactions > 0)
        #expect(report.errors.isEmpty)

        let accountDescriptor = FetchDescriptor<Account>()
        let accounts = try context.fetch(accountDescriptor)
        #expect(accounts.count == 1)
        #expect(accounts[0].institution == "Openbank Mexico")
        #expect(accounts[0].type == .checking)

        let txDescriptor = FetchDescriptor<Transaction>()
        let transactions = try context.fetch(txDescriptor)
        #expect(transactions.count == report.newTransactions)
    }

    @Test("Rejects encrypted PDF gracefully")
    func rejectsEncryptedPDF() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let pipeline = IngestPipeline(context: context)

        let url = URL(fileURLWithPath: "/Users/developer/Documents/GitHub/shiny-happiness/samples/202302.pdf")
        let reports = await pipeline.ingest(files: [url])

        #expect(reports.count == 1)
    }

    @Test("Detects already-imported statement by hash")
    func detectsDuplicateStatement() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let pipeline = IngestPipeline(context: context)

        let url = URL(fileURLWithPath: "/Users/developer/Documents/GitHub/shiny-happiness/samples/202508.pdf")

        let firstReports = await pipeline.ingest(files: [url])
        #expect(firstReports[0].newTransactions > 0)

        let secondReports = await pipeline.ingest(files: [url])
        #expect(secondReports[0].duplicateTransactions > 0)
        #expect(secondReports[0].newTransactions == 0)
    }

    @Test("Auto-creates account for new institution")
    func autoCreatesAccount() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let pipeline = IngestPipeline(context: context)

        let url = URL(fileURLWithPath: "/Users/developer/Documents/GitHub/shiny-happiness/samples/202508.pdf")
        _ = await pipeline.ingest(files: [url])

        let descriptor = FetchDescriptor<Account>()
        let accounts = try context.fetch(descriptor)

        #expect(accounts.count == 1)
        #expect(accounts[0].institution == "Openbank Mexico")
        #expect(accounts[0].type == .checking)
    }

    @Test("Reuses existing account for same institution")
    func reusesExistingAccount() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let pipeline = IngestPipeline(context: context)

        let url = URL(fileURLWithPath: "/Users/developer/Documents/GitHub/shiny-happiness/samples/202508.pdf")
        _ = await pipeline.ingest(files: [url])
        _ = await pipeline.ingest(files: [url])

        let descriptor = FetchDescriptor<Account>()
        let accounts = try context.fetch(descriptor)

        #expect(accounts.count == 1)
    }

    @Test("Handles nonexistent file gracefully")
    func handlesNonexistentFile() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let pipeline = IngestPipeline(context: context)

        let url = URL(fileURLWithPath: "/nonexistent/file.pdf")
        let reports = await pipeline.ingest(files: [url])

        #expect(reports.count == 1)
        #expect(reports[0].errorCount == 1)
        #expect(!reports[0].errors.isEmpty)
    }

    @Test("Ingests Amex PDF with restricted-but-readable access")
    func ingestsAmexPDF() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let pipeline = IngestPipeline(context: context)

        let url = URL(fileURLWithPath: "/Users/developer/Documents/GitHub/shiny-happiness/samples/201901.pdf")
        let reports = await pipeline.ingest(files: [url])

        #expect(reports.count == 1)

        let descriptor = FetchDescriptor<Account>()
        let accounts = try context.fetch(descriptor)
        #expect(accounts.count == 1)
        #expect(accounts[0].institution == "American Express Mexico")
        #expect(accounts[0].type == .creditCard)
    }
}
