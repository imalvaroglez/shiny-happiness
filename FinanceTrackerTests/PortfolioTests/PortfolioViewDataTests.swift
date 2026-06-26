import Testing
import Foundation
@testable import FinanceTracker

@Suite("Portfolio View Data")
struct PortfolioViewDataTests {
    @Test("Position row value and growth are derived from latest cached price")
    func positionRowValueAndGrowth() throws {
        let row = PortfolioViewData.PositionRow(
            id: UUID(),
            ticker: "FEMSAUBD",
            name: nil,
            shares: 10,
            averageCost: 100,
            lastPrice: 125,
            lastPriceAt: Date(timeIntervalSince1970: 1)
        )

        #expect(row.value == 1_250)
        let growth = try #require(row.growthPercent)
        #expect(abs(growth - 25) < 0.001)
    }

    @Test("Growth is unavailable without a usable price or cost basis")
    func growthUnavailableWithoutPriceOrCost() {
        let id = UUID()
        let noPrice = PortfolioViewData.PositionRow(
            id: id,
            ticker: "FEMSAUBD",
            name: nil,
            shares: 10,
            averageCost: 100,
            lastPrice: nil,
            lastPriceAt: nil
        )
        let zeroCost = PortfolioViewData.PositionRow(
            id: id,
            ticker: "FEMSAUBD",
            name: nil,
            shares: 10,
            averageCost: 0,
            lastPrice: 125,
            lastPriceAt: nil
        )

        #expect(noPrice.value == nil)
        #expect(noPrice.growthPercent == nil)
        #expect(zeroCost.growthPercent == nil)
    }
}
