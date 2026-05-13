import Foundation
import os

/// Parses pasted HSBC 2Now statement text into per-card sections + a list of
/// `UnparsedLine` records for anything the parser couldn't confidently decode.
///
/// The user pastes raw text from the HSBC web/app portal. Each transaction line
/// has shape:
///   `<opDate>  <postDate>  <description…>  (+|-)  $<amount>`
/// with dates in `dd-Mmm-yyyy` Spanish format. Statement-level fields (period,
/// due date, balances, credit limit) live in a header block; the MSI table sits
/// between the header and the regular-transactions block. Per-card sections
/// start with a "Tarjeta titular 5470...1111" or "Tarjeta adicional ...1112" line.
struct PastedHsbc2NowParser {

    /// Sendable snapshot of a `SignRecoveryHint`, passed in by the pipeline so the
    /// parser can stay free of SwiftData dependencies.
    struct SignHint: Sendable {
        let pattern: String      // case-insensitive regex
        let implicitSign: Int    // -1 = charge (HSBC "+"), +1 = payment (HSBC "-")
    }

    struct UnparsedLine: Sendable {
        let rawText: String
        let reason: String
        let cardLast4: String?
        let parsedDate: Date?
        let parsedAmount: Decimal?
        let parsedDescription: String?
    }

    struct ParseResult: Sendable {
        let sections: [ParsedSection]
        let pendings: [UnparsedLine]
        /// Sum of all `+`-signed amounts the parser recognized. Diagnostics only.
        let parsedTotalCharges: Decimal
        /// Sum of all `-`-signed amounts the parser recognized.
        let parsedTotalPayments: Decimal
    }

    /// Learned hints consulted when a row's description matches but the line lacked
    /// an explicit +/- glyph. Defaults to empty; the pipeline supplies the live set.
    let signHints: [SignHint]

    init(signHints: [SignHint] = []) {
        self.signHints = signHints
    }

    func parse(_ text: String) -> ParseResult {
        let lines = text.components(separatedBy: .newlines)

        let header = parseHeader(lines: lines)
        let installments = parseInstallments(lines: lines, fallbackYear: header.fallbackYear)
        let (cardTransactions, cardPendings) = parseCardSections(lines: lines, fallbackYear: header.fallbackYear)

        // Merge MSI installments into the titular section so MSI cuotas have full context.
        let titularCard = cardTransactions.first { $0.cardLast4 == header.titularCardLast4 ?? "1111" }?.cardLast4
            ?? cardTransactions.first?.cardLast4
            ?? "1111"

        let titularAccountNumber = cardTransactions.first { $0.cardLast4 == titularCard }?.cardLast4
            ?? cardTransactions.first?.cardLast4
            ?? "1111"

        var sections: [ParsedSection] = []
        for (idx, card) in cardTransactions.enumerated() {
            let isPrimary = card.cardLast4 == titularCard
            let installmentRaws: [RawTransaction] = isPrimary ? installments.map { hint in
                RawTransaction(
                    postedAt: hint.firstChargeDate,
                    amount: -hint.originalAmount,
                    currency: "MXN",
                    descriptionRaw: hint.merchantDescription,
                    merchantNormalized: hint.merchantDescription,
                    cardLast4: card.cardLast4,
                    installmentHint: hint
                )
            } : []
            let section = ParsedSection(
                accountHint: "HSBC 2Now",
                accountType: .creditCard,
                accountNumber: titularAccountNumber,
                nickname: isPrimary ? "HSBC 2Now Oro" : "HSBC 2Now Oro (Adicional)",
                openingBalance: isPrimary ? header.previousBalance.map { -$0 } : nil,
                closingBalance: isPrimary ? header.totalBalance.map { -$0 } : nil,
                transactions: installmentRaws + card.transactions,
                creditLimit: isPrimary ? header.creditLimit : nil,
                minimumPayment: isPrimary ? header.minimumPayment : nil,
                paymentForNoInterest: isPrimary ? header.paymentForNoInterest : nil,
                paymentDueDate: isPrimary ? header.paymentDueDate : nil,
                interestCharged: isPrimary ? header.interestCharged : nil,
                feesCharged: isPrimary ? header.feesCharged : nil,
                ivaCharged: isPrimary ? header.ivaCharged : nil
            )
            sections.append(section)
            _ = idx
        }

        let allTxns = sections.flatMap(\.transactions)
        let totalCharges = allTxns.filter { $0.amount < 0 && $0.installmentHint == nil }
            .reduce(Decimal(0)) { $0 + abs($1.amount) }
        let totalPayments = allTxns.filter { $0.amount > 0 }
            .reduce(Decimal(0)) { $0 + $1.amount }

        return ParseResult(
            sections: sections,
            pendings: cardPendings,
            parsedTotalCharges: totalCharges,
            parsedTotalPayments: totalPayments
        )
    }

    // MARK: - Statement header

    struct Header {
        var periodStart: Date?
        var periodEnd: Date?
        var paymentDueDate: Date?
        var paymentForNoInterest: Decimal?
        var minimumPayment: Decimal?
        var previousBalance: Decimal?
        var totalBalance: Decimal?
        var creditLimit: Decimal?
        var interestCharged: Decimal?
        var feesCharged: Decimal?
        var ivaCharged: Decimal?
        var titularCardLast4: String?
        var fallbackYear: Int
    }

    func parseHeader(lines: [String]) -> Header {
        var h = Header(fallbackYear: Calendar.current.component(.year, from: .now))
        let joined = lines.joined(separator: "\n")

        if let m = joined.firstMatch(of: /(\d{1,2})-([A-Za-zñÑáéíóúÁÉÍÓÚ]{3})-(\d{4})\s*al\s*(\d{1,2})-([A-Za-zñÑáéíóúÁÉÍÓÚ]{3})-(\d{4})/) {
            h.periodStart = parseSpanishDate("\(m.1)-\(m.2)-\(m.3)")
            h.periodEnd = parseSpanishDate("\(m.4)-\(m.5)-\(m.6)")
            if let e = h.periodEnd {
                h.fallbackYear = Calendar.current.component(.year, from: e)
            }
        }

        if let m = joined.firstMatch(of: /(?i)l[ií]mite de pago[^\n]*?(\d{1,2})-([A-Za-zñÑáéíóúÁÉÍÓÚ]{3})-(\d{4})/) {
            h.paymentDueDate = parseSpanishDate("\(m.1)-\(m.2)-\(m.3)")
        }

        for (idx, line) in lines.enumerated() {
            if h.paymentForNoInterest == nil, line.range(of: "PAGO PARA NO GENERAR", options: .caseInsensitive) != nil {
                h.paymentForNoInterest = findAmountNear(lines: lines, around: idx)
            }
            if h.minimumPayment == nil, line.range(of: #"Pago m[ií]nimo"#, options: .regularExpression) != nil {
                if line.range(of: "compras y", options: .caseInsensitive) == nil && line.range(of: "cargos diferidos", options: .caseInsensitive) == nil {
                    h.minimumPayment = findAmountNear(lines: lines, around: idx)
                }
            }
            if h.previousBalance == nil, line.range(of: "Adeudo del periodo anterior", options: .caseInsensitive) != nil {
                h.previousBalance = findAmountNear(lines: lines, around: idx)
            }
            if h.totalBalance == nil, line.range(of: "Saldo deudor total", options: .caseInsensitive) != nil {
                h.totalBalance = findAmountNear(lines: lines, around: idx)
            }
            if h.creditLimit == nil, line.range(of: #"L[ií]mite de cr[eé]dito"#, options: .regularExpression) != nil {
                h.creditLimit = findAmountNear(lines: lines, around: idx)
            }
            if h.interestCharged == nil, line.range(of: "Monto de intereses", options: .caseInsensitive) != nil {
                h.interestCharged = findAmountNear(lines: lines, around: idx)
            }
            if h.feesCharged == nil, line.range(of: "Monto de comisiones", options: .caseInsensitive) != nil {
                h.feesCharged = findAmountNear(lines: lines, around: idx)
            }
            if h.ivaCharged == nil, line.range(of: "IVA de intereses", options: .caseInsensitive) != nil {
                h.ivaCharged = findAmountNear(lines: lines, around: idx)
            }
            if h.titularCardLast4 == nil, let m = line.firstMatch(of: /Tarjeta\s+titular\s+\d{12}(\d{4})/) {
                h.titularCardLast4 = String(m.1)
            }
        }

        return h
    }

    /// Find the first parseable amount in a line near `idx`. Returns the absolute value
    /// (sign on header amounts is typically a separate `=`, `+`, or `-` glyph the user pastes
    /// but doesn't affect interpretation: it's a labelled aggregate, not a transaction).
    func findAmountNear(lines: [String], around idx: Int) -> Decimal? {
        for offset in [0, 1, 2, -1, -2] {
            let i = idx + offset
            guard i >= 0, i < lines.count else { continue }
            if let m = lines[i].matches(of: /\$\s*(\d[\d,]*(?:\.\d{1,2})?)/).last {
                if let v = parseAmountBody(String(m.1)) {
                    return v
                }
            }
        }
        return nil
    }

    // MARK: - MSI installments

    func parseInstallments(lines: [String], fallbackYear: Int) -> [RawInstallmentHint] {
        // The MSI block follows a header containing "COMPRAS Y CARGOS DIFERIDOS A MESES SIN INTERESES".
        // Rows have: dd-Mmm-yyyy <desc...> $A $B $C XX de YY R.RR%
        // where A = original amount, B = saldo pendiente, C = pago requerido,
        // XX/YY = cuota counter, R.RR% = rate.
        guard let startIdx = lines.firstIndex(where: { $0.range(of: "COMPRAS Y CARGOS DIFERIDOS A MESES", options: .caseInsensitive) != nil }) else {
            return []
        }
        // End at the next section marker or end of input.
        let endIdx = (startIdx..<lines.count).first { i in
            lines[i].range(of: "CARGOS, ABONOS Y COMPRAS REGULARES", options: .caseInsensitive) != nil
        } ?? lines.count

        var hints: [RawInstallmentHint] = []
        var i = startIdx
        while i < endIdx {
            let line = lines[i]
            // Anchor: a line that opens with a date AND contains "XX de YY" later (possibly on a following line).
            if let dateMatch = line.firstMatch(of: /^\s*(\d{1,2}-[A-Za-zñÑ]{3}-\d{4})\s+/) {
                // Sometimes the row is split across two lines because of long descriptions.
                let block = lines[i..<min(i + 3, endIdx)].joined(separator: " ")
                if let m = block.firstMatch(of: /(\d{1,2})\s*de\s*(\d{1,2})/),
                   let date = parseSpanishDate(String(dateMatch.1)) {
                    // Match `$<digits>[,<digits>...](.<2 digits>)?` — refuses to span into the
                    // following cuota counter like `1,416.25 02`.
                    let dollarMatches = Array(block.matches(of: /\$\s*(\d[\d,]*(?:\.\d{1,2})?)/))
                    let amounts = dollarMatches.compactMap { parseAmountBody(String($0.1)) }
                    if amounts.count >= 3 {
                        let original = amounts[0]
                        let monthly = amounts[2]
                        let rate = block.firstMatch(of: /(\d+(?:\.\d+)?)\s*%/).flatMap { Decimal(string: String($0.1)) } ?? 0
                        let current = Int(String(m.1)) ?? 1
                        let total = Int(String(m.2)) ?? 0

                        // Description: between the leading date and the first $ amount.
                        var description = ""
                        if let dollarRange = block.range(of: "$") {
                            let prefix = block[block.startIndex..<dollarRange.lowerBound]
                            description = String(prefix)
                                .replacingOccurrences(of: dateMatch.0, with: "")
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                        }

                        hints.append(RawInstallmentHint(
                            originalAmount: original,
                            totalMonths: total,
                            currentMonth: current,
                            monthlyAmount: monthly,
                            ratePercent: rate,
                            firstChargeDate: date,
                            merchantDescription: description.isEmpty ? "MSI Installment" : description
                        ))
                    }
                }
            }
            i += 1
        }
        return hints
    }

    // MARK: - Per-card transaction sections

    struct CardBucket {
        let cardLast4: String
        let transactions: [RawTransaction]
    }

    func parseCardSections(lines: [String], fallbackYear: Int) -> ([CardBucket], [UnparsedLine]) {
        // Skip everything until the first "CARGOS, ABONOS Y COMPRAS REGULARES" marker.
        guard let startIdx = lines.firstIndex(where: { $0.range(of: "CARGOS, ABONOS Y COMPRAS REGULARES", options: .caseInsensitive) != nil }) else {
            return ([], [])
        }

        var scope: String? = nil
        var bucketed: [String: [RawTransaction]] = [:]
        var pendings: [UnparsedLine] = []

        var i = startIdx
        while i < lines.count {
            let line = lines[i]
            // Detect section header switch.
            if let m = line.firstMatch(of: /Tarjeta\s+(?:titular|adicional)\s+\d{12}(\d{4})/) {
                scope = String(m.1)
                if bucketed[scope!] == nil { bucketed[scope!] = [] }
                i += 1
                continue
            }
            // Skip column header rows.
            if line.range(of: #"Fecha de.*operaci[oó]n"#, options: .regularExpression) != nil
                || line.range(of: "Descripción del movimiento", options: .caseInsensitive) != nil
                || line.range(of: #"^\s*$"#, options: .regularExpression) != nil
                || line.range(of: "Total cargos", options: .caseInsensitive) != nil
                || line.range(of: "Total abonos", options: .caseInsensitive) != nil {
                i += 1
                continue
            }

            if let s = scope {
                if let txn = parseTransactionLine(line, cardLast4: s) {
                    bucketed[s, default: []].append(txn)
                } else if looksLikeTransactionAttempt(line) {
                    pendings.append(UnparsedLine(
                        rawText: line,
                        reason: "Could not parse all of (date, amount, description) from this row",
                        cardLast4: s,
                        parsedDate: extractFirstDate(line),
                        parsedAmount: extractLastAmount(line),
                        parsedDescription: extractDescription(line)
                    ))
                }
            }
            i += 1
        }

        // Order: titular (suffix 1111, then anything else) first.
        let buckets = bucketed
            .map { CardBucket(cardLast4: $0.key, transactions: $0.value) }
            .sorted { (lhs, rhs) -> Bool in
                let lPri = lhs.cardLast4.hasSuffix("1111") ? 0 : 1
                let rPri = rhs.cardLast4.hasSuffix("1111") ? 0 : 1
                return lPri < rPri
            }
        return (buckets, pendings)
    }

    /// Try to parse a single transaction row. Shape:
    ///   `<dd-Mmm-yyyy> <dd-Mmm-yyyy> <description…> <+ or -> $<amount>`
    /// The two dates may be the same (op + posting). Description spans the space between
    /// the second date and the sign. Sign+amount is at the line's tail.
    ///
    /// If the strict pattern fails to match because the sign glyph is missing, the
    /// parser tries a loose pattern and consults `signHints` to recover the sign
    /// from the description. If no hint matches, returns nil — the pipeline will
    /// stage the line as a `PendingImport`.
    func parseTransactionLine(_ line: String, cardLast4: String) -> RawTransaction? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Pattern: leading date(s), description, then trailing sign + $ + amount.
        let strict = #/^(\d{1,2}-[A-Za-zñÑáéíóúÁÉÍÓÚ]{3}-\d{4})\s+(\d{1,2}-[A-Za-zñÑáéíóúÁÉÍÓÚ]{3}-\d{4})\s+(.+?)\s+([+\-])\s*\$\s*(\d[\d,]*(?:\.\d{1,2})?)\s*$/#

        if let m = trimmed.firstMatch(of: strict) {
            guard let opDate = parseSpanishDate(String(m.1)) else { return nil }
            let postDate = parseSpanishDate(String(m.2)) ?? opDate
            let description = String(m.3).trimmingCharacters(in: .whitespacesAndNewlines)
            let signChar = String(m.4)
            guard let absAmount = parseAmountBody(String(m.5)) else { return nil }

            // HSBC convention: '+' = charge (debt up, money out of pocket);
            // '-' = payment/refund. App convention: positive = money in, negative = money out.
            // Flip the HSBC sign; then let a learned hint override if the description
            // matches a known payment/charge phrase.
            var appAmount: Decimal = (signChar == "-") ? absAmount : -absAmount
            if let override = signHintOverride(for: description) {
                appAmount = override > 0 ? absAmount : -absAmount
            }

            return RawTransaction(
                postedAt: postDate,
                amount: appAmount,
                currency: "MXN",
                descriptionRaw: description,
                merchantNormalized: description,
                cardLast4: cardLast4
            )
        }

        // Loose pattern: tail amount with no `+`/`-` sign. Only accepted when a
        // learned SignRecoveryHint matches the description.
        let loose = #/^(\d{1,2}-[A-Za-zñÑáéíóúÁÉÍÓÚ]{3}-\d{4})\s+(\d{1,2}-[A-Za-zñÑáéíóúÁÉÍÓÚ]{3}-\d{4})\s+(.+?)\s+\$\s*(\d[\d,]*(?:\.\d{1,2})?)\s*$/#
        guard let m = trimmed.firstMatch(of: loose) else { return nil }
        guard let opDate = parseSpanishDate(String(m.1)) else { return nil }
        let postDate = parseSpanishDate(String(m.2)) ?? opDate
        let description = String(m.3).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let absAmount = parseAmountBody(String(m.4)) else { return nil }
        guard let override = signHintOverride(for: description) else { return nil }

        let appAmount: Decimal = override > 0 ? absAmount : -absAmount
        return RawTransaction(
            postedAt: postDate,
            amount: appAmount,
            currency: "MXN",
            descriptionRaw: description,
            merchantNormalized: description,
            cardLast4: cardLast4
        )
    }

    /// Returns `+1` or `-1` if a `SignHint` matches `description` (or `nil` if none).
    /// Implicit sign is in **app convention** (positive = money in).
    private func signHintOverride(for description: String) -> Int? {
        for hint in signHints {
            if description.range(of: hint.pattern, options: .regularExpression) != nil {
                return hint.implicitSign >= 0 ? 1 : -1
            }
        }
        return nil
    }

    private func looksLikeTransactionAttempt(_ line: String) -> Bool {
        // A "looks like a transaction attempt" line has at least a leading date OR a `$` amount.
        line.range(of: #"^\s*\d{1,2}-[A-Za-zñÑ]{3}-\d{4}"#, options: .regularExpression) != nil
            || line.contains("$")
    }

    private func extractFirstDate(_ line: String) -> Date? {
        guard let m = line.firstMatch(of: /(\d{1,2}-[A-Za-zñÑáéíóúÁÉÍÓÚ]{3}-\d{4})/) else { return nil }
        return parseSpanishDate(String(m.1))
    }

    private func extractLastAmount(_ line: String) -> Decimal? {
        let matches = Array(line.matches(of: /([+\-]?)\s*\$\s*(\d[\d,]*(?:\.\d{1,2})?)/))
        guard let m = matches.last, let body = parseAmountBody(String(m.2)) else { return nil }
        let sign = String(m.1)
        return sign == "-" ? body : -body
    }

    private func extractDescription(_ line: String) -> String? {
        // Drop leading dates and trailing amount tokens.
        let stripped = line
            .replacing(/^\s*(?:\d{1,2}-[A-Za-zñÑáéíóúÁÉÍÓÚ]{3}-\d{4}\s+){1,2}/, with: "")
            .replacing(/\s+[+\-]?\s*\$\s*\d[\d,]*(?:\.\d{1,2})?\s*$/, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? nil : stripped
    }

    // MARK: - Numeric helpers

    /// Convert an HSBC pasted amount body (`"25,986.00"`, `"4.776.50"`, `"1 876.85"`, `"104.3"`)
    /// to a clean Decimal-parseable form, treating any of `,` `.` ` ` as candidate thousands
    /// separators. The last `.` followed by ≤2 digits is the decimal point.
    func parseAmountBody(_ raw: String) -> Decimal? {
        let filtered = raw.filter { $0.isNumber || $0 == "." || $0 == "," || $0 == " " }
        var working = filtered.replacingOccurrences(of: ",", with: "")
        working = working.replacingOccurrences(of: " ", with: "")
        let dotCount = working.filter { $0 == "." }.count
        if dotCount > 1 {
            guard let lastDot = working.lastIndex(of: ".") else { return nil }
            let prefix = working[..<lastDot].replacingOccurrences(of: ".", with: "")
            let suffix = working[lastDot...]
            working = prefix + suffix
        }
        return Decimal(string: working)
    }

    private static let spanishMonths: [String: Int] = [
        "ene": 1, "feb": 2, "mar": 3, "abr": 4, "may": 5, "jun": 6,
        "jul": 7, "ago": 8, "sep": 9, "oct": 10, "nov": 11, "dic": 12,
    ]

    func parseSpanishDate(_ raw: String) -> Date? {
        let parts = raw.split(separator: "-").map(String.init)
        guard parts.count == 3 else { return nil }
        let dayDigits = parts[0].filter(\.isNumber)
        let yearDigits = parts[2].filter(\.isNumber)
        guard let day = Int(dayDigits),
              let month = PastedHsbc2NowParser.spanishMonths[parts[1].lowercased()],
              let year = Int(yearDigits),
              day >= 1, day <= 31,
              year >= 2000, year <= 2100 else { return nil }
        var comps = DateComponents()
        comps.day = day
        comps.month = month
        comps.year = year
        comps.timeZone = TimeZone(identifier: "America/Mexico_City")
        return Calendar(identifier: .gregorian).date(from: comps)
    }
}
