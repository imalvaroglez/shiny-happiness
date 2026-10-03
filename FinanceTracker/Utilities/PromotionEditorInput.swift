import Foundation

enum PromotionEditorInput {
    enum InputError: LocalizedError {
        case invalidTarget, invertedWindow
        var errorDescription: String? {
            switch self {
            case .invalidTarget: "La meta debe ser un número mayor que cero (por ejemplo, 100,000.00)."
            case .invertedWindow: "El fin de la ventana no puede ser anterior al inicio."
            }
        }
    }

    static func editableTarget(_ amount: Decimal?) -> String {
        amount.map { NSDecimalNumber(decimal: $0).stringValue } ?? ""
    }

    static func target(from text: String) throws -> Decimal? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let pattern = #"^(?:[0-9]+|[0-9]{1,3}(?:,[0-9]{3})+)(?:\.[0-9]{1,2})?$"#
        guard text.range(of: pattern, options: .regularExpression) != nil,
              let amount = Decimal(string: text.replacingOccurrences(of: ",", with: ""),
                                   locale: Locale(identifier: "en_US_POSIX")), amount > 0 else {
            throw InputError.invalidTarget
        }
        return amount
    }

    static func validateWindow(start: Date?, end: Date?, calendar: Calendar = .current) throws {
        if let start, let end, calendar.startOfDay(for: end) < calendar.startOfDay(for: start) {
            throw InputError.invertedWindow
        }
    }
}
