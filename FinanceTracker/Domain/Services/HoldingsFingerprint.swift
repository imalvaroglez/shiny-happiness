import Foundation
import CryptoKit

/// Locale-independent SHA-256 of a portfolio's active holdings.
/// Input is normalized so the fingerprint is stable regardless of locale/format.
enum HoldingsFingerprint {
    /// `holdings`: (ticker, shares, averageCost). Only `shares > 0` rows count.
    static func of(_ holdings: [(ticker: String, shares: Decimal, cost: Decimal)]) -> String {
        let rows = holdings
            .filter { $0.shares > 0 }
            .map { (ticker: $0.ticker.uppercased().trimmingCharacters(in: .whitespaces),
                    shares: $0.shares,
                    cost: $0.cost) }
            .sorted { lhs, rhs in
                if lhs.ticker != rhs.ticker { return lhs.ticker < rhs.ticker }
                return false
            }
        // ponytail: unit delimiter \u{1F} can't appear in a ticker or stringValue.
        let delimiter = "\u{1F}"
        let payload = rows.map { row in
            // NSDecimalNumber.stringValue is locale-independent (no grouping separators).
            let s = NSDecimalNumber(decimal: row.shares).stringValue
            let c = NSDecimalNumber(decimal: row.cost).stringValue
            return "\(row.ticker)\(delimiter)\(s)\(delimiter)\(c)"
        }.joined(separator: delimiter)
        return SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
