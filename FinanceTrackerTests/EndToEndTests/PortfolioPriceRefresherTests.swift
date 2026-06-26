import Testing
import Foundation
import SwiftData
@testable import FinanceTracker

@Suite("Portfolio Price Refresher")
@MainActor
struct PortfolioPriceRefresherTests {
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(schema: AppSchema.schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: AppSchema.schema, configurations: [config])
    }

    @Test("Full refresh writes prices and authoritative valuation snapshot")
    func fullRefreshWritesValuationSnapshot() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(institution: "Broker", type: .investment, nickname: "Broker")
        context.insert(account)
        let femsa = try PortfolioService.addPosition(
            account: account,
            emisoraSerie: "FEMSAUBD",
            name: nil,
            shares: 10,
            averageCost: 100,
            context: context
        )
        let gfnorte = try PortfolioService.addPosition(
            account: account,
            emisoraSerie: "GFNORTEO",
            name: nil,
            shares: 2,
            averageCost: 125,
            context: context
        )
        femsa.lastModifiedAt = .distantPast
        gfnorte.lastModifiedAt = .distantPast
        try context.save()

        let quotedAt = Date(timeIntervalSince1970: 1_780_000_000)
        let outcome = await PortfolioPriceRefresher.refresh(account: account, context: context) { tickers in
            #expect(Set(tickers) == Set(["FEMSAUBD", "GFNORTEO"]))
            return [
                "FEMSAUBD": DataBursatilClient.PriceSnapshot(price: 150, timestamp: quotedAt),
                "GFNORTEO": DataBursatilClient.PriceSnapshot(price: 200, timestamp: quotedAt),
            ]
        }

        #expect(outcome == .priced)
        #expect(femsa.lastPrice == 150)
        #expect(femsa.lastPriceAt == quotedAt)
        #expect(femsa.lastModifiedAt == .distantPast)
        #expect(gfnorte.lastPrice == 200)
        #expect(gfnorte.lastPriceAt == quotedAt)
        #expect(gfnorte.lastModifiedAt == .distantPast)

        let snapshot = try #require(try context.fetch(FetchDescriptor<AccountBalanceSnapshot>())
            .first { $0.kind == .portfolioValuation })
        #expect(snapshot.amount == 1_900)
        let expectedFingerprint = HoldingsFingerprint.of([
            ("FEMSAUBD", 10, 100),
            ("GFNORTEO", 2, 125),
        ])
        #expect(snapshot.note == "Portfolio valuation |fp=\(expectedFingerprint)")

        let resolution = AccountBalanceResolver.resolution(account: account, asOf: .distantFuture, context: context)
        #expect(resolution.amount == 1_900)
        #expect(resolution.sourceSnapshotKind == .portfolioValuation)
    }

    @Test("Partial refresh keeps prior valuation snapshot")
    func partialRefreshDoesNotWriteValuationSnapshot() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(institution: "Broker", type: .investment, nickname: "Broker")
        context.insert(account)
        let femsa = try PortfolioService.addPosition(
            account: account,
            emisoraSerie: "FEMSAUBD",
            name: nil,
            shares: 10,
            averageCost: 100,
            context: context
        )
        let gfnorte = try PortfolioService.addPosition(
            account: account,
            emisoraSerie: "GFNORTEO",
            name: nil,
            shares: 2,
            averageCost: 125,
            context: context
        )
        context.insert(AccountBalanceSnapshot(
            account: account,
            date: Date.now.addingTimeInterval(-3_600),
            amount: 555,
            kind: .portfolioValuation,
            note: "Portfolio valuation |fp=old"
        ))
        try context.save()

        let outcome = await PortfolioPriceRefresher.refresh(account: account, context: context) { _ in
            [
                "FEMSAUBD": DataBursatilClient.PriceSnapshot(price: 150, timestamp: nil),
            ]
        }

        #expect(outcome == .partial(missing: ["GFNORTEO"]))
        #expect(femsa.lastPrice == 150)
        #expect(femsa.lastPriceAt != nil)
        #expect(gfnorte.lastPrice == nil)
        #expect(try context.fetchCount(FetchDescriptor<AccountBalanceSnapshot>()) == 1)
        let resolution = AccountBalanceResolver.resolution(account: account, asOf: .distantFuture, context: context)
        #expect(resolution.amount == 555)
        #expect(resolution.sourceSnapshotNote == "Portfolio valuation |fp=old")
    }

    @Test("Empty account does not fetch prices")
    func emptyAccountDoesNotFetchPrices() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(institution: "Broker", type: .investment, nickname: "Broker")
        context.insert(account)

        #expect(await PortfolioPriceRefresher.refresh(account: account, context: context) == .empty)

        let outcome = await PortfolioPriceRefresher.refresh(account: account, context: context) { _ in
            Issue.record("No fetch should happen without active positions")
            return [:]
        }

        #expect(outcome == .empty)
    }

    @Test("Requested portfolio tickers refresh into Net Worth")
    func requestedPortfolioTickersRefreshIntoNetWorth() async throws {
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
            includeInNetWorth: true,
            context: context
        )
        let requested = [
            ("VOO", "VOO", Decimal(10)),
            ("IBM", "IBM", Decimal(20)),
            ("FMTY14", "FMTY14", Decimal(30)),
            ("AMX B", "AMXB", Decimal(40)),
            ("CEMEX CPO", "CEMEXCPO", Decimal(50)),
            ("GFNORTE O", "GFNORTEO", Decimal(60)),
        ]

        #expect(PortfolioService.canAddPositions(account: account, context: context))
        for (input, _, _) in requested {
            try PortfolioService.addPosition(
                account: account,
                emisoraSerie: input,
                name: nil,
                shares: 1,
                averageCost: 1,
                context: context
            )
        }

        let outcome = await PortfolioPriceRefresher.refresh(account: account, context: context) { tickers in
            #expect(Set(tickers) == Set(requested.map { $0.1 }))
            return Dictionary(uniqueKeysWithValues: requested.map {
                ($0.1, DataBursatilClient.PriceSnapshot(price: $0.2, timestamp: nil))
            })
        }

        #expect(outcome == .priced)
        let expectedTotal = requested.reduce(Decimal(0)) { $0 + $1.2 }
        let viewModel = DashboardViewModel()
        viewModel.configure(context: context)
        guard case .consolidated(let snapshot) = viewModel.snapshot else {
            Issue.record("Expected consolidated snapshot")
            return
        }
        #expect(snapshot.netWorth == expectedTotal)
        #expect(snapshot.accountSummaries.first { $0.id == account.id }?.latestBalance == expectedTotal)
    }
}
