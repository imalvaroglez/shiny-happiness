import Foundation

enum Confidence: Int, Comparable, Sendable {
    case low = 0
    case medium = 1
    case high = 2

    static func < (lhs: Confidence, rhs: Confidence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct StatementContext: Sendable {
    let cutoffMonth: Int
    let cutoffYear: Int
    let startMonth: Int?

    func inferYear(forMonth month: Int) -> Int {
        if let start = startMonth, start > cutoffMonth {
            return month >= start ? cutoffYear - 1 : cutoffYear
        }
        return month > cutoffMonth ? cutoffYear - 1 : cutoffYear
    }
}

struct ParsedDate: Sendable {
    let day: Int
    let month: Int
    let year: Int?
    let confidence: Confidence
    let trailingDescription: String?

    var fullDate: Date? {
        guard let year else { return nil }
        let calendar = Calendar(identifier: .gregorian)
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }
}

struct ParsedAmount: Sendable {
    let value: Decimal
    let isCredit: Bool
    let confidence: Confidence
}

struct SemanticNormalizer: Sendable {
    let datePatterns: DatePatterns
    let amountConventions: AmountConventions

    init(datePatterns: DatePatterns, amountConventions: AmountConventions) {
        self.datePatterns = datePatterns
        self.amountConventions = amountConventions
    }

    // MARK: - Date Parsing

    func parseDate(_ text: String, context: StatementContext? = nil) -> ParsedDate? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        for pattern in datePatterns.patterns {
            if pattern.continuation == true { continue }

            if let result = tryMatchDate(trimmed, pattern: pattern, context: context) {
                return result
            }
        }
        return nil
    }

    func isPartialDateStart(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        for pattern in datePatterns.patterns where pattern.continuation == true {
            guard let regex = try? NSRegularExpression(pattern: pattern.regex, options: .caseInsensitive) else { continue }
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            if regex.firstMatch(in: trimmed, range: range) != nil {
                return true
            }
        }
        return false
    }

    func parseDateContinuation(_ text: String, partialDay: Int, context: StatementContext? = nil) -> ParsedDate? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)

        let fullSpanishMonths = datePatterns.monthMap(named: "spanish_full")
        for (monthName, monthNum) in fullSpanishMonths {
            if trimmed.caseInsensitiveCompare(monthName) == .orderedSame {
                let year = context?.inferYear(forMonth: monthNum)
                return ParsedDate(
                    day: partialDay,
                    month: monthNum,
                    year: year,
                    confidence: year != nil ? .medium : .low,
                    trailingDescription: nil
                )
            }
        }
        return nil
    }

    func parsePartialDay(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        for pattern in datePatterns.patterns where pattern.continuation == true {
            guard let regex = try? NSRegularExpression(pattern: pattern.regex, options: .caseInsensitive) else { continue }
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            if let match = regex.firstMatch(in: trimmed, range: range) {
                if let dayRange = Range(match.range(at: 1), in: trimmed),
                   let day = Int(trimmed[dayRange]) {
                    return day
                }
            }
        }
        return nil
    }

    // MARK: - Statement Context

    func extractStatementContext(_ text: String) -> StatementContext? {
        for periodPattern in datePatterns.periodPatterns {
            guard let regex = try? NSRegularExpression(pattern: periodPattern.regex, options: .caseInsensitive) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            guard let match = regex.firstMatch(in: text, range: range) else { continue }

            let monthMapName = periodPattern.month_map ?? "spanish_short"
            let monthMap = datePatterns.monthMap(named: monthMapName)

            if periodPattern.id == "amex_period_header" {
                return extractAmexPeriodContext(from: match, in: text, monthMap: monthMap)
            } else if periodPattern.id == "amex_cutoff_dates" {
                return extractAmexCutoffContext(from: match, in: text, monthMap: monthMap)
            } else if periodPattern.id == "banorte_period" {
                return extractBanortePeriodContext(from: match, in: text, monthMap: monthMap)
            } else if periodPattern.id == "banorte_cutoff_date" {
                return extractBanorteCutoffContext(from: match, in: text, monthMap: monthMap)
            }
        }
        return nil
    }

    // MARK: - Amount Parsing

    func parseAmount(_ text: String, conventionId: String? = nil) -> ParsedAmount? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)

        let numberRegex = try? NSRegularExpression(
            pattern: "(-?)(?:\\$\\s*)?([\\d,]+\\.\\d{2})",
            options: .caseInsensitive
        )
        guard let regex = numberRegex else { return nil }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, range: range) else { return nil }

        let signRange = Range(match.range(at: 1), in: trimmed)
        let valueRange = Range(match.range(at: 2), in: trimmed)
        guard let valueRange else { return nil }

        let signStr = signRange.map { String(trimmed[$0]) } ?? ""
        let valueStr = String(trimmed[valueRange]).replacingOccurrences(of: ",", with: "")

        guard let decimalValue = Decimal(string: valueStr) else { return nil }

        let hasExplicitSign = signStr == "-"
        let convention = amountConventions.conventions.first { $0.id == conventionId }

        if let convention, convention.id == "cr_suffix" {
            let isCredit = trimmed.hasSuffix("CR") || trimmed.contains("CR")
            let signMultiplier = Decimal(
                isCredit
                    ? (convention.credit_sign ?? 1)
                    : (convention.charge_sign ?? -1)
            )
            return ParsedAmount(
                value: decimalValue * signMultiplier,
                isCredit: isCredit,
                confidence: .high
            )
        }

        if let convention, convention.id == "trailing_minus" {
            let isCredit = trimmed.hasSuffix("-")
            let signMultiplier = Decimal(
                isCredit
                    ? (convention.credit_sign ?? 1)
                    : (convention.charge_sign ?? -1)
            )
            return ParsedAmount(
                value: decimalValue * signMultiplier,
                isCredit: isCredit,
                confidence: .high
            )
        }

        if hasExplicitSign {
            let signedValue = signStr == "-" ? -decimalValue : decimalValue
            let isCredit = signedValue >= 0
            return ParsedAmount(value: signedValue, isCredit: isCredit, confidence: .high)
        }

        return ParsedAmount(value: decimalValue, isCredit: false, confidence: .high)
    }

    func isCreditMarker(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed == "CR" || trimmed == "AB" || trimmed == "HABER"
    }

    // MARK: - Description Normalization

    func normalizeDescription(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    func looksLikeAmount(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let pattern = "^-?(?:\\$\\s*)?[\\d,]+\\.\\d{2}\\s*(?:CR|-)?$"
        return trimmed.range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: - Private Helpers

    private func tryMatchDate(_ text: String, pattern: DatePatterns.Pattern, context: StatementContext?) -> ParsedDate? {
        guard let regex = try? NSRegularExpression(pattern: pattern.regex, options: .caseInsensitive) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }

        var day: Int?
        var month: Int?
        var year: Int?
        var trailing: String?

        let monthMapName = pattern.month_map ?? ""
        let monthMap = datePatterns.monthMap(named: monthMapName)

        for (index, fieldName) in pattern.fields.enumerated() {
            let groupIndex = index + 1
            guard groupIndex <= match.numberOfRanges,
                  let fieldRange = Range(match.range(at: groupIndex), in: text) else { continue }

            let fieldValue = String(text[fieldRange])

            switch fieldName {
            case "day":
                day = Int(fieldValue)
            case "month":
                month = Int(fieldValue)
            case "year":
                var y = Int(fieldValue) ?? 0
                if let padding = pattern.year_padding, y < 100 {
                    y += padding
                }
                year = y
            case "month_name_short", "month_name_full":
                month = monthMap[fieldValue]
            case "trailing_description":
                trailing = fieldValue.trimmingCharacters(in: .whitespaces)
            default:
                break
            }
        }

        guard let d = day, let m = month else { return nil }

        let inferredYear: Int?
        if let y = year {
            inferredYear = y
        } else if pattern.year_source == "statement_context", let ctx = context {
            inferredYear = ctx.inferYear(forMonth: m)
        } else {
            inferredYear = nil
        }

        let confidence: Confidence
        if inferredYear != nil && year != nil {
            confidence = .high
        } else if inferredYear != nil {
            confidence = .medium
        } else {
            confidence = .low
        }

        return ParsedDate(day: d, month: m, year: inferredYear, confidence: confidence, trailingDescription: trailing)
    }

    private func extractAmexPeriodContext(
        from match: NSTextCheckingResult,
        in text: String,
        monthMap: [String: Int]
    ) -> StatementContext? {
        guard match.numberOfRanges >= 6 else { return nil }

        guard let endMonthRange = Range(match.range(at: 4), in: text),
              let endYearRange = Range(match.range(at: 5), in: text),
              let startMonthRange = Range(match.range(at: 2), in: text) else { return nil }

        let endMonthStr = String(text[endMonthRange])
        let endYearStr = String(text[endYearRange])
        let startMonthStr = String(text[startMonthRange])

        guard let endMonth = monthMap[endMonthStr],
              let endYear = Int(endYearStr),
              let startMonth = monthMap[startMonthStr] else { return nil }

        return StatementContext(cutoffMonth: endMonth, cutoffYear: endYear, startMonth: startMonth)
    }

    private func extractAmexCutoffContext(
        from match: NSTextCheckingResult,
        in text: String,
        monthMap: [String: Int]
    ) -> StatementContext? {
        guard match.numberOfRanges >= 7 else { return nil }

        guard let cutoffMonthRange = Range(match.range(at: 2), in: text),
              let cutoffYearRange = Range(match.range(at: 3), in: text) else { return nil }

        let cutoffMonthStr = String(text[cutoffMonthRange])
        let cutoffYearStr = String(text[cutoffYearRange])

        guard let cutoffMonth = monthMap[cutoffMonthStr],
              let cutoffYear = Int(cutoffYearStr) else { return nil }

        return StatementContext(cutoffMonth: cutoffMonth, cutoffYear: cutoffYear, startMonth: nil)
    }

    private func extractBanortePeriodContext(
        from match: NSTextCheckingResult,
        in text: String,
        monthMap: [String: Int]
    ) -> StatementContext? {
        guard match.numberOfRanges >= 6 else { return nil }

        guard let startMonthRange = Range(match.range(at: 2), in: text),
              let _ = Range(match.range(at: 3), in: text),
              let endMonthRange = Range(match.range(at: 4), in: text),
              let endYearRange = Range(match.range(at: 5), in: text) else { return nil }

        let startMonthStr = String(text[startMonthRange])
        let endMonthStr = String(text[endMonthRange])
        let endYearStr = String(text[endYearRange])

        guard let startMonth = monthMap[startMonthStr],
              let endMonth = monthMap[endMonthStr],
              let endYear = Int(endYearStr) else { return nil }

        return StatementContext(cutoffMonth: endMonth, cutoffYear: endYear, startMonth: startMonth)
    }

    private func extractBanorteCutoffContext(
        from match: NSTextCheckingResult,
        in text: String,
        monthMap: [String: Int]
    ) -> StatementContext? {
        guard match.numberOfRanges >= 4 else { return nil }

        guard let cutoffMonthRange = Range(match.range(at: 2), in: text),
              let cutoffYearRange = Range(match.range(at: 3), in: text) else { return nil }

        let cutoffMonthStr = String(text[cutoffMonthRange])
        let cutoffYearStr = String(text[cutoffYearRange])

        guard let cutoffMonth = monthMap[cutoffMonthStr],
              let cutoffYear = Int(cutoffYearStr) else { return nil }

        return StatementContext(cutoffMonth: cutoffMonth, cutoffYear: cutoffYear, startMonth: nil)
    }
}
