import Testing
import Foundation
@testable import FinanceTracker

/// Pure-logic tests for the raw clipboard amount formatter. No @MainActor,
/// no ModelContainer — `Decimal.plainMoneyString` is a value-type extension.
@Suite("Plain Money String")
struct PlainMoneyStringTests {

    @Test("Positive balance renders with dot decimal, two places")
    func positiveBalance() {
        #expect(Decimal(string: "172382.42")!.plainMoneyString == "172382.42")
        #expect(Decimal(string: "631196.16")!.plainMoneyString == "631196.16")
    }

    @Test("Negative balance preserves sign")
    func negativeBalance() {
        #expect(Decimal(string: "-533.72")!.plainMoneyString == "-533.72")
    }

    @Test("Zero renders with two decimal places")
    func zeroBalance() {
        #expect(Decimal(0).plainMoneyString == "0.00")
    }

    @Test("Whole amounts gain two decimal places")
    func wholeAmount() {
        #expect(Decimal(string: "1500")!.plainMoneyString == "1500.00")
    }

    @Test("Plain string has no currency symbol or grouping separators")
    func noSymbolOrGrouping() {
        let rendered = Decimal(string: "1234567.89")!.plainMoneyString
        #expect(!rendered.contains("$"))
        #expect(!rendered.contains(","))
        #expect(!rendered.contains(" "))
        #expect(!rendered.contains("MXN") && !rendered.contains("USD"))
        #expect(rendered == "1234567.89")
    }

    @Test("Plain string uses a dot decimal separator")
    func dotDecimalSeparator() {
        // en_US_POSIX guarantees a dot regardless of the user's locale.
        let rendered = Decimal(string: "42.5")!.plainMoneyString
        #expect(rendered.contains("."))
        #expect(!rendered.contains(","))
        #expect(rendered == "42.50")
    }
}
