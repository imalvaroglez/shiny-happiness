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
        let sections = try await parseSections(data: data)
        return sections.flatMap(\.transactions)
    }

    func parseSections(data: Data) async throws -> [ParsedSection] {
        guard let document = PDFDocument(data: data) else {
            throw ParserError.invalidData("Could not create PDF document from data")
        }

        let documentText = extractDocumentText(from: document)
        if let banamex = parseBanamexSections(from: documentText), !banamex.isEmpty {
            return banamex
        }

        var sections: [ParsedSection] = []
        var currentSectionTransactions: [RawTransaction] = []
        var currentSectionHint: String?
        var currentSectionNumber: String?
        var currentSectionType: AccountType?
        var currentSectionNickname: String?
        var currentContext: StatementContext?
        var currentOpeningBalance: Decimal?
        var currentClosingBalance: Decimal?
        var amexMetadata = StatementMetadata()

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let fullText = page.string ?? ""
            amexMetadata.merge(extractAmexMetadata(from: fullText))

            let (accountHint, accountNumber, accountType, nickname) = detectAccountSection(in: fullText)

            let isLegalPage = fullText.contains("Resumen de tus aclaraciones") || fullText.contains("Glosario de Términos")

            if accountHint != nil && accountHint != currentSectionHint && !isLegalPage {
                if !currentSectionTransactions.isEmpty || currentClosingBalance != nil {
                    sections.append(ParsedSection(
                        accountHint: currentSectionHint,
                        accountType: currentSectionType,
                        accountNumber: currentSectionNumber,
                        nickname: currentSectionNickname,
                        openingBalance: currentOpeningBalance,
                        closingBalance: currentClosingBalance,
                        transactions: currentSectionTransactions,
                        creditLimit: nil,
                        minimumPayment: nil,
                        paymentForNoInterest: nil,
                        paymentDueDate: nil,
                        interestCharged: nil,
                        feesCharged: nil,
                        ivaCharged: nil
                    ))
                }
                currentSectionTransactions = []
                currentSectionHint = accountHint
                currentSectionNumber = accountNumber
                currentSectionType = accountType
                currentSectionNickname = nickname
                currentContext = normalizer.extractStatementContext(fullText)
                currentOpeningBalance = nil
                currentClosingBalance = nil
            } else if currentSectionHint == nil {
                let detected = detectAccountSection(in: fullText)
                if detected.hint != nil {
                    currentSectionHint = detected.hint
                    currentSectionNumber = detected.number
                    currentSectionType = detected.type
                    currentSectionNickname = detected.nickname
                }
                currentContext = normalizer.extractStatementContext(fullText)
            }

            if isLegalPage { continue }

            if currentContext == nil {
                currentContext = normalizer.extractStatementContext(fullText)
            }

            if currentClosingBalance == nil, currentSectionHint != nil {
                let summary = extractStatementSummary(from: fullText)
                if summary.closing != nil {
                    currentOpeningBalance = summary.opening
                    currentClosingBalance = summary.closing
                }
            }

            let rows = PDFTextExtractor.extractRows(from: page)
            guard !rows.isEmpty else { continue }

            let pageTransactions = parseRows(rows, context: currentContext)
            currentSectionTransactions.append(contentsOf: pageTransactions)
        }

        if !currentSectionTransactions.isEmpty || currentClosingBalance != nil {
            let isAmex = amexMetadata.hasValues
            sections.append(ParsedSection(
                accountHint: currentSectionHint ?? (isAmex ? "American Express Mexico" : nil),
                accountType: currentSectionType ?? (isAmex ? .creditCard : nil),
                accountNumber: currentSectionNumber ?? amexMetadata.accountNumber,
                nickname: currentSectionNickname ?? (isAmex ? "American Express Mexico" : nil),
                openingBalance: currentOpeningBalance,
                closingBalance: currentClosingBalance ?? amexMetadata.closingBalance,
                transactions: currentSectionTransactions,
                creditLimit: amexMetadata.creditLimit,
                minimumPayment: amexMetadata.minimumPayment,
                paymentForNoInterest: amexMetadata.paymentForNoInterest,
                paymentDueDate: amexMetadata.paymentDueDate,
                interestCharged: amexMetadata.interestCharged,
                feesCharged: amexMetadata.feesCharged,
                ivaCharged: amexMetadata.ivaCharged
            ))
        }

        return sections
    }

    func parseSectionsFromText(_ text: String) -> [ParsedSection] {
        let meta = extractAmexMetadata(from: text)
        return [ParsedSection(
            accountHint: meta.accountNumber,
            accountType: nil,
            accountNumber: meta.accountNumber,
            nickname: nil,
            openingBalance: nil,
            closingBalance: meta.closingBalance,
            transactions: [],
            creditLimit: meta.creditLimit,
            minimumPayment: meta.minimumPayment,
            paymentForNoInterest: meta.paymentForNoInterest,
            paymentDueDate: meta.paymentDueDate,
            interestCharged: meta.interestCharged,
            feesCharged: meta.feesCharged,
            ivaCharged: meta.ivaCharged
        )]
    }

    private struct StatementMetadata {
        var accountNumber: String?
        var closingBalance: Decimal?
        var creditLimit: Decimal?
        var minimumPayment: Decimal?
        var paymentForNoInterest: Decimal?
        var paymentDueDate: Date?
        var interestCharged: Decimal?
        var feesCharged: Decimal?
        var ivaCharged: Decimal?

        var hasValues: Bool {
            accountNumber != nil
                || closingBalance != nil
                || creditLimit != nil
                || minimumPayment != nil
                || paymentForNoInterest != nil
                || paymentDueDate != nil
                || interestCharged != nil
                || feesCharged != nil
                || ivaCharged != nil
        }

        mutating func merge(_ other: StatementMetadata) {
            accountNumber = accountNumber ?? other.accountNumber
            closingBalance = closingBalance ?? other.closingBalance
            creditLimit = creditLimit ?? other.creditLimit
            minimumPayment = minimumPayment ?? other.minimumPayment
            paymentForNoInterest = paymentForNoInterest ?? other.paymentForNoInterest
            paymentDueDate = paymentDueDate ?? other.paymentDueDate
            interestCharged = interestCharged ?? other.interestCharged
            feesCharged = feesCharged ?? other.feesCharged
            ivaCharged = ivaCharged ?? other.ivaCharged
        }
    }

    private func extractAmexMetadata(from text: String) -> StatementMetadata {
        guard text.range(of: "American Express", options: .caseInsensitive) != nil else {
            return StatementMetadata()
        }

        let accountNumber = firstRegexCapture(
            in: text,
            pattern: #"(?:N[uú]mero\s+de\s+Cuenta|Cuenta)\s*:?\s*(?:\*+\s*)?([0-9][0-9\s-]{4,})"#
        ).map { value in
            let digits = value.filter(\.isNumber)
            return String(digits.suffix(10))
        }

        let closing = amountNearAnyLabel(in: text, labels: [
            "Nuevo Saldo",
            "Saldo Nuevo",
            "Saldo Total",
            "Total a Pagar",
            "Saldo al Corte",
            "Saldo Actual"
        ]).map { -abs($0) }

        let creditLimit = amountNearAnyLabel(in: text, labels: [
            "Límite de Crédito",
            "Limite de Credito",
            "Línea de Crédito",
            "Linea de Credito"
        ])

        let minimumPayment = exactColonAmount(in: text, label: "Pago Mínimo")
            ?? exactColonAmount(in: text, label: "Pago Minimo")
            ?? amountNearAnyLabel(in: text, labels: [
                "Pago mínimo requerido",
                "Pago minimo requerido"
            ])

        let noInterest = exactColonAmount(in: text, label: "Pago para no generar intereses")
            ?? exactColonAmount(in: text, label: "Pago Para No Generar Intereses")
            ?? amountNearAnyLabel(in: text, labels: [
                "Pago para no generar interés",
                "Pago para no generar interes"
            ])

        let dueDate = exactColonDate(in: text, label: "Fecha Límite de Pago")
            ?? exactColonDate(in: text, label: "Fecha Limite de Pago")
            ?? dateNearAnyLabel(in: text, labels: [
                "Fecha Límite de Pago",
                "Fecha Limite de Pago",
                "Fecha límite para pago",
                "Fecha limite para pago"
            ])

        let interest = amountNearAnyLabel(in: text, labels: [
            "Monto de Intereses",
            "Intereses del periodo",
            "Cargos por intereses",
            "Intereses cargados"
        ])

        let fees = amountNearAnyLabel(in: text, labels: [
            "Comisiones",
            "Cuotas",
            "Anualidad"
        ])

        let iva = amountNearAnyLabel(in: text, labels: [
            "IVA",
            "I.V.A."
        ])

        return StatementMetadata(
            accountNumber: accountNumber,
            closingBalance: closing,
            creditLimit: creditLimit,
            minimumPayment: minimumPayment,
            paymentForNoInterest: noInterest,
            paymentDueDate: dueDate,
            interestCharged: interest,
            feesCharged: fees,
            ivaCharged: iva
        )
    }

    private func amountNearAnyLabel(in text: String, labels: [String]) -> Decimal? {
        for label in labels {
            if let amount = amountNearLabel(in: text, label: label) {
                return amount
            }
        }
        return nil
    }

    private func amountNearLabel(in text: String, label: String) -> Decimal? {
        let escaped = NSRegularExpression.escapedPattern(for: label)
        let pattern = #"(?is)"# + escaped + #".{0,120}?\$?\s*(-?[\d,]+\.\d{2})"#
        guard let value = firstRegexCapture(in: text, pattern: pattern) else { return nil }
        return Decimal(string: value.replacingOccurrences(of: ",", with: ""))
    }

    private func extractDocumentText(from document: PDFDocument) -> String {
        var text = ""
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            text += page.string ?? ""
            text += "\n"
        }
        return text
    }

    private func parseBanamexSections(from text: String) -> [ParsedSection]? {
        if text.localizedCaseInsensitiveContains("EXPLORA BANAMEX") {
            return [parseBanamexExploraSection(from: text)]
        }
        if text.localizedCaseInsensitiveContains("Cuenta Priority") {
            return [parseBanamexPrioritySection(from: text)]
        }
        return nil
    }

    private func parseBanamexPrioritySection(from text: String) -> ParsedSection {
        let transactions = parseBanamexPriorityTransactions(from: text)
        let accountNumber = firstRegexCapture(
            in: text,
            pattern: #"N[uú]mero\s+de\s+cuenta\s+de\s+cheques\s+([0-9]{6,})"#
        ).map { String($0.filter(\.isNumber).suffix(10)) }

        return ParsedSection(
            accountHint: "Cuenta Priority",
            accountType: .checking,
            accountNumber: accountNumber,
            nickname: "Banamex Priority",
            openingBalance: exactLineAmount(in: text, label: "Saldo anterior"),
            closingBalance: exactLineAmount(in: text, label: "Saldo al corte"),
            transactions: transactions
        )
    }

    private func parseBanamexPriorityTransactions(from text: String) -> [RawTransaction] {
        let year = statementYear(from: text) ?? Calendar(identifier: .gregorian).component(.year, from: .now)
        let opening = exactLineAmount(in: text, label: "Saldo anterior") ?? 0
        var runningBalance = opening
        var transactions: [RawTransaction] = []
        var inOperations = false
        var currentLines: [String] = []

        func flush() {
            guard !currentLines.isEmpty else { return }
            defer { currentLines = [] }

            let entry = currentLines.joined(separator: " ")
            guard let date = banamexPriorityDate(from: entry, year: year) else { return }
            let amounts = decimalMatches(in: entry)
            guard let newBalance = amounts.last else { return }

            let amount = newBalance - runningBalance
            runningBalance = newBalance
            guard amount != 0 else { return }

            let description = cleanBanamexPriorityDescription(entry)
            transactions.append(RawTransaction(
                postedAt: date,
                amount: amount,
                currency: "MXN",
                descriptionRaw: normalizer.normalizeDescription(description),
                merchantNormalized: extractMerchant(from: description),
                fxRateToBase: 1,
                isTransfer: false
            ))
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if line.localizedCaseInsensitiveContains("Domiciliación Banamex")
                || line.localizedCaseInsensitiveContains("Aclaraciones")
                || line.localizedCaseInsensitiveContains("Centro de Atención") {
                flush()
                inOperations = false
            }

            if line.localizedCaseInsensitiveContains("FECHA CONCEPTO RETIROS DEPÓSITOS SALDO") {
                flush()
                inOperations = true
                continue
            }

            guard inOperations else { continue }
            if line.localizedCaseInsensitiveContains("SALDO ANTERIOR") { continue }

            if isBanamexPriorityTransactionStart(line) {
                flush()
                currentLines = [line]
            } else if !currentLines.isEmpty {
                currentLines.append(line)
            }
        }

        flush()
        return transactions
    }

    private func parseBanamexExploraSection(from text: String) -> ParsedSection {
        let transactions = parseBanamexExploraTransactions(from: text)
        let accountNumber = firstRegexCapture(
            in: text,
            pattern: #"N[uú]mero\s+de\s+tarjeta:?\s*([0-9\s]{12,})"#
        ).map { String($0.filter(\.isNumber).suffix(10)) }

        return ParsedSection(
            accountHint: "EXPLORA BANAMEX",
            accountType: .creditCard,
            accountNumber: accountNumber,
            nickname: "Banamex Explora",
            openingBalance: amountAfterLabel(in: text, label: "Adeudo del periodo anterior").map { -abs($0) },
            closingBalance: amountAfterLabel(in: text, label: "Saldo deudor total").map { -abs($0) },
            transactions: transactions,
            creditLimit: amountAfterLabel(in: text, label: "Límite de crédito"),
            minimumPayment: exactColonAmount(in: text, label: "Pago mínimo"),
            paymentForNoInterest: amountAfterLabel(in: text, label: "Pago para no generar intereses"),
            paymentDueDate: dateNearAnyLabel(in: text, labels: ["Fecha límite de pago", "Fecha limite de pago"]),
            interestCharged: amountAfterLabel(in: text, label: "Monto de Intereses"),
            feesCharged: amountAfterLabel(in: text, label: "Monto de comisiones"),
            ivaCharged: amountAfterLabel(in: text, label: "IVA de Intereses y comisiones")
        )
    }

    private func parseBanamexExploraTransactions(from text: String) -> [RawTransaction] {
        var transactions: [RawTransaction] = []
        var inMovements = false
        var currentCardLast4: String?
        var currentLines: [String] = []

        func flush() {
            guard !currentLines.isEmpty else { return }
            defer { currentLines = [] }

            let entry = currentLines.joined(separator: " ")
            guard let parsed = parseBanamexExploraEntry(entry, cardLast4: currentCardLast4) else { return }
            transactions.append(parsed)
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if line.localizedCaseInsensitiveContains("DESGLOSE DE MOVIMIENTOS") {
                inMovements = true
                continue
            }

            guard inMovements else { continue }

            if line.localizedCaseInsensitiveContains("Total cargos Total abonos")
                || line.localizedCaseInsensitiveContains("ATENCIÓN DE QUEJAS") {
                flush()
                inMovements = false
                continue
            }

            if line.localizedCaseInsensitiveContains("CARGOS, ABONOS Y COMPRAS") {
                flush()
                continue
            }

            if let last4 = banamexCardLast4(from: line) {
                flush()
                currentCardLast4 = last4
                continue
            }

            if line.localizedCaseInsensitiveContains("Fecha de la")
                || line.localizedCaseInsensitiveContains("Descripción del movimiento")
                || line.localizedCaseInsensitiveContains("Monto")
                || line == "Fecha" {
                continue
            }

            if isBanamexExploraTransactionStart(line) {
                flush()
                currentLines = [line]
            } else if !currentLines.isEmpty {
                currentLines.append(line)
            }
        }

        flush()
        return transactions
    }

    private func parseBanamexExploraEntry(_ entry: String, cardLast4: String?) -> RawTransaction? {
        guard let dateMatch = firstRegexCapture(
            in: entry,
            pattern: #"^(\d{1,2}-[A-Za-zÁÉÍÓÚáéíóú]{3,4}-\d{4})"#
        ),
        let postedAt = parseStatementDate(dateMatch) else { return nil }

        let signedAmountPattern = #"([+-])\s*\$\s*([\d,]+\.\d{2})"#
        guard let regex = try? NSRegularExpression(pattern: signedAmountPattern) else { return nil }
        let range = NSRange(entry.startIndex..., in: entry)
        guard let match = regex.matches(in: entry, range: range).last,
              let signRange = Range(match.range(at: 1), in: entry),
              let amountRange = Range(match.range(at: 2), in: entry),
              let value = Decimal(string: String(entry[amountRange]).replacingOccurrences(of: ",", with: "")) else { return nil }

        let sign = String(entry[signRange])
        let amount = sign == "-" ? abs(value) : -abs(value)
        let description = cleanBanamexExploraDescription(entry)

        return RawTransaction(
            postedAt: postedAt,
            amount: amount,
            currency: "MXN",
            descriptionRaw: normalizer.normalizeDescription(description),
            merchantNormalized: extractMerchant(from: description),
            fxRateToBase: 1,
            isTransfer: false,
            cardLast4: cardLast4
        )
    }

    private func statementYear(from text: String) -> Int? {
        firstRegexCapture(in: text, pattern: #"(?:Fecha de corte|Periodo|Per[ií]odo).{0,80}?(\d{4})"#)
            .flatMap(Int.init)
    }

    private func exactLineAmount(in text: String, label: String) -> Decimal? {
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.localizedCaseInsensitiveContains(label) else { continue }
            if let amount = decimalMatches(in: line).last {
                return amount
            }
        }
        return nil
    }

    private func exactColonAmount(in text: String, label: String) -> Decimal? {
        let escaped = NSRegularExpression.escapedPattern(for: label)
        let pattern = #"(?im)^\s*"# + escaped + #"\s*:\s*\d*[^\n$]*\$?\s*([\d,]+\.\d{2})"#
        guard let value = firstRegexCapture(in: text, pattern: pattern) else { return nil }
        return Decimal(string: value.replacingOccurrences(of: ",", with: ""))
    }

    private func exactColonDate(in text: String, label: String) -> Date? {
        let escaped = NSRegularExpression.escapedPattern(for: label)
        let pattern = #"(?im)^\s*"# + escaped + #"\s*:\s*(.+)$"#
        guard let value = firstRegexCapture(in: text, pattern: pattern) else { return nil }
        return parseStatementDate(value.trimmingCharacters(in: .whitespaces))
    }

    private func amountAfterLabel(in text: String, label: String) -> Decimal? {
        let escaped = NSRegularExpression.escapedPattern(for: label)
        let pattern = #"(?is)"# + escaped + #".{0,80}?\$?\s*([\d,]+\.\d{2})"#
        guard let value = firstRegexCapture(in: text, pattern: pattern) else { return nil }
        return Decimal(string: value.replacingOccurrences(of: ",", with: ""))
    }

    private func decimalMatches(in text: String) -> [Decimal] {
        let pattern = #"\$?\s*([\d,]+\.\d{2})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let amountRange = Range(match.range(at: 1), in: text) else { return nil }
            return Decimal(string: String(text[amountRange]).replacingOccurrences(of: ",", with: ""))
        }
    }

    private func banamexPriorityDate(from text: String, year: Int) -> Date? {
        guard let dateText = firstRegexCapture(in: text, pattern: #"^(\d{1,2}\s+[A-ZÁÉÍÓÚ]{3})\b"#) else {
            return nil
        }
        let parts = dateText.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard parts.count == 2, let day = Int(parts[0]), let month = spanishShortMonth(parts[1]) else {
            return nil
        }
        return Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: day))
    }

    private func isBanamexPriorityTransactionStart(_ line: String) -> Bool {
        line.range(of: #"^\d{1,2}\s+[A-ZÁÉÍÓÚ]{3}\b"#, options: .regularExpression) != nil
    }

    private func isBanamexExploraTransactionStart(_ line: String) -> Bool {
        line.range(of: #"^\d{1,2}-[A-Za-zÁÉÍÓÚáéíóú]{3,4}-\d{4}\b"#, options: .regularExpression) != nil
    }

    private func banamexCardLast4(from line: String) -> String? {
        guard line.localizedCaseInsensitiveContains("Tarjeta titular")
                || line.localizedCaseInsensitiveContains("Tarjeta digital") else { return nil }
        return firstRegexCapture(in: line, pattern: #"Tarjeta\s+(?:titular|digital):\s*([0-9\s]{12,})"#)
            .map { String($0.filter(\.isNumber).suffix(4)) }
    }

    private func cleanBanamexPriorityDescription(_ entry: String) -> String {
        entry
            .replacingOccurrences(of: #"^\d{1,2}\s+[A-ZÁÉÍÓÚ]{3}\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?:\s+\$?\s*[\d,]+\.\d{2})+\s*$"#, with: "", options: .regularExpression)
    }

    private func cleanBanamexExploraDescription(_ entry: String) -> String {
        entry
            .replacingOccurrences(of: #"^\d{1,2}-[A-Za-zÁÉÍÓÚáéíóú]{3,4}-\d{4}\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^\d{1,2}-[A-Za-zÁÉÍÓÚáéíóú]{3,4}-\d{4}\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+[+-]\s*\$\s*[\d,]+\.\d{2}\s*$"#, with: "", options: .regularExpression)
    }

    private func spanishShortMonth(_ value: String) -> Int? {
        switch value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es_MX")).uppercased() {
        case "ENE": return 1
        case "FEB": return 2
        case "MAR": return 3
        case "ABR": return 4
        case "MAY": return 5
        case "JUN": return 6
        case "JUL": return 7
        case "AGO": return 8
        case "SEP", "SEPT": return 9
        case "OCT": return 10
        case "NOV": return 11
        case "DIC": return 12
        default: return nil
        }
    }

    private func dateNearAnyLabel(in text: String, labels: [String]) -> Date? {
        for label in labels {
            if let date = dateNearLabel(in: text, label: label) {
                return date
            }
        }
        return nil
    }

    private func dateNearLabel(in text: String, label: String) -> Date? {
        let escaped = NSRegularExpression.escapedPattern(for: label)
        let datePattern = #"(\d{1,2}[-/]\w{3,4}[-/]\d{4}|\d{1,2}/\d{1,2}/\d{2,4}|\d{1,2}\s+de\s+\w+\s+de\s+\d{4}|\d{1,2}\s+de\s+\w+\s+\d{4})"#
        let pattern = #"(?is)"# + escaped + #".{0,120}?"# + datePattern
        guard let value = firstRegexCapture(in: text, pattern: pattern) else { return nil }
        return parseStatementDate(value)
    }

    private func parseStatementDate(_ value: String) -> Date? {
        let formats = [
            ("dd-MMM-yyyy", "es_MX"),
            ("dd/MMM/yyyy", "es_MX"),
            ("dd/MM/yyyy", "es_MX"),
            ("dd/MM/yy", "es_MX"),
            ("dd 'de' MMMM yyyy", "es_MX"),
            ("dd 'de' MMMM 'de' yyyy", "es_MX"),
            ("dd-MMM-yyyy", "en_US_POSIX"),
            ("dd/MMM/yyyy", "en_US_POSIX")
        ]

        for (format, locale) in formats {
            let formatter = DateFormatter()
            formatter.dateFormat = format
            formatter.locale = Locale(identifier: locale)
            formatter.timeZone = TimeZone(identifier: "America/Mexico_City")
            if let date = formatter.date(from: value) {
                return date
            }
        }
        return nil
    }

    private func firstRegexCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[captureRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func detectAccountSection(in text: String) -> (hint: String?, number: String?, type: AccountType?, nickname: String?) {
        let lines = text.components(separatedBy: "\n")
        let headerLines = Array(lines.prefix(12).map { $0.trimmingCharacters(in: .whitespaces) })

        for line in headerLines {
            let savingsExact = ["Apartado Open +", "Apartados Open +", "Apartado Open", "Apartados Open"]
            for pattern in savingsExact {
                if line.caseInsensitiveCompare(pattern) == .orderedSame {
                    let number = extractAccountNumber(from: text)
                    return (pattern, number, .savings, "Openbank Apartados")
                }
            }
        }

        for line in headerLines {
            let checkingExact = ["Cuenta Débito Open +", "Cuenta Débito Open"]
            for pattern in checkingExact {
                if line.caseInsensitiveCompare(pattern) == .orderedSame {
                    let number = extractAccountNumber(from: text)
                    return (pattern, number, .checking, "Openbank Débito")
                }
            }
        }

        return (nil, nil, nil, nil)
    }

    private func extractAccountNumber(from text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"CLABE\s*:?\s*\d{16,18}|"# + #"Cuenta\s*:?\s*\d{8,20}|"# + #"No\.\s*:?\s*\d{6,20}|"# + #"contrato\s*:?\s*\d{6,20}"#) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)
        if let match = matches.first {
            guard let r = Range(match.range, in: text) else { return nil }
            let raw = String(text[r]).filter(\.isNumber)
            if raw.count >= 4 { return String(raw.suffix(4)) }
        }
        return nil
    }

    private func parseRows(_ rows: [TableRow], context: StatementContext?) -> [RawTransaction] {
        if let table = columnDetector.detectTable(in: rows) {
            let allSameX = table.columns.count >= 2 && table.columns.allSatisfy({ abs($0.xCenter - table.columns[0].xCenter) < 50 })
            if allSameX {
                let gridResult = parseWideHeaderTable(rows: rows, table: table, context: context)
                if !gridResult.isEmpty {
                    return gridResult
                }
            }

            let result: [RawTransaction]
            switch table.layout {
            case .flow:
                result = parseFlowTable(rows: rows, table: table, context: context)
            case .grid:
                result = parseGridTable(rows: rows, table: table, context: context)
            }

            if !result.isEmpty {
                return result
            }
        }

        return parseLineByLine(rows: rows, context: context)
    }

    private func parseLineByLine(rows: [TableRow], context: StatementContext?) -> [RawTransaction] {
        var transactions: [RawTransaction] = []
        var inTransactionSection = false
        var currentConvention: String? = nil

        for (_, row) in rows.enumerated() {
            let lineText = row.cells.map { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard !lineText.isEmpty else { continue }

            if columnDetector.vocabulary.isSectionStart(lineText) {
                inTransactionSection = true
                currentConvention = nil
                continue
            }

            if columnDetector.vocabulary.isSectionEnd(lineText) {
                inTransactionSection = false
                continue
            }

            guard inTransactionSection else { continue }

            if lineText.contains("Fecha") && (lineText.contains("Concepto") || lineText.contains("Importe") || lineText.contains("Monto") || lineText.contains("Descripción")) {
                currentConvention = detectConvention(from: lineText)
                continue
            }

            let parsed = parseSingleLine(lineText, context: context, convention: currentConvention)
            if !parsed.isEmpty {
                transactions.append(contentsOf: parsed)
            }
        }

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

        let splitColumnPattern = #"^(\d{1,2}/\d{1,2}(?:/\d{2,4})?)\s+(.+?)\s+[+-]?\s*\$\s*([\d,]+\.?\d*)\s+[+-]?\s*\$\s*([\d,]+\.?\d*)\s*$"#
        if let regex = try? NSRegularExpression(pattern: splitColumnPattern, options: .caseInsensitive) {
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            if let match = regex.firstMatch(in: trimmed, range: range),
               let dateRange = Range(match.range(at: 1), in: trimmed),
               let descRange = Range(match.range(at: 2), in: trimmed),
               let amountRange = Range(match.range(at: 3), in: trimmed) {

                let dateStr = String(trimmed[dateRange])
                let descStr = String(trimmed[descRange])
                let amountStr = String(trimmed[amountRange])

                if let parsedDate = normalizer.parseDate(dateStr, context: context),
                   parsedDate.confidence >= .low {
                    let valueStr = amountStr.replacingOccurrences(of: ",", with: "")
                    if let decimalValue = Decimal(string: valueStr) {
                        let desc = cleanDescription(descStr)
                        let isCredit = desc.lowercased().contains("abono") || desc.lowercased().contains("deposito") || desc.lowercased().contains("depósito")
                        let amount: Decimal = isCredit ? abs(decimalValue) : -abs(decimalValue)

                        return RawTransaction(
                            postedAt: parsedDate.fullDate ?? Date(),
                            amount: amount,
                            currency: "MXN",
                            descriptionRaw: normalizer.normalizeDescription(desc),
                            merchantNormalized: extractMerchant(from: desc),
                            fxRateToBase: 1,
                            isTransfer: false
                        )
                    }
                }
            }
        }

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
            merchantNormalized: extractMerchant(from: description),
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
                merchantNormalized: extractMerchant(from: desc),
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
            merchantNormalized: extractMerchant(from: desc),
            fxRateToBase: 1,
            isTransfer: false
        )
    }

    private func parseWideHeaderTable(rows: [TableRow], table: DetectedTable, context: StatementContext?) -> [RawTransaction] {
        var transactions: [RawTransaction] = []
        let dataRows = Array(rows[table.dataRowRange])

        for (_, row) in dataRows.enumerated() {
            var dateStr: String?
            var descriptionParts: [String] = []
            var amountTexts: [String] = []

            for cell in row.cells {
                let text = cell.text.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }

                let containsAmount = text.contains("$") || normalizer.looksLikeAmount(text)
                let startsWithDate = normalizer.parseDate(text, context: context) != nil
                let startsWithDatePrefix = text.range(of: #"^\d{1,2}/\d{1,2}/\d{2,4}\s"#, options: .regularExpression) != nil

                if startsWithDate && !containsAmount {
                    dateStr = text
                } else if startsWithDatePrefix && containsAmount {
                    let splitSegments = splitByDates(text)
                    for segment in splitSegments {
                        if let tx = parseSingleTransactionSegment(segment, context: context, convention: nil) {
                            transactions.append(tx)
                        }
                    }
                    dateStr = nil
                    continue
                } else if startsWithDatePrefix && !containsAmount {
                    let datePrefixRegex = try? NSRegularExpression(pattern: #"^(\d{1,2}/\d{1,2}/\d{2,4})\s+(.+)$"#)
                    if let match = datePrefixRegex?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                       let dateRange = Range(match.range(at: 1), in: text),
                       let descRange = Range(match.range(at: 2), in: text) {
                        dateStr = String(text[dateRange])
                        descriptionParts.append(String(text[descRange]))
                    }
                } else if containsAmount {
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
            let isWithdrawal = desc.contains("retiro") || desc.contains("enviada") || desc.contains("cargo") || desc.contains("isr")
            let finalAmount = isWithdrawal ? -abs(transactionAmount) : abs(transactionAmount)

            let tx = RawTransaction(
                postedAt: parsedDate.fullDate ?? Date(),
                amount: finalAmount,
                currency: "MXN",
                descriptionRaw: normalizer.normalizeDescription(descriptionParts.joined(separator: " ")),
                merchantNormalized: extractMerchant(from: descriptionParts.joined(separator: " ")),
                fxRateToBase: 1,
                isTransfer: false
            )
            transactions.append(tx)
        }

        return transactions
    }

    private func extractStatementSummary(from text: String) -> (opening: Decimal?, closing: Decimal?) {
        guard text.contains("Resumen del periodo") || text.contains("Resumen informativo") else {
            return (nil, nil)
        }

        var openingBalance: Decimal?
        var closingBalance: Decimal?

        let openingPattern = #"Saldo\s+inicial\s+(?:de\s+)?\$\s*([\d,]+\.?\d*)"#
        if let regex = try? NSRegularExpression(pattern: openingPattern, options: .caseInsensitive) {
            let range = NSRange(text.startIndex..., in: text)
            if let match = regex.firstMatch(in: text, range: range),
               let valueRange = Range(match.range(at: 1), in: text) {
                let valueStr = String(text[valueRange]).replacingOccurrences(of: ",", with: "")
                openingBalance = Decimal(string: valueStr)
            }
        }

        let closingPattern = #"Saldo\s+final\s+\$\s*([\d,]+\.?\d*)"#
        if let regex = try? NSRegularExpression(pattern: closingPattern, options: .caseInsensitive) {
            let range = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, range: range)
            for match in matches {
                if let valueRange = Range(match.range(at: 1), in: text) {
                    let valueStr = String(text[valueRange]).replacingOccurrences(of: ",", with: "")
                    closingBalance = Decimal(string: valueStr)
                }
            }
        }

        return (openingBalance, closingBalance)
    }

    private func cleanDescription(_ descStr: String) -> String {
        descStr.replacingOccurrences(
            of: #"\s+[A-Z]\s*[A-Z]?\s*$"#,
            with: "",
            options: .regularExpression
        )
    }

    private func extractMerchant(from description: String) -> String {
        if description.contains("; Transferencia SPEI") {
            let parts = description.components(separatedBy: "; Transferencia SPEI")
            if let first = parts.first?.trimmingCharacters(in: .whitespaces), !first.isEmpty {
                return first
            }
        }
        return MerchantExtractor.extractMerchant(from: description) ?? ""
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
