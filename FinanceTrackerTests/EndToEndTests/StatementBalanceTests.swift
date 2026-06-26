import Testing
import Foundation
import SwiftData
@testable import FinanceTracker

@Suite("Statement Balance Extraction")
struct StatementBalanceTests {

    let parser: StructuralParser

    init() {
        guard let p = StructuralParser() else {
            fatalError("StructuralParser() must initialize from bundled JSON knowledge files")
        }
        self.parser = p
    }

    private var openbankPDF: URL? {
        FixtureLoader.optionalURL("01.pdf")
    }

    @Test("Extracts closing balance from each account section")
    func extractsClosingBalances() async throws {
        guard let openbankPDF else { return }
        let data = try Data(contentsOf: openbankPDF)
        let sections = try await parser.parseSections(data: data)

        #expect(sections.count == 2, "Should have 2 sections (Débito + Apartado)")

        let debito = sections.first { $0.accountType == .checking }
        let apartado = sections.first { $0.accountType == .savings }

        #expect(debito != nil, "Should find checking section")
        #expect(apartado != nil, "Should find savings section")

        #expect(debito?.closingBalance == 0, "Débito closing balance should be $0.00")
        #expect(apartado?.closingBalance == 462_480.49, "Apartado closing balance should be $462,480.49")
    }

    @Test("Extracts opening balance from each account section")
    func extractsOpeningBalances() async throws {
        guard let openbankPDF else { return }
        let data = try Data(contentsOf: openbankPDF)
        let sections = try await parser.parseSections(data: data)

        let debito = sections.first { $0.accountType == .checking }
        let apartado = sections.first { $0.accountType == .savings }

        #expect(debito?.openingBalance == 0, "Débito opening balance should be $0.00")
        #expect(apartado?.openingBalance == 394_495.60, "Apartado opening balance should be $394,495.60")
    }

    @Test("March PDF has correct closing balance for Apartado")
    func marchClosingBalance() async throws {
        guard let url = FixtureLoader.optionalURL("03.pdf") else { return }

        let data = try Data(contentsOf: url)
        let sections = try await parser.parseSections(data: data)

        let apartado = sections.first { $0.accountType == .savings }
        #expect(apartado != nil)
        #expect(apartado?.closingBalance == 49_371.09, "March Apartado closing balance should be $49,371.09")
    }

    @Test("February PDF has correct closing balance for Apartado")
    func februaryClosingBalance() async throws {
        guard let url = FixtureLoader.optionalURL("02.pdf") else { return }

        let data = try Data(contentsOf: url)
        let sections = try await parser.parseSections(data: data)

        let apartado = sections.first { $0.accountType == .savings }
        #expect(apartado != nil)
        #expect(apartado?.closingBalance == 470_017.33, "February Apartado closing balance should be $470,017.33")
    }
}

@Suite("Statement Balance Persistence")
@MainActor
struct StatementBalancePersistenceTests {

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
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    @Test("Closing balance stored on Statement after ingest")
    func closingBalancePersisted() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        SeedDataLoader.bootstrapIfNeeded(context: context)

        let pipeline = IngestPipeline(context: context)
        guard let url = FixtureLoader.optionalURL("01.pdf") else { return }
        let reports = await pipeline.ingest(files: [url])
        #expect(reports[0].newTransactions > 0)

        let statements = try context.fetch(FetchDescriptor<Statement>())
        #expect(statements.count == 2, "Should have 2 statements")

        let debito = statements.first { $0.account?.type == .checking }
        let apartado = statements.first { $0.account?.type == .savings }

        #expect(debito?.closingBalance == 0, "Débito closing should be $0.00")
        #expect(apartado?.closingBalance == 462_480.49, "Apartado closing should be $462,480.49")

        #expect(debito?.openingBalance == 0, "Débito opening should be $0.00")
        #expect(apartado?.openingBalance == 394_495.60, "Apartado opening should be $394,495.60")
    }

    @Test("Net worth computed from statement closing balances")
    func netWorthFromStatements() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        SeedDataLoader.bootstrapIfNeeded(context: context)

        let pipeline = IngestPipeline(context: context)
        guard
            let jan = FixtureLoader.optionalURL("01.pdf"),
            let feb = FixtureLoader.optionalURL("02.pdf"),
            let mar = FixtureLoader.optionalURL("03.pdf")
        else { return }
        let urls = [jan, feb, mar]
        let reports = await pipeline.ingest(files: urls)
        #expect(reports.allSatisfy { $0.newTransactions > 0 || $0.errors.isEmpty })

        let viewModel = DashboardViewModel()
        viewModel.configure(context: context)

        guard case .consolidated(let snap) = viewModel.snapshot else {
            Issue.record("Expected consolidated snapshot, got \(viewModel.snapshot)")
            return
        }

        #expect(snap.netWorth == 49_371.09, "Current net worth should be $49,371.09 (March Débito $0 + Apartado $49,371.09)")

        #expect(!snap.netWorthOverTime.isEmpty, "Should have net worth data points")

        if let jan = snap.netWorthOverTime.first {
            let calendar = Calendar(identifier: .gregorian)
            let month = calendar.component(.month, from: jan.month)
            #expect(month == 1, "First point should be January")
            #expect(jan.balance == 462_480.49, "January net worth should be $462,480.49")
        }

        if let mar = snap.netWorthOverTime.last {
            #expect(mar.balance == 49_371.09, "March net worth should be $49,371.09")
        }
    }
}
