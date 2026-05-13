import Testing
import Foundation
import SwiftData
@testable import FinanceTracker

@Suite("End-to-End PDF Import")
@MainActor
struct EndToEndPDFTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            Account.self,
            Transaction.self,
            Statement.self,
            Category.self,
            CategoryRule.self,
            InstallmentPlan.self,
            PendingImport.self,
            SignRecoveryHint.self,
        ])
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true
        )
        return try ModelContainer(for: schema, configurations: [config])
    }

    @Test("Amex PDF produces transactions via full ingest pipeline")
    func amexPDFProducesTransactions() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let pipeline = IngestPipeline(context: context)

        let url = URL(fileURLWithPath: "/Users/imalvaroglez/Documents/GitHub/shiny-happiness/samples/201901.pdf")
        // SKIPPED: fixture PDF not in samples/
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let reports = await pipeline.ingest(files: [url])

        #expect(reports.count == 1)
        let report = reports[0]
        #expect(report.newTransactions > 0, "Amex PDF should produce at least one transaction")
        #expect(report.errors.isEmpty, "Amex PDF should not produce errors: \(report.errors.map(\.message))")

        let txDescriptor = FetchDescriptor<Transaction>()
        let transactions = try context.fetch(txDescriptor)
        #expect(!transactions.isEmpty)

        let credits = transactions.filter { $0.amount > 0 }
        let charges = transactions.filter { $0.amount < 0 }
        #expect(!credits.isEmpty, "Should have at least one credit (payment)")
        #expect(!charges.isEmpty, "Should have at least one charge")

        let payment = transactions.first { $0.descriptionRaw.localizedCaseInsensitiveContains("PAGO RECIBIDO") }
        #expect(payment != nil, "Should find 'PAGO RECIBIDO' transaction")
        #expect(payment!.amount > 0, "Payment should be positive")
    }

    @Test("Openbank PDF produces transactions via full ingest pipeline")
    func openbankPDFProducesTransactions() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let pipeline = IngestPipeline(context: context)

        let url = URL(fileURLWithPath: "/Users/imalvaroglez/Documents/GitHub/shiny-happiness/samples/01.pdf")
        let reports = await pipeline.ingest(files: [url])

        #expect(reports.count == 1)
        let report = reports[0]
        #expect(report.newTransactions > 0, "Openbank PDF should produce at least one transaction")
        #expect(report.errors.isEmpty, "Openbank PDF should not produce errors: \(report.errors.map(\.message))")

        let txDescriptor = FetchDescriptor<Transaction>()
        let transactions = try context.fetch(txDescriptor)
        #expect(!transactions.isEmpty)

        let deposits = transactions.filter { $0.amount > 0 }
        let withdrawals = transactions.filter { $0.amount < 0 }
        #expect(!deposits.isEmpty, "Should have at least one deposit")
        #expect(!withdrawals.isEmpty, "Should have at least one withdrawal")
    }
}
