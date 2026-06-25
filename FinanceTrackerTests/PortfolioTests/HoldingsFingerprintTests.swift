import Testing
import Foundation
@testable import FinanceTracker

@Suite("Holdings Fingerprint")
struct HoldingsFingerprintTests {
    /// Plain value tuples used as input so the test doesn't need SwiftData.
    private struct Holding { let ticker: String; let shares: Decimal; let cost: Decimal }

    private func fp(_ holdings: [Holding]) -> String {
        HoldingsFingerprint.of(holdings.map { ($0.ticker, $0.shares, $0.cost) })
    }

    @Test("Order-independent")
    func orderIndependent() {
        let a = fp([Holding(ticker: "bimboa", shares: 10, cost: 50),
                    Holding(ticker: "FEMSAUBD", shares: 5, cost: 100)])
        let b = fp([Holding(ticker: "FEMSAUBD", shares: 5, cost: 100),
                    Holding(ticker: "bimboa", shares: 10, cost: 50)])
        #expect(a == b)
    }

    @Test("Ticker normalization (uppercase/trim)")
    func tickerNormalized() {
        let a = fp([Holding(ticker: " femsaubd ", shares: 5, cost: 100)])
        let b = fp([Holding(ticker: "FEMSAUBD", shares: 5, cost: 100)])
        #expect(a == b)
    }

    @Test("Different holdings differ")
    func differs() {
        let a = fp([Holding(ticker: "FEMSAUBD", shares: 5, cost: 100)])
        let b = fp([Holding(ticker: "FEMSAUBD", shares: 6, cost: 100)])
        #expect(a != b)
    }

    @Test("Zero-share positions excluded")
    func excludesZeroShares() {
        let withZero = fp([Holding(ticker: "FEMSAUBD", shares: 5, cost: 100),
                           Holding(ticker: "BIMBOA", shares: 0, cost: 40)])
        let withoutZero = fp([Holding(ticker: "FEMSAUBD", shares: 5, cost: 100)])
        #expect(withZero == withoutZero)
    }

    @Test("Empty holdings are stable")
    func emptyStable() {
        #expect(fp([]) == fp([]))
        #expect(!fp([]).isEmpty)
    }
}
