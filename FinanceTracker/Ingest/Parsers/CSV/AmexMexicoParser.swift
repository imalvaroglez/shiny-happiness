import Foundation
import PDFKit

struct AmexMexicoParser: StatementParser, Sendable {
    private let spanishDateFormatter: DateFormatter
    private let slashDateFormatter: DateFormatter

    init() {
        let df = DateFormatter()
        df.dateFormat = "dd-MMM-yyyy"
        df.locale = Locale(identifier: "es_MX")
        df.timeZone = TimeZone(identifier: "America/Mexico_City")
        self.spanishDateFormatter = df

        let df2 = DateFormatter()
        df2.dateFormat = "dd/MMM/yyyy"
        df2.locale = Locale(identifier: "es_MX")
        df2.timeZone = TimeZone(identifier: "America/Mexico_City")
        self.slashDateFormatter = df2
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
        var inDetailSection = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            if isDetailSectionHeader(trimmed) {
                inDetailSection = true
                continue
            }

            if isSectionEnd(trimmed) {
                inDetailSection = false
                continue
            }

            if !inDetailSection { continue }

            if let tx = parseTransactionLine(trimmed) {
                transactions.append(tx)
            }
        }

        return transactions
    }

    private func parseTransactionLine(_ line: String) -> RawTransaction? {
        let datePatterns = [
            #"(\d{2}-\w{3}-\d{4})"#,
            #"(\d{2}/\w{3}/\d{4})"#,
            #"(\d{2}\s+de\s+\w+\s+de\s+\d{4})"#,
        ]

        for pattern in datePatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  let dateRange = Range(match.range(at: 1), in: line) else { continue }

            let dateString = String(line[dateRange])
            guard let date = parseDate(dateString) else { continue }

            let amount = extractAmount(from: line)
            let description = extractDescription(from: line, dateMatch: match)

            return RawTransaction(
                postedAt: date,
                amount: amount,
                currency: "MXN",
                descriptionRaw: description,
                merchantNormalized: extractMerchant(from: description)
            )
        }

        return nil
    }

    private func parseDate(_ dateString: String) -> Date? {
        let normalized = dateString
            .replacingOccurrences(of: "Ene", with: "Jan")
            .replacingOccurrences(of: "Feb", with: "Feb")
            .replacingOccurrences(of: "Mar", with: "Mar")
            .replacingOccurrences(of: "Abr", with: "Apr")
            .replacingOccurrences(of: "May", with: "May")
            .replacingOccurrences(of: "Jun", with: "Jun")
            .replacingOccurrences(of: "Jul", with: "Jul")
            .replacingOccurrences(of: "Ago", with: "Aug")
            .replacingOccurrences(of: "Sep", with: "Sep")
            .replacingOccurrences(of: "Oct", with: "Oct")
            .replacingOccurrences(of: "Nov", with: "Nov")
            .replacingOccurrences(of: "Dic", with: "Dec")

        if let date = spanishDateFormatter.date(from: dateString) { return date }
        if let date = slashDateFormatter.date(from: dateString) { return date }

        let isoFormatter = DateFormatter()
        isoFormatter.dateFormat = "dd-MMM-yyyy"
        isoFormatter.locale = Locale(identifier: "en_US_POSIX")
        return isoFormatter.date(from: normalized)
    }

    private func extractAmount(from line: String) -> Decimal {
        let pattern = #"(-?\d{1,3}(?:,\d{3})*(?:\.\d{2}))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        let range = NSRange(line.startIndex..., in: line)
        let matches = regex.matches(in: line, range: range)

        guard let lastMatch = matches.last,
              let amountRange = Range(lastMatch.range(at: 1), in: line) else { return 0 }

        let amountStr = String(line[amountRange]).replacingOccurrences(of: ",", with: "")
        return Decimal(string: amountStr) ?? 0
    }

    private func extractDescription(from line: String, dateMatch: NSTextCheckingResult) -> String {
        let fullRange = NSRange(line.startIndex..., in: line)
        let afterDate = NSRange(location: dateMatch.range.upperBound, length: fullRange.upperBound - dateMatch.range.upperBound)
        guard let descRange = Range(afterDate, in: line) else { return line }

        var desc = String(line[descRange])
            .replacingOccurrences(of: #"-?\d{1,3}(?:,\d{3})*(?:\.\d{2})"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"MXN"#, with: "")
            .replacingOccurrences(of: #"USD"#, with: "")
            .trimmingCharacters(in: .whitespaces)

        if desc.isEmpty {
            desc = line.trimmingCharacters(in: .whitespaces)
        }

        return desc
    }

    private func extractMerchant(from description: String) -> String {
        let prefixes = ["Uber", "DiDi", "OXXO", "Amazon", "Mercado Pago", "Starbucks",
                        "Netflix", "Spotify", "Apple", "Google", "Walmart", "SANBORNS",
                        "GAP", "ZARA", "HEB", "VIPS", "TOKS"]
        for prefix in prefixes {
            if description.localizedCaseInsensitiveContains(prefix) {
                return prefix
            }
        }

        let words = description.components(separatedBy: CharacterSet(charactersIn: " ,;:."))
            .filter { !$0.isEmpty && $0.count > 2 }
        return words.first ?? description
    }

    private func isDetailSectionHeader(_ line: String) -> Bool {
        let headers = [
            "Detalle de Transacciones",
            "Detalle de Cargo",
            "DETALLE DE TRANSACCIONES",
            "TARJETA TITULAR",
            "TARJETA ADICIONAL",
        ]
        return headers.contains { line.contains($0) }
    }

    private func isSectionEnd(_ line: String) -> Bool {
        let ends = [
            "Número de Cuenta",
            "Pago Mínimo",
            "Fecha límite",
            "Pago para no generar",
            "Resumen de Crédito",
            "Llamamos",
            "CAT ",
            "Tasa de Interés",
        ]
        return ends.contains { line.contains($0) }
    }
}
