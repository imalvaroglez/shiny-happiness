import Testing
import Foundation
import SwiftData
import CryptoKit
@testable import FinanceTracker

@Suite("Ingest Pipeline")
@MainActor
struct IngestPipelineTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            Account.self, AccountBalanceSnapshot.self, Transaction.self,
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

    @Test("Ingests Openbank PDF and creates transactions")
    func ingestsOpenbankPDF() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let pipeline = IngestPipeline(context: context)

        guard let url = FixtureLoader.optionalURL("01.pdf") else { return }
        let reports = await pipeline.ingest(files: [url])

        #expect(reports.count == 1)
        let report = reports[0]
        #expect(report.fileName == "01.pdf")
        #expect(report.newTransactions > 0)
        #expect(report.errors.isEmpty)

        let accountDescriptor = FetchDescriptor<Account>()
        let accounts = try context.fetch(accountDescriptor)
        #expect(accounts.count == 2)
        let institutionNames = Set(accounts.map(\.institution))
        #expect(institutionNames == ["Openbank Mexico"])

        let txDescriptor = FetchDescriptor<Transaction>()
        let transactions = try context.fetch(txDescriptor)
        #expect(transactions.count == report.newTransactions)
    }

    @Test("Rejects encrypted PDF gracefully")
    func rejectsEncryptedPDF() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let pipeline = IngestPipeline(context: context)

        // SKIPPED: fixture PDF not in samples/
        guard let url = FixtureLoader.optionalURL("202302.pdf") else { return }
        let reports = await pipeline.ingest(files: [url])

        #expect(reports.count == 1)
    }

    @Test("Detects already-imported statement by hash")
    func detectsDuplicateStatement() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let pipeline = IngestPipeline(context: context)

        guard let url = FixtureLoader.optionalURL("01.pdf") else { return }

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

        guard let url = FixtureLoader.optionalURL("01.pdf") else { return }
        _ = await pipeline.ingest(files: [url])

        let descriptor = FetchDescriptor<Account>()
        let accounts = try context.fetch(descriptor)

        #expect(accounts.count == 2)
        let institutionNames = Set(accounts.map(\.institution))
        #expect(institutionNames == ["Openbank Mexico"])
    }

    @Test("Reuses existing account for same institution")
    func reusesExistingAccount() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let pipeline = IngestPipeline(context: context)

        guard let url = FixtureLoader.optionalURL("01.pdf") else { return }
        _ = await pipeline.ingest(files: [url])
        _ = await pipeline.ingest(files: [url])

        let descriptor = FetchDescriptor<Account>()
        let accounts = try context.fetch(descriptor)

        #expect(accounts.count == 2)
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

        // SKIPPED: fixture PDF not in samples/
        guard let url = FixtureLoader.optionalURL("201901.pdf") else { return }
        let reports = await pipeline.ingest(files: [url])

        #expect(reports.count == 1)

        let descriptor = FetchDescriptor<Account>()
        let accounts = try context.fetch(descriptor)
        #expect(accounts.count == 1)
        #expect(accounts[0].institution == "American Express Mexico")
        #expect(accounts[0].type == .creditCard)
    }

    @Test("Duplicate statement import repairs stale non-nil metadata")
    func duplicateStatementRepairsMetadata() async throws {
        guard let url = FixtureLoader.optionalURL("12_abr_2026_-_11_may_2026.pdf") else { return }

        let container = try makeContainer()
        let context = container.mainContext
        let data = try Data(contentsOf: url)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

        let account = Account(institution: "American Express Mexico", type: .creditCard, currency: "MXN")
        context.insert(account)
        let wrongStatement = Statement(
            account: account,
            periodStart: Date(timeIntervalSince1970: 0),
            periodEnd: Date(timeIntervalSince1970: 0),
            sourceFileHash: hash,
            closingBalance: -6195.33
        )
        context.insert(wrongStatement)
        try context.save()

        let pipeline = IngestPipeline(context: context)
        let reports = await pipeline.ingest(files: [url])

        #expect(reports[0].newTransactions == 0)
        #expect(wrongStatement.closingBalance == -33996.87)
        #expect(wrongStatement.paymentForNoInterest == 13802.95)
        #expect(wrongStatement.minimumPayment == 3600.00)
        let due = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: wrongStatement.paymentDueDate ?? .distantPast)
        #expect(due.year == 2026 && due.month == 6 && due.day == 1)
    }
}
