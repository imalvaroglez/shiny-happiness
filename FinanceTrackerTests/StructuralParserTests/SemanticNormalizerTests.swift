import Testing
import Foundation
@testable import FinanceTracker

@Suite("SemanticNormalizer")
struct SemanticNormalizerTests {

    let normalizer: SemanticNormalizer

    init() {
        let patterns = DatePatterns(
            patterns: [
                DatePatterns.Pattern(
                    id: "dd_mm_yy_slash",
                    regex: "^(\\d{1,2})/(\\d{1,2})/(\\d{2,4})$",
                    fields: ["day", "month", "year"],
                    month_map: nil, year_source: nil, year_padding: 2000,
                    continuation: nil, continuation_pattern: nil, continuation_fields: nil,
                    sourced_from: nil
                ),
                DatePatterns.Pattern(
                    id: "dd_mmm_yyyy_dash",
                    regex: "^(\\d{1,2})-(\\w{3,4})-(\\d{4})$",
                    fields: ["day", "month_name_short", "year"],
                    month_map: "spanish_short", year_source: nil, year_padding: nil,
                    continuation: nil, continuation_pattern: nil, continuation_fields: nil,
                    sourced_from: nil
                ),
                DatePatterns.Pattern(
                    id: "dd_de_month_full_inline",
                    regex: "^(\\d{1,2})\\s+de\\s+(Enero|Febrero|Marzo|Abril|Mayo|Junio|Julio|Agosto|Septiembre|Octubre|Noviembre|Diciembre)\\b(.*)$",
                    fields: ["day", "month_name_full", "trailing_description"],
                    month_map: "spanish_full", year_source: "statement_context",
                    year_padding: nil, continuation: nil, continuation_pattern: nil,
                    continuation_fields: nil, sourced_from: nil
                ),
                DatePatterns.Pattern(
                    id: "dd_de_multiline",
                    regex: "^(\\d{1,2})\\s*de$",
                    fields: ["day"],
                    month_map: "spanish_full", year_source: "statement_context",
                    year_padding: nil, continuation: true,
                    continuation_pattern: "^(Enero|Febrero|Marzo|Abril|Mayo|Junio|Julio|Agosto|Septiembre|Octubre|Noviembre|Diciembre)$",
                    continuation_fields: ["month_name_full"],
                    sourced_from: nil
                ),
            ],
            periodPatterns: [
                DatePatterns.PeriodPattern(
                    id: "amex_cutoff_dates",
                    regex: "(\\d{1,2})-(\\w{3,4})-(\\d{4})\\s+(\\d{1,2})-(\\w{3,4})-(\\d{4})",
                    fields: ["cutoff_day", "cutoff_month_short", "cutoff_year",
                             "next_day", "next_month_short", "next_year"],
                    month_map: "spanish_short",
                    sourced_from: nil
                ),
            ],
            monthMaps: [
                "spanish_short": ["Ene": 1, "Feb": 2, "Mar": 3, "Abr": 4, "May": 5, "Jun": 6,
                                   "Jul": 7, "Ago": 8, "Sep": 9, "Oct": 10, "Nov": 11, "Dic": 12],
                "spanish_full": ["Enero": 1, "Febrero": 2, "Marzo": 3, "Abril": 4, "Mayo": 5,
                                  "Junio": 6, "Julio": 7, "Agosto": 8, "Septiembre": 9,
                                  "Octubre": 10, "Noviembre": 11, "Diciembre": 12],
            ]
        )

        let conventions = AmountConventions(
            numberFormat: AmountConventions.NumberFormat(
                thousands_separator: ",",
                decimal_separator: ".",
                currency_symbols: ["$"],
                amount_regex: "(-?)(?:\\$\\s*)?([\\d,]+\\.\\d{2})"
            ),
            conventions: [
                AmountConventions.Convention(
                    id: "cr_suffix",
                    description: "CR suffix convention",
                    charge_sign: -1, credit_sign: 1,
                    credit_marker: "CR", credit_marker_position: "after_amount",
                    detect_hint: nil, deposit_sign: nil, withdrawal_sign: nil,
                    sourced_from: nil
                ),
            ]
        )

        self.normalizer = SemanticNormalizer(datePatterns: patterns, amountConventions: conventions)
    }

    // MARK: - Date Parsing

    @Test("Parses DD/MM/YY format (Openbank)")
    func parsesSlashDate() {
        let result = normalizer.parseDate("15/08/25")
        #expect(result != nil)
        #expect(result?.day == 15)
        #expect(result?.month == 8)
        #expect(result?.year == 2025)
        #expect(result?.confidence == .high)
    }

    @Test("Parses DD-MMM-YYYY format (Amex headers)")
    func parsesDashDate() {
        let result = normalizer.parseDate("11-Ene-2019")
        #expect(result != nil)
        #expect(result?.day == 11)
        #expect(result?.month == 1)
        #expect(result?.year == 2019)
        #expect(result?.confidence == .high)
    }

    @Test("Parses inline Spanish date with trailing description")
    func parsesInlineSpanishDate() {
        let ctx = StatementContext(cutoffMonth: 1, cutoffYear: 2019, startMonth: 12)
        let result = normalizer.parseDate("3 de Enero DIDICHUXING MEXICO", context: ctx)
        #expect(result != nil)
        #expect(result?.day == 3)
        #expect(result?.month == 1)
        #expect(result?.year == 2019)
        #expect(result?.trailingDescription == "DIDICHUXING MEXICO")
        #expect(result?.confidence == .medium)
    }

    @Test("Detects partial date start (multi-line)")
    func detectsPartialDate() {
        #expect(normalizer.isPartialDateStart("12 de"))
        #expect(normalizer.isPartialDateStart("5 de"))
        #expect(!normalizer.isPartialDateStart("12 de Enero"))
    }

    @Test("Extracts day from partial date")
    func extractsPartialDay() {
        #expect(normalizer.parsePartialDay("12 de") == 12)
        #expect(normalizer.parsePartialDay("3 de") == 3)
    }

    @Test("Completes multi-line date from month continuation")
    func completesMultilineDate() {
        let ctx = StatementContext(cutoffMonth: 1, cutoffYear: 2019, startMonth: 12)

        let result = normalizer.parseDateContinuation("Diciembre", partialDay: 12, context: ctx)
        #expect(result != nil)
        #expect(result?.day == 12)
        #expect(result?.month == 12)
        #expect(result?.year == 2018)
        #expect(result?.confidence == .medium)
    }

    @Test("Returns nil for non-month continuation")
    func rejectsNonMonthContinuation() {
        let result = normalizer.parseDateContinuation("PAGO RECIBIDO", partialDay: 12)
        #expect(result == nil)
    }

    // MARK: - Year Inference

    @Test("Infers year: Diciembre before Enero cutoff")
    func yearInferenceDecember() {
        let ctx = StatementContext(cutoffMonth: 1, cutoffYear: 2019, startMonth: 12)
        #expect(ctx.inferYear(forMonth: 12) == 2018)
        #expect(ctx.inferYear(forMonth: 1) == 2019)
    }

    @Test("Infers year: same month as cutoff")
    func yearInferenceSameMonth() {
        let ctx = StatementContext(cutoffMonth: 8, cutoffYear: 2025, startMonth: nil)
        #expect(ctx.inferYear(forMonth: 8) == 2025)
        #expect(ctx.inferYear(forMonth: 7) == 2025)
        #expect(ctx.inferYear(forMonth: 9) == 2024)
    }

    // MARK: - Statement Context Extraction

    @Test("Extracts context from Amex cutoff dates")
    func extractsAmexCutoffContext() {
        let text = "11-Ene-2019 11-Feb-2019"
        let ctx = normalizer.extractStatementContext(text)
        #expect(ctx != nil)
        #expect(ctx?.cutoffMonth == 1)
        #expect(ctx?.cutoffYear == 2019)
    }

    // MARK: - Amount Parsing

    @Test("Parses bare amount as charge (CR suffix convention)")
    func parsesChargeAmount() {
        let result = normalizer.parseAmount("186.55", conventionId: "cr_suffix")
        #expect(result != nil)
        #expect(result?.value == Decimal(string: "-186.55"))
        #expect(result?.isCredit == false)
    }

    @Test("Parses amount with CR suffix as credit")
    func parsesCreditWithCR() {
        let result = normalizer.parseAmount("5,429.12 CR", conventionId: "cr_suffix")
        #expect(result != nil)
        #expect(result?.value == Decimal(string: "5429.12"))
        #expect(result?.isCredit == true)
    }

    @Test("Parses amount with comma thousands separator")
    func parsesAmountWithCommas() {
        let result = normalizer.parseAmount("2,499.98", conventionId: "cr_suffix")
        #expect(result != nil)
        #expect(result?.value == Decimal(string: "-2499.98"))
    }

    @Test("Parses negative signed amount")
    func parsesSignedAmount() {
        let result = normalizer.parseAmount("-500.00")
        #expect(result != nil)
        #expect(result?.isCredit == false)
    }

    @Test("Detects amount-like strings")
    func detectsAmountStrings() {
        #expect(normalizer.looksLikeAmount("186.55"))
        #expect(normalizer.looksLikeAmount("5,429.12"))
        #expect(normalizer.looksLikeAmount("5,429.12 CR"))
        #expect(normalizer.looksLikeAmount("-500.00"))
        #expect(!normalizer.looksLikeAmount("PAGO RECIBIDO"))
        #expect(!normalizer.looksLikeAmount("OXXO STORE"))
    }

    @Test("Detects credit markers")
    func detectsCreditMarkers() {
        #expect(normalizer.isCreditMarker("CR"))
        #expect(normalizer.isCreditMarker("AB"))
        #expect(!normalizer.isCreditMarker("OXXO"))
    }

    // MARK: - Description

    @Test("Normalizes description whitespace")
    func normalizesDescription() {
        let result = normalizer.normalizeDescription("  UBER   TRIP   HELP  ")
        #expect(result == "UBER TRIP HELP")
    }
}
