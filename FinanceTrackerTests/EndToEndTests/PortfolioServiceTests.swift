import Testing
import Foundation
import SwiftData
@testable import FinanceTracker

@Suite("Portfolio Service")
@MainActor
struct PortfolioServiceTests {
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(schema: AppSchema.schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: AppSchema.schema, configurations: [config])
    }

    @Test("Add position then buy more updates weighted average cost")
    func buyMoreWeightedAverage() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(institution: "Broker", type: .investment, nickname: "Broker")
        context.insert(account)
        try context.save()

        let position = try PortfolioService.addPosition(
            account: account,
            emisoraSerie: "FEMSAUBD",
            name: nil,
            shares: 10,
            averageCost: 100,
            context: context
        )
        #expect(position.shares == 10)
        #expect(position.averageCost == 100)

        try PortfolioService.buyMore(position: position, addedShares: 10, buyPrice: 120, context: context)
        #expect(position.shares == 20)
        #expect(position.averageCost == 110)
    }

    @Test("Duplicate ticker is rejected")
    func rejectsDuplicateTicker() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(institution: "Broker", type: .investment, nickname: "Broker")
        context.insert(account)
        _ = try PortfolioService.addPosition(account: account, emisoraSerie: "FEMSAUBD", name: nil, shares: 5, averageCost: 100, context: context)

        do {
            _ = try PortfolioService.addPosition(account: account, emisoraSerie: " femsaubd ", name: nil, shares: 5, averageCost: 100, context: context)
            Issue.record("expected duplicate ticker")
        } catch PortfolioService.ValidationError.duplicateTicker {
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("Spaced BMV series are stored in provider format")
    func normalizesSpacedBMVSeries() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(institution: "Broker", type: .investment, nickname: "Broker")
        context.insert(account)

        let amx = try PortfolioService.addPosition(account: account, emisoraSerie: " amx b ", name: nil, shares: 1, averageCost: 1, context: context)
        let cemex = try PortfolioService.addPosition(account: account, emisoraSerie: "CEMEX CPO", name: nil, shares: 1, averageCost: 1, context: context)
        let gfnorte = try PortfolioService.addPosition(account: account, emisoraSerie: "GFNORTE O", name: nil, shares: 1, averageCost: 1, context: context)

        #expect(amx.emisoraSerie == "AMXB")
        #expect(cemex.emisoraSerie == "CEMEXCPO")
        #expect(gfnorte.emisoraSerie == "GFNORTEO")
    }

    @Test("SIC suffixes are stored in canonical form")
    func normalizesSICSuffixes() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(institution: "Broker", type: .investment, nickname: "Broker")
        context.insert(account)

        let voo = try PortfolioService.addPosition(account: account, emisoraSerie: "VOO.MX", name: nil, shares: 1, averageCost: 1, context: context)
        let ibm = try PortfolioService.addPosition(account: account, emisoraSerie: "IBM*", name: nil, shares: 1, averageCost: 1, context: context)

        #expect(voo.emisoraSerie == "VOO")
        #expect(ibm.emisoraSerie == "IBM")
    }

    @Test("Eligibility blocks investment accounts with manual anchors")
    func eligibility() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let empty = Account(institution: "Broker", type: .investment, nickname: "Broker")
        context.insert(empty)
        #expect(PortfolioService.canAddPositions(account: empty, context: context))

        let cetes = Account(institution: "CI Banco", type: .investment, nickname: "CETES")
        context.insert(cetes)
        context.insert(AccountBalanceSnapshot(account: cetes, date: .now, amount: 1_000, kind: .manualOpening))
        try context.save()
        #expect(!PortfolioService.canAddPositions(account: cetes, context: context))
    }

    @Test("New zero-balance investment account can add positions")
    func zeroOpeningInvestmentCanAddPositions() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = try AccountCreationService.create(
            kind: .investment,
            name: "Broker",
            institution: "Broker",
            accountNumber: nil,
            currency: "MXN",
            openingAmount: 0,
            creditLimit: nil,
            tintHex: nil,
            context: context
        )

        #expect(PortfolioService.canAddPositions(account: account, context: context))
    }

    @Test("Emptied portfolio can restart")
    func emptiedPortfolioRestart() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(institution: "Broker", type: .investment, nickname: "Broker")
        context.insert(account)
        context.insert(AccountBalanceSnapshot(account: account, date: .now, amount: 0, kind: .portfolioValuation))
        try context.save()

        #expect(PortfolioService.canAddPositions(account: account, context: context))
    }

    @Test("Deleting the last position writes a zero portfolio valuation")
    func finalDeleteWritesZeroSnapshot() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(institution: "Broker", type: .investment, nickname: "Broker")
        context.insert(account)
        let position = try PortfolioService.addPosition(account: account, emisoraSerie: "FEMSAUBD", name: nil, shares: 5, averageCost: 100, context: context)
        context.insert(AccountBalanceSnapshot(account: account, date: .now.addingTimeInterval(-3_600), amount: 500, kind: .portfolioValuation))
        try context.save()

        try PortfolioService.delete(position: position, account: account, context: context)

        let snapshots = try context.fetch(FetchDescriptor<AccountBalanceSnapshot>())
        let zeroValuations = snapshots.filter { $0.kind == .portfolioValuation && $0.amount == 0 }
        #expect(zeroValuations.count == 1)
        #expect(PortfolioService.activePositions(accountID: account.id, context: context).isEmpty)
    }

    @Test("Portfolio mode means active positions exist")
    func portfolioMode() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(institution: "Broker", type: .investment, nickname: "Broker")
        context.insert(account)
        try context.save()

        #expect(!PortfolioService.inPortfolioMode(account: account, context: context))
        _ = try PortfolioService.addPosition(account: account, emisoraSerie: "FEMSAUBD", name: nil, shares: 5, averageCost: 100, context: context)
        #expect(PortfolioService.inPortfolioMode(account: account, context: context))
    }
}
