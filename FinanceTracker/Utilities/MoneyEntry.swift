import Foundation

/// Plain-text money entry format: parse and render amounts exactly as the
/// user types them — no currency symbol, no grouping separator, at most two
/// decimal places. Lives in Utilities so shared UI (e.g. `EditableMoneyField`)
/// can use it without depending on the Properties feature.
enum MoneyEntry {
    static func parseEntryAmount(_ text: String) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = "^(?:[0-9]+|[1-9][0-9]{0,2}(?:,[0-9]{3})+)(?:\\.[0-9]{1,2})?$"
        guard trimmed.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return Decimal(string: trimmed.replacingOccurrences(of: ",", with: ""),
                       locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Capture uses cents; the report retains its original Decimal obligation.
    static func suggestedEntryText(_ amount: Decimal) -> String {
        var value = amount
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 2, .plain)
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: rounded as NSDecimalNumber) ?? rounded.description
    }
}
