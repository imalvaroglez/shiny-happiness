import Foundation
import SwiftData

@MainActor
enum PortfolioPriceRefresher {
    enum Outcome: Equatable {
        case priced
        case partial
        case empty
        case notAuthenticated
        case failed
    }

    typealias QuoteFetcher = @Sendable ([String]) async throws -> [String: DataBursatilClient.PriceSnapshot]

    @discardableResult
    static func refresh(account: Account, context: ModelContext) async -> Outcome {
        guard !PortfolioService.activePositions(accountID: account.id, context: context).isEmpty else { return .empty }
        guard let token = KeychainTokenStore.token(), !token.isEmpty else { return .notAuthenticated }
        let client = DataBursatilClient(token: token)
        return await refresh(account: account, context: context) { tickers in
            try await client.quotes(for: tickers)
        }
    }

    @discardableResult
    static func refresh(account: Account, context: ModelContext, fetchQuotes: QuoteFetcher) async -> Outcome {
        let positions = PortfolioService.activePositions(accountID: account.id, context: context)
        guard !positions.isEmpty else { return .empty }

        let quotes: [String: DataBursatilClient.PriceSnapshot]
        do {
            quotes = try await fetchQuotes(positions.map(\.emisoraSerie))
        } catch {
            return .failed
        }

        var quotesByTicker: [String: DataBursatilClient.PriceSnapshot] = [:]
        for (ticker, quote) in quotes {
            quotesByTicker[PortfolioTicker.normalize(ticker)] = quote
        }
        var allPriced = true
        for position in positions {
            guard let quote = quotesByTicker[PortfolioTicker.normalize(position.emisoraSerie)] else {
                allPriced = false
                continue
            }
            position.lastPrice = quote.price
            position.lastPriceAt = quote.timestamp ?? .now
        }

        guard allPriced else {
            try? context.save()
            return .partial
        }

        let totalValue = positions.reduce(Decimal(0)) { $0 + ($1.shares * ($1.lastPrice ?? 0)) }
        let holdings = positions.map { ($0.emisoraSerie, $0.shares, $0.averageCost) }
        let fingerprint = HoldingsFingerprint.of(holdings)
        context.insert(AccountBalanceSnapshot(
            account: account,
            date: .now,
            amount: totalValue,
            kind: .portfolioValuation,
            note: "Portfolio valuation |fp=\(fingerprint)"
        ))
        try? context.save()
        return .priced
    }

}
