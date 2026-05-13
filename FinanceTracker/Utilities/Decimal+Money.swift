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

    private static let _mxnFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "MXN"
        f.locale = Locale(identifier: "es_MX")
        return f
    }()

    var moneyDisplay: String {
        Self._mxnFormatter.string(from: self as NSDecimalNumber) ?? "\(self)"
    }
}
