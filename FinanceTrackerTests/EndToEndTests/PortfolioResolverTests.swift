import Testing
import Foundation
import SwiftData
@testable import FinanceTracker

@Suite("Portfolio Resolver")
@MainActor
struct PortfolioResolverTests {
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(schema: AppSchema.schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: AppSchema.schema, configurations: [config])
    }

    private func date(_ year: Int = 2026, _ month: Int = 6, _ day: Int = 1, hour: Int = 12) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.timeZone = TimeZone(identifier: "America/Mexico_City")
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    @Test("Portfolio valuation anchor is authoritative")
    func authoritativeNoRollForward() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(institution: "Broker", type: .investment, nickname: "Broker")
        let valuationDate = date(hour: 9)
        let asOf = date(hour: 12)
        context.insert(account)
        context.insert(AccountBalanceSnapshot(account: account, date: valuationDate, amount: 12_000, kind: .portfolioValuation))
        context.insert(Transaction(account: account, postedAt: asOf, amount: 500, descriptionRaw: "deposit"))
        try context.save()

        let resolution = AccountBalanceResolver.resolution(account: account, asOf: asOf, context: context)
        #expect(resolution.amount == 12_000)
    }

    @Test("Portfolio valuation provenance is exposed")
    func provenancePortfolio() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(institution: "Broker", type: .investment, nickname: "Broker")
        let snapshot = AccountBalanceSnapshot(
            account: account,
            date: date(),
            amount: 1_000,
            kind: .portfolioValuation,
            note: "Portfolio valuation |fp=abc"
        )
        context.insert(account)
        context.insert(snapshot)
        try context.save()

        let resolution = AccountBalanceResolver.resolution(account: account, asOf: date(), context: context)
        #expect(resolution.sourceSnapshotID == snapshot.id)
        #expect(resolution.sourceSnapshotKind == .portfolioValuation)
        #expect(resolution.sourceSnapshotNote == "Portfolio valuation |fp=abc")
    }

    @Test("Newer statement wins over older portfolio valuation")
    func provenanceNotPortfolioWhenStatementLatest() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(institution: "Broker", type: .investment, nickname: "Broker")
        context.insert(account)
        context.insert(AccountBalanceSnapshot(account: account, date: date(hour: 9), amount: 1_000, kind: .portfolioValuation))
        context.insert(Statement(
            account: account,
            periodStart: date(hour: 10),
            periodEnd: date(hour: 12),
            sourceFileHash: "h",
            closingBalance: 800
        ))
        try context.save()

        let resolution = AccountBalanceResolver.resolution(account: account, asOf: date(hour: 12), context: context)
        #expect(resolution.amount == 800)
        #expect(resolution.sourceSnapshotKind != .portfolioValuation)
    }
}
