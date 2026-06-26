import Foundation

struct PortfolioViewData: Equatable {
    struct PositionRow: Equatable, Identifiable {
        let id: UUID
        let ticker: String
        let name: String?
        let shares: Decimal
        let averageCost: Decimal
        let lastPrice: Decimal?
        let lastPriceAt: Date?

        var value: Decimal? {
            lastPrice.map { shares * $0 }
        }

        var growthPercent: Double? {
            guard let value, averageCost > 0 else { return nil }
            let cost = shares * averageCost
            guard cost != 0 else { return nil }
            return (((value - cost) / cost) as NSDecimalNumber).doubleValue * 100
        }
    }

    let inPortfolioMode: Bool
    let valuationAmount: Decimal?
    let valuationDate: Date?
    let sourceIsPortfolioValuation: Bool
    let holdingsFingerprintMatches: Bool
    let totalInvested: Decimal
    let totalGrowthPercent: Double?
    let isPartialOrStale: Bool
    let rows: [PositionRow]
}
