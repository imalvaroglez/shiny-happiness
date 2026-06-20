import Foundation
import PDFKit

struct OpenbankMexicoParser: StatementParser, Sendable {
    private let dateFormatter: DateFormatter

    init() {
        let df = DateFormatter()
        df.dateFormat = "dd/MM/yy"
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "America/Mexico_City")
        self.dateFormatter = df
    }

    func parse(data: Data) async throws -> [RawTransaction] {
        guard let document = PDFDocument(data: data) else {
            throw ParserError.invalidData("Cannot open PDF document")
        }

        if document.isLocked {
            throw ParserError.encrypted("Document is password-protected")
        }

        var allTransactions: [RawTransaction] = []

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            guard let pageText = page.string else { continue }

            let pageTransactions = parsePage(pageText)
            allTransactions.append(contentsOf: pageTransactions)
        }

        return allTransactions
    }

    private func parsePage(_ pageText: String) -> [RawTransaction] {
        var transactions: [RawTransaction] = []

        let lines = pageText.components(separatedBy: "\n")
        var currentDescription: [String] = []
        var currentDate: Date?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            if isHeaderOrFooter(trimmed) { continue }

            if let date = tryParseDate(trimmed) {
                if let prevDate = currentDate, !currentDescription.isEmpty {
                    if let tx = buildTransaction(date: prevDate, textLines: currentDescription) {
                        transactions.append(tx)
                    }
                }
                currentDate = date
                currentDescription = []
                let remainder = extractDescriptionFromSameLine(trimmed)
                if !remainder.isEmpty {
                    currentDescription.append(remainder)
                }
                continue
            }

            if currentDate != nil {
                currentDescription.append(trimmed)
            }
        }

        if let date = currentDate, !currentDescription.isEmpty {
            if let tx = buildTransaction(date: date, textLines: currentDescription) {
                transactions.append(tx)
            }
        }

        return transactions
    }

    private func buildTransaction(date: Date, textLines: [String]) -> RawTransaction? {
        let fullText = textLines.joined(separator: " ")

        let amounts = extractAmounts(from: fullText)
        guard let primaryAmount = amounts.first else { return nil }

        let description = cleanDescription(fullText)

        return RawTransaction(
            postedAt: date,
            amount: primaryAmount,
            currency: "MXN",
            descriptionRaw: description,
            merchantNormalized: extractMerchant(from: description),
            isTransfer: isTransferDescription(description)
        )
    }

    private func extractAmounts(from text: String) -> [Decimal] {
        let pattern = #"\$\s*([\d,]+\.?\d*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)

        var amounts: [Decimal] = []
        for match in matches {
            guard let amountRange = Range(match.range(at: 1), in: text) else { continue }
            let amountStr = String(text[amountRange]).replacingOccurrences(of: ",", with: "")
            if let value = Decimal(string: amountStr), value > 0 {
                amounts.append(value)
            }
        }

        if amounts.count >= 3 {
            let depositIdx = 0
            let withdrawalIdx = 1
            if amounts[depositIdx] > 0 && amounts[withdrawalIdx] > 0 {
                return [amounts[depositIdx], -amounts[withdrawalIdx]]
            }
            return [amounts[0]]
        }

        if amounts.count == 2 {
            let fullText = text.lowercased()
            if fullText.contains("retiro") || fullText.contains("enviada") || fullText.contains("cargo") {
                return [-amounts[0]]
            }
            return [amounts[0]]
        }

        if amounts.count == 1 {
            let fullText = text.lowercased()
            if fullText.contains("retiro") || fullText.contains("enviada") || fullText.contains("cargo") {
                return [-amounts[0]]
            }
            return [amounts[0]]
        }

        return amounts
    }

    private func tryParseDate(_ line: String) -> Date? {
        let pattern = #"^(\d{2}/\d{2}/\d{2})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              let dateRange = Range(match.range(at: 1), in: line) else { return nil }
        return dateFormatter.date(from: String(line[dateRange]))
    }

    private func extractDescriptionFromSameLine(_ line: String) -> String {
        let pattern = #"^\d{2}/\d{2}/\d{2}\s*(.+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return line }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              let descRange = Range(match.range(at: 1), in: line) else { return "" }
        return String(line[descRange]).trimmingCharacters(in: .whitespaces)
    }

    private func cleanDescription(_ text: String) -> String {
        var cleaned = text
            .replacingOccurrences(of: #"\$\s*[\d,]+\.?\d*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "MXN", with: "")
            .replacingOccurrences(of: "Transferencia SPEI enviada a", with: "")
            .replacingOccurrences(of: "Transferencia SPEI recibida de la cuenta", with: "")
            .replacingOccurrences(of: "Traspaso a tu cuenta de ahorro;", with: "Traspaso ahorro")
            .replacingOccurrences(of: "Transferencia recibida de la cuenta", with: "")
            .replacingOccurrences(of: "Transferencia enviada a", with: "")
            .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        if cleaned.isEmpty {
            cleaned = text.trimmingCharacters(in: .whitespaces)
        }

        return cleaned
    }

    private func extractMerchant(from description: String) -> String {
        let prefixes = ["DiDi", "Uber", "OXXO", "Amazon", "Mercado Pago", "Starbucks",
                        "BBVA", "NU MEXICO", "Banorte", "Openbank", "Moneypool",
                        "Fantasy", "Tdc explora", "Efectivo para"]
        for prefix in prefixes {
            if description.localizedCaseInsensitiveContains(prefix) {
                return prefix
            }
        }

        let words = description.components(separatedBy: CharacterSet(charactersIn: " ,;:"))
            .filter { !$0.isEmpty && $0.count > 2 }
        return words.first ?? description
    }

    private func isTransferDescription(_ description: String) -> Bool {
        let keywords = ["Transferencia SPEI", "Traspaso", "Transferencia recibida", "Transferencia enviada"]
        return keywords.contains { description.contains($0) }
    }

    private func isHeaderOrFooter(_ line: String) -> Bool {
        let skipPatterns = [
            "Detalle de tus transacciones",
            "Fecha Concepto Depósito Retiro Saldo",
            "Emitido por Openbank",
            "Página",
            "Cuenta Débito",
            "Resumen del periodo",
            "Saldo inicial",
            "Saldo final",
            "Depósitos",
            "Retiro en efectivo",
            "Otros cargos",
            "Comisiones",
            "Días del periodo",
        ]
        return skipPatterns.contains { line.contains($0) }
    }
}

enum ParserError: Error, LocalizedError, Sendable {
    case invalidData(String)
    case encrypted(String)
    case unsupportedFormat(String)
    case parseFailure(String)

    var errorDescription: String? {
        switch self {
        case .invalidData(let msg): "Invalid data: \(msg)"
        case .encrypted(let msg): "Encrypted: \(msg)"
        case .unsupportedFormat(let msg): "Unsupported format: \(msg)"
        case .parseFailure(let msg): "Parse failure: \(msg)"
        }
    }
}
