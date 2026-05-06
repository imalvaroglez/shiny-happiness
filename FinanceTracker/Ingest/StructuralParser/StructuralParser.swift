import Foundation
import PDFKit
import os

struct StructuralParser: StatementParser {
    static var supportedIssuers: [String] { [] }
    static var supportedFormats: [FileFormat] { [.pdf] }

    private let vocabulary: HeaderVocabulary
    private let normalizer: SemanticNormalizer
    private let columnDetector: ColumnDetector

    init?() {
        guard let patterns = DatePatterns.load(),
              let conventions = AmountConventions.load(),
              let vocab = HeaderVocabulary.load() else {
            return nil
        }
        self.vocabulary = vocab
        self.normalizer = SemanticNormalizer(datePatterns: patterns, amountConventions: conventions)
        self.columnDetector = ColumnDetector(vocabulary: vocab)
    }

    internal init(vocabulary: HeaderVocabulary, normalizer: SemanticNormalizer, columnDetector: ColumnDetector) {
        self.vocabulary = vocabulary
        self.normalizer = normalizer
        self.columnDetector = columnDetector
    }

    func parse(data: Data) async throws -> [RawTransaction] {
        guard let document = PDFDocument(data: data) else {
            throw ParserError.invalidData("Could not create PDF document from data")
        }

        let log = Logger.parser
        log.info("StructuralParser: processing \(document.pageCount) pages")

        var statementContext: StatementContext?

        var allTransactions: [RawTransaction] = []

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }

            if statementContext == nil {
                let fullText = page.string ?? ""
                statementContext = normalizer.extractStatementContext(fullText)
            }

            let rows = PDFTextExtractor.extractRows(from: page)
            log.debug("Page \(pageIndex): \(rows.count) rows extracted")
            guard !rows.isEmpty else { continue }

            let pageTransactions = parseRows(rows, context: statementContext)
            log.debug("Page \(pageIndex): \(pageTransactions.count) transactions extracted (line-based or structural)")
            allTransactions.append(contentsOf: pageTransactions)
        }

        log.info("StructuralParser: total \(allTransactions.count) transactions from \(document.pageCount) pages")
        return allTransactions
    }

    private func parseRows(_ rows: [TableRow], context: StatementContext?) -> [RawTransaction] {
        if let table = columnDetector.detectTable(in: rows) {
            Logger.parser.debug("Detected table: layout=\(String(describing: table.layout)), columns=\(table.columns.count), convention=\(table.amountConvention ?? "none"), dataRows=\(table.dataRowRange.count)")

            let result: [RawTransaction]
            if table.columns.count >= 2, table.columns.allSatisfy({ abs($0.xCenter - table.columns[0].xCenter) < 50 }) {
                result = parseWideHeaderTable(rows: rows, table: table, context: context)
            } else {
                switch table.layout {
                case .flow:
                    result = parseFlowTable(rows: rows, table: table, context: context)
                case .grid:
                    result = parseGridTable(rows: rows, table: table, context: context)
                }
            }

            if result.isEmpty {
                return parseLineByLine(rows: rows, context: context)
            }
            return result
        }

        Logger.parser.debug("No table detected in \(rows.count) rows, trying line-based parsing")
        return parseLineByLine(rows: rows, context: context)
    }

    private func parseLineByLine(rows: [TableRow], context: StatementContext?) -> [RawTransaction] {
        var transactions: [RawTransaction] = []
        var inTransactionSection = false
        var currentConvention: String? = nil
        var pendingDateStr: String? = nil
        var pendingDescription: String? = nil

        for (rowIndex, row) in rows.enumerated() {
            let lineText = row.cells.map { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard !lineText.isEmpty else { continue }

            if columnDetector.vocabulary.isSectionStart(lineText) {
                Logger.parser.debug("Line parser: section start at row \(rowIndex): \(lineText.prefix(60))")
                inTransactionSection = true
                currentConvention = nil
                pendingDateStr = nil
                pendingDescription = nil
                continue
            }

            if columnDetector.vocabulary.isSectionEnd(lineText) {
                Logger.parser.debug("Line parser: section end at row \(rowIndex): \(lineText.prefix(60))")
                inTransactionSection = false
                pendingDateStr = nil
                pendingDescription = nil
                continue
            }

            guard inTransactionSection else { continue }

            if lineText.contains("Fecha") && (lineText.contains("Concepto") || lineText.contains("Importe") || lineText.contains("Monto") || lineText.contains("Descripción")) {
                currentConvention = detectConvention(from: lineText)
                Logger.parser.debug("Line parser: header row, convention=\(currentConvention ?? "nil"): \(lineText.prefix(80))")
                continue
            }

            if let pendingDate = pendingDateStr, let pendingDesc = pendingDescription {
                let amountOnlyPattern = #"^\$?\s*(-?)([\d,]+\.?\d*)\s*(-?)$"#
                if let regex = try? NSRegularExpression(pattern: amountOnlyPattern),
                   let match = regex.firstMatch(in: lineText, range: NSRange(lineText.startIndex..., in: lineText)),
                   let valueRange = Range(match.range(at: 2), in: lineText) {
                    let leadingMinus = match.range(at: 1).length > 0
                    let trailingMinus = match.range(at: 3).length > 0
                    let valueStr = String(lineText[valueRange]).replacingOccurrences(of: ",", with: "")
                    if let decimalValue = Decimal(string: valueStr) {
                        let isCredit = leadingMinus || trailingMinus
                        let amount: Decimal = isCredit ? abs(decimalValue) : -abs(decimalValue)

                        if let parsedDate = normalizer.parseDate(pendingDate, context: context),
                           parsedDate.confidence >= .low {
                            let tx = RawTransaction(
                                postedAt: parsedDate.fullDate ?? Date(),
                                amount: amount,
                                currency: "MXN",
                                descriptionRaw: normalizer.normalizeDescription(pendingDesc),
                                merchantNormalized: "",
                                fxRateToBase: 1,
                                isTransfer: false
                            )
                            transactions.append(tx)
                        }
                    }
                    pendingDateStr = nil
                    pendingDescription = nil
                    continue
                }
            }

            let parsed = parseSingleLine(lineText, context: context, convention: currentConvention)
            if !parsed.isEmpty {
                transactions.append(contentsOf: parsed)
                pendingDateStr = nil
                pendingDescription = nil
            } else if let (date, desc) = extractDateWithoutAmount(from: lineText, context: context) {
                pendingDateStr = date
                pendingDescription = desc
            }
        }

        Logger.parser.debug("Line parser: found \(transactions.count) transactions from \(rows.count) rows")
        return transactions
    }

    private func extractDateWithoutAmount(from line: String, context: StatementContext?) -> (String, String)? {
        let segments = splitByDates(line)
        guard let first = segments.first else { return nil }

        let datePattern = #"^(\d{1,2}/\d{1,2}(?:/\d{2,4})?)\s+(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: datePattern) else { return nil }
        let range = NSRange(first.startIndex..., in: first)
        guard let match = regex.firstMatch(in: first, range: range) else { return nil }

        guard let dateRange = Range(match.range(at: 1), in: first),
              let descRange = Range(match.range(at: 2), in: first) else { return nil }

        let dateStr = String(first[dateRange])
        let desc = String(first[descRange])

        guard normalizer.parseDate(dateStr, context: context) != nil else { return nil }
        guard !desc.isEmpty else { return nil }

        return (dateStr, desc)
    }

    private func detectConvention(from headerLine: String) -> String? {
        if headerLine.contains("Importe") && !headerLine.contains("Cargo") && !headerLine.contains("Abono") {
            return "trailing_minus"
        }
        return nil
    }

    private func parseSingleLine(_ line: String, context: StatementContext?, convention: String?) -> [RawTransaction] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return [] }

        let segments = splitByDates(trimmed)
        guard !segments.isEmpty else { return [] }

        var transactions: [RawTransaction] = []
        for segment in segments {
            if let tx = parseSingleTransactionSegment(segment, context: context, convention: convention) {
                transactions.append(tx)
            }
        }

        return transactions
    }

    private func splitByDates(_ line: String) -> [String] {
        let datePattern = #"\d{1,2}/\d{1,2}(?:/\d{2,4})?"#
        guard let regex = try? NSRegularExpression(pattern: datePattern) else { return [line] }
        let range = NSRange(line.startIndex..., in: line)
        let matches = regex.matches(in: line, range: range)

        guard !matches.isEmpty else { return [line] }

        var segments: [String] = []
        for (i, match) in matches.enumerated() {
            let start = Range(match.range, in: line)!.lowerBound
            let end: String.Index
            if i + 1 < matches.count {
                end = Range(matches[i + 1].range, in: line)!.lowerBound
            } else {
                end = line.endIndex
            }
            let segment = String(line[start..<end]).trimmingCharacters(in: .whitespaces)
            if !segment.isEmpty {
                segments.append(segment)
            }
        }

        return segments
    }

    private func parseSingleTransactionSegment(_ segment: String, context: StatementContext?, convention: String?) -> RawTransaction? {
        let trimmed = segment.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let dateAmountPattern = #"^(\d{1,2}/\d{1,2}(?:/\d{2,4})?)\s+(.+)\s+\$\s*(-?)([\d,]+\.?\d*)\s*(-?)$"#
        guard let regex = try? NSRegularExpression(pattern: dateAmountPattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, range: range) else { return nil }

        guard let dateRange = Range(match.range(at: 1), in: trimmed),
              let descRange = Range(match.range(at: 2), in: trimmed),
              let amountRange = Range(match.range(at: 4), in: trimmed) else { return nil }

        let dateStr = String(trimmed[dateRange])
        let descStr = String(trimmed[descRange])
        let amountStr = String(trimmed[amountRange])
        let leadingMinus = match.range(at: 3).length > 0
            ? (Range(match.range(at: 3), in: trimmed).map { String(trimmed[$0]) } ?? "") == "-"
            : false
        let trailingMinus = match.range(at: 5).length > 0
            ? (Range(match.range(at: 5), in: trimmed).map { String(trimmed[$0]) } ?? "") == "-"
            : false

        guard let parsedDate = normalizer.parseDate(dateStr, context: context),
              parsedDate.confidence >= .low else { return nil }

        let valueStr = amountStr.replacingOccurrences(of: ",", with: "")
        guard let decimalValue = Decimal(string: valueStr) else { return nil }

        let isCredit: Bool
        if let conv = convention, conv == "trailing_minus" {
            isCredit = trailingMinus
        } else {
            isCredit = trailingMinus || leadingMinus
        }

        let amount: Decimal
        if isCredit {
            amount = abs(decimalValue)
        } else {
            amount = decimalValue < 0 ? decimalValue : -abs(decimalValue)
        }

        let cleanedDesc = descStr.replacingOccurrences(
            of: #"\s+[A-Z]\s*[A-Z]?\s*$"#,
            with: "",
            options: .regularExpression
        )
        let description = normalizer.normalizeDescription(cleanedDesc)

        return RawTransaction(
            postedAt: parsedDate.fullDate ?? Date(),
            amount: amount,
            currency: "MXN",
            descriptionRaw: description,
            merchantNormalized: "",
            fxRateToBase: 1,
            isTransfer: false
        )
    }

    private func parseFlowTable(rows: [TableRow], table: DetectedTable, context: StatementContext?) -> [RawTransaction] {
        var transactions: [RawTransaction] = []
        let dataRows = Array(rows[table.dataRowRange])

        var pendingDay: Int?
        var pendingMonth: Int?
        var currentDescription: [String] = []
        var currentAmount: Decimal?
        var isCredit = false

        for row in dataRows {
            for cell in row.cells {
                let trimmed = cell.text.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }

                if normalizer.isCreditMarker(trimmed) {
                    isCredit = true
                    continue
                }

                if normalizer.looksLikeAmount(trimmed), pendingDay != nil {
                    if let parsed = normalizer.parseAmount(trimmed, conventionId: table.amountConvention) {
                        currentAmount = parsed.value
                        if parsed.isCredit { isCredit = true }
                    }
                    continue
                }

                if normalizer.isPartialDateStart(trimmed) {
                    if let day = normalizer.parsePartialDay(trimmed) {
                        if let pd = pendingDay, let pm = pendingMonth, let amt = currentAmount {
                            if let tx = buildRawTransaction(day: pd, month: pm, amount: amt, description: currentDescription, isCredit: isCredit, context: context) {
                                transactions.append(tx)
                            }
                        }
                        pendingDay = day
                        pendingMonth = nil
                        currentDescription = []
                        currentAmount = nil
                        isCredit = false
                    }
                    continue
                }

                if pendingDay != nil, pendingMonth == nil {
                    if let dateResult = normalizer.parseDateContinuation(trimmed, partialDay: pendingDay!, context: context) {
                        pendingMonth = dateResult.month
                        continue
                    }
                }

                if let inlineResult = normalizer.parseDate(trimmed, context: context), inlineResult.confidence >= .medium {
                    if let pd = pendingDay, let pm = pendingMonth, let amt = currentAmount {
                        if let tx = buildRawTransaction(day: pd, month: pm, amount: amt, description: currentDescription, isCredit: isCredit, context: context) {
                            transactions.append(tx)
                        }
                    }

                    pendingDay = inlineResult.day
                    pendingMonth = inlineResult.month
                    currentDescription = []
                    currentAmount = nil
                    isCredit = false

                    if let trailing = inlineResult.trailingDescription, !trailing.isEmpty {
                        currentDescription.append(trailing)
                    }
                    continue
                }

                if pendingDay != nil {
                    if let parsed = normalizer.parseAmount(trimmed, conventionId: table.amountConvention) {
                        currentAmount = parsed.value
                        if parsed.isCredit { isCredit = true }
                    } else {
                        currentDescription.append(normalizer.normalizeDescription(trimmed))
                    }
                }
            }
        }

        if let pd = pendingDay, let pm = pendingMonth, let amt = currentAmount {
            if let tx = buildRawTransaction(day: pd, month: pm, amount: amt, description: currentDescription, isCredit: isCredit, context: context) {
                transactions.append(tx)
            }
        }

        return transactions
    }

    private func parseGridTable(rows: [TableRow], table: DetectedTable, context: StatementContext?) -> [RawTransaction] {
        var transactions: [RawTransaction] = []
        let dataRows = Array(rows[table.dataRowRange])

        for row in dataRows {
            let assignments = columnDetector.assignCellRoles(in: row, columns: table.columns)

            var dateStr: String?
            var descriptionParts: [String] = []
            var amountStr: String?
            var debitStr: String?
            var creditStr: String?

            for assignment in assignments {
                switch assignment.role {
                case .date:
                    dateStr = assignment.text
                case .description:
                    descriptionParts.append(assignment.text)
                case .amount:
                    amountStr = assignment.text
                case .debit:
                    debitStr = assignment.text
                case .credit:
                    creditStr = assignment.text
                case .balance:
                    break
                case nil:
                    if dateStr == nil { dateStr = assignment.text }
                    else { descriptionParts.append(assignment.text) }
                }
            }

            guard let dateStr, let parsedDate = normalizer.parseDate(dateStr, context: context),
                  parsedDate.confidence >= .low else { continue }

            let desc = descriptionParts.joined(separator: " ")

            var amount: Decimal = 0
            if let debitStr, let parsed = normalizer.parseAmount(debitStr) {
                amount = parsed.value < 0 ? parsed.value : -parsed.value
            }
            if let creditStr, let parsed = normalizer.parseAmount(creditStr) {
                amount = parsed.value > 0 ? parsed.value : abs(parsed.value)
            }
            if amount == 0, let amountStr, let parsed = normalizer.parseAmount(amountStr, conventionId: table.amountConvention) {
                amount = parsed.value
            }

            guard amount != 0 else { continue }

            let tx = RawTransaction(
                postedAt: parsedDate.fullDate ?? Date(),
                amount: amount,
                currency: "MXN",
                descriptionRaw: normalizer.normalizeDescription(desc),
                merchantNormalized: "",
                fxRateToBase: 1,
                isTransfer: false
            )
            transactions.append(tx)
        }

        return transactions
    }

    private func buildRawTransaction(
        day: Int,
        month: Int,
        amount: Decimal,
        description: [String],
        isCredit: Bool,
        context: StatementContext?
    ) -> RawTransaction? {
        let year: Int
        if let ctx = context {
            year = ctx.inferYear(forMonth: month)
        } else {
            let now = Date()
            let calendar = Calendar(identifier: .gregorian)
            year = calendar.component(.year, from: now)
        }

        let calendar = Calendar(identifier: .gregorian)
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
            return nil
        }

        let desc = description.joined(separator: " ")

        return RawTransaction(
            postedAt: date,
            amount: isCredit ? abs(amount) : (amount < 0 ? amount : -abs(amount)),
            currency: "MXN",
            descriptionRaw: normalizer.normalizeDescription(desc),
            merchantNormalized: "",
            fxRateToBase: 1,
            isTransfer: false
        )
    }

    private func parseWideHeaderTable(rows: [TableRow], table: DetectedTable, context: StatementContext?) -> [RawTransaction] {
        var transactions: [RawTransaction] = []
        let dataRows = Array(rows[table.dataRowRange])

        for row in dataRows {
            var dateStr: String?
            var descriptionParts: [String] = []
            var amountTexts: [String] = []

            for cell in row.cells {
                let text = cell.text.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }

                if normalizer.parseDate(text, context: context) != nil {
                    dateStr = text
                } else if text.contains("$") || normalizer.looksLikeAmount(text) {
                    amountTexts.append(text)
                } else {
                    descriptionParts.append(text)
                }
            }

            guard let dateStr, let parsedDate = normalizer.parseDate(dateStr, context: context) else { continue }

            var allAmounts: [Decimal] = []
            for amountText in amountTexts {
                allAmounts.append(contentsOf: extractAllAmounts(from: amountText))
            }

            guard !allAmounts.isEmpty else { continue }

            let transactionAmount: Decimal
            if allAmounts.count >= 2 {
                transactionAmount = allAmounts[0]
            } else {
                transactionAmount = allAmounts[0]
            }

            let desc = descriptionParts.joined(separator: " ").lowercased()
            let isWithdrawal = desc.contains("retiro") || desc.contains("enviada") || desc.contains("cargo")
            let finalAmount = isWithdrawal ? -abs(transactionAmount) : abs(transactionAmount)

            let tx = RawTransaction(
                postedAt: parsedDate.fullDate ?? Date(),
                amount: finalAmount,
                currency: "MXN",
                descriptionRaw: normalizer.normalizeDescription(descriptionParts.joined(separator: " ")),
                merchantNormalized: "",
                fxRateToBase: 1,
                isTransfer: false
            )
            transactions.append(tx)
        }

        return transactions
    }

    private func extractAllAmounts(from text: String) -> [Decimal] {
        let pattern = #"\$\s*([\d,]+\.?\d*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)

        var amounts: [Decimal] = []
        for match in matches {
            guard let amountRange = Range(match.range(at: 1), in: text) else { continue }
            let amountStr = String(text[amountRange]).replacingOccurrences(of: ",", with: "")
            if let value = Decimal(string: amountStr) {
                amounts.append(value)
            }
        }
        return amounts
    }
}
