import Foundation
import Testing
@testable import FinanceTracker

@Suite("Portfolio Dashboard Copy")
struct PortfolioDashboardCopyTests {
    @Test("Refresh outcomes map to actionable user messages")
    func refreshOutcomeMessages() {
        #expect(PortfolioDashboardCopy.refreshMessage(for: .priced) == nil)
        #expect(PortfolioDashboardCopy.refreshMessage(for: .partial(missing: ["GFNORTEO"])) == "Some positions could not be priced: GFNORTEO. No portfolio valuation was saved.")
        #expect(PortfolioDashboardCopy.refreshMessage(for: .empty) == "No active positions to price.")
        #expect(PortfolioDashboardCopy.refreshMessage(for: .notAuthenticated) == "Add your DataBursatil token in Settings before refreshing prices.")
        #expect(PortfolioDashboardCopy.refreshMessage(for: .failed) == "Could not refresh prices from DataBursatil.")
    }

    @Test("Portfolio mode hides manual account actions and warns on stale holdings")
    func portfolioModeAndWarningState() {
        let stale = PortfolioViewData(
            inPortfolioMode: true,
            valuationAmount: 1_000,
            valuationDate: Date(timeIntervalSince1970: 1),
            sourceIsPortfolioValuation: true,
            holdingsFingerprintMatches: false,
            totalInvested: 800,
            totalGrowthPercent: nil,
            isPartialOrStale: false,
            rows: []
        )
        let empty = PortfolioViewData(
            inPortfolioMode: false,
            valuationAmount: nil,
            valuationDate: nil,
            sourceIsPortfolioValuation: false,
            holdingsFingerprintMatches: false,
            totalInvested: 0,
            totalGrowthPercent: nil,
            isPartialOrStale: false,
            rows: []
        )

        #expect(PortfolioDashboardCopy.hidesManualActions(portfolio: stale))
        #expect(!PortfolioDashboardCopy.hidesManualActions(portfolio: empty))
        #expect(!PortfolioDashboardCopy.hidesManualActions(portfolio: nil))
        #expect(PortfolioDashboardCopy.showsHoldingsWarning(portfolio: stale))
        #expect(!PortfolioDashboardCopy.showsHoldingsWarning(portfolio: empty))
    }
}
