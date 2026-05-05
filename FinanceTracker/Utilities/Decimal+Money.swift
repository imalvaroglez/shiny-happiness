import Foundation

extension Decimal {
    init(moneyString: String, locale: Locale = .current) {
        let cleaned = moneyString
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: "MXN", with: "")
            .replacingOccurrences(of: "USD", with: "")
            .trimmingCharacters(in: .whitespaces)
        if let d = Decimal(string: cleaned, locale: locale) {
            self = d
        } else {
            let fallback = cleaned.replacingOccurrences(of: ",", with: "")
            self = Decimal(string: fallback) ?? 0
        }
    }

    var moneyDisplay: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "MXN"
        formatter.locale = Locale(identifier: "es_MX")
        return formatter.string(from: self as NSDecimalNumber) ?? "\(self)"
    }
}
