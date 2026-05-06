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
            log.debug("Page \(pageIndex): \(pageTransactions.count) transactions extracted")
            allTransactions.append(contentsOf: pageTransactions)
        }

        log.info("StructuralParser: total \(allTransactions.count) transactions from \(document.pageCount) pages")
        return allTransactions
    }

    private func parseRows(_ rows: [TableRow], context: StatementContext?) -> [RawTransaction] {
        guard let table = columnDetector.detectTable(in: rows) else {
            Logger.parser.debug("No table detected in \(rows.count) rows")
            return []
        }

        Logger.parser.debug("Detected table: layout=\(String(describing: table.layout)), columns=\(table.columns.count), convention=\(table.amountConvention ?? "none"), dataRows=\(table.dataRowRange.count)")

        if table.columns.count >= 2, table.columns.allSatisfy({ abs($0.xCenter - table.columns[0].xCenter) < 50 }) {
            return parseWideHeaderTable(rows: rows, table: table, context: context)
        }

        switch table.layout {
        case .flow:
            return parseFlowTable(rows: rows, table: table, context: context)
        case .grid:
            return parseGridTable(rows: rows, table: table, context: context)
        }
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
