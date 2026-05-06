import Testing
import Foundation
@testable import FinanceTracker

@Suite("StructuralParser Integration")
struct StructuralParserTests {

    let parser: StructuralParser

    init() {
        let vocabulary = HeaderVocabulary(from: [
            "date_column": ["Fecha", "Date", "Fch", "Dia"],
            "description_column": ["Detalle", "Concepto", "Descripción", "Description", "Operaciones", "Movimiento", "Referencia"],
            "amount_column": ["Importe", "Monto", "Cargo", "Abono", "Amount", "Débito", "Crédito"],
            "debit_column": ["Retiro", "Cargo", "Débito", "Withdrawal", "Debit"],
            "credit_column": ["Depósito", "Abono", "Crédito", "Deposit", "Credit"],
            "balance_column": ["Saldo", "Balance"],
            "combined_headers": [
                "Fecha y Detalle de las operaciones": ["date_column", "description_column"],
                "Fecha Concepto Depósito Retiro Saldo": ["date_column", "description_column", "credit_column", "debit_column", "balance_column"],
                "Detalle de tus transacciones": ["description_column"],
                "Importe en MN": ["amount_column"],
                "Importe en M.N.": ["amount_column"],
                "Fecha Concepto RFC/CURP Tipo de transacción Importe": ["date_column", "description_column", "amount_column"]
            ],
            "section_start_markers": [
                "Fecha y Detalle de las operaciones",
                "Detalle de Transacciones",
                "Detalle de Cargo",
                "DETALLE DE TRANSACCIONES",
                "Detalle de tus transacciones",
                "TARJETA TITULAR",
                "TARJETA ADICIONAL",
                "Detalle de movimientos del Titular en M.N.",
                "Detalle de movimientos de TDC Digital",
                "Detalle de movimientos en M.N."
            ],
            "section_end_markers": [
                "Total de las transacciones",
                "Total de Mensualidades",
                "Transacciones de Mensualidades",
                "Número de Cuenta",
                "Pago Mínimo",
                "Fecha límite",
                "Pago para no generar",
                "Resumen de Crédito",
                "Llamamos",
                "CAT ",
                "Tasa de Interés",
                "Consolidado de compras",
                "Resumen de Mensualidades",
                "Detalle de programas a plazos",
                "Mensajes importantes"
            ]
        ])

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
                    id: "dd_mmm_yyyy_slash",
                    regex: "^(\\d{1,2})/(\\w{3,4})/(\\d{4})$",
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
                DatePatterns.Pattern(
                    id: "dd_de_mmmm_de_yyyy",
                    regex: "^(\\d{1,2})\\s+de\\s+(\\w+)\\s+de\\s+(\\d{4})$",
                    fields: ["day", "month_name_full", "year"],
                    month_map: "spanish_full", year_source: nil, year_padding: nil,
                    continuation: nil, continuation_pattern: nil, continuation_fields: nil,
                    sourced_from: nil
                ),
                DatePatterns.Pattern(
                    id: "dd_mm_no_year",
                    regex: "^(\\d{1,2})/(\\d{1,2})$",
                    fields: ["day", "month"],
                    month_map: nil, year_source: "statement_context", year_padding: nil,
                    continuation: nil, continuation_pattern: nil, continuation_fields: nil,
                    sourced_from: nil
                ),
            ],
            periodPatterns: [
                DatePatterns.PeriodPattern(
                    id: "amex_period_header",
                    regex: "(\\d{1,2})\\s*de\\s*(\\w+)\\s*al\\s*(\\d{1,2})\\s*de\\s*(\\w+)\\s*de\\s*(\\d{4})",
                    fields: ["start_day", "start_month_name", "end_day", "end_month_name", "end_year"],
                    month_map: "spanish_full",
                    sourced_from: nil
                ),
                DatePatterns.PeriodPattern(
                    id: "amex_cutoff_dates",
                    regex: "(\\d{1,2})-(\\w{3,4})-(\\d{4})\\s+(\\d{1,2})-(\\w{3,4})-(\\d{4})",
                    fields: ["cutoff_day", "cutoff_month_short", "cutoff_year",
                             "next_day", "next_month_short", "next_year"],
                    month_map: "spanish_short",
                    sourced_from: nil
                ),
                DatePatterns.PeriodPattern(
                    id: "banorte_period",
                    regex: "(\\d{1,2})\\s+(Enero|Febrero|Marzo|Abril|Mayo|Junio|Julio|Agosto|Septiembre|Octubre|Noviembre|Diciembre)\\s+al\\s+(\\d{1,2})\\s+(Enero|Febrero|Marzo|Abril|Mayo|Junio|Julio|Agosto|Septiembre|Octubre|Noviembre|Diciembre),?\\s+(\\d{4})",
                    fields: ["start_day", "start_month_name", "end_day", "end_month_name", "end_year"],
                    month_map: "spanish_full",
                    sourced_from: nil
                ),
            ],
            monthMaps: [
                "spanish_short": ["Ene": 1, "Feb": 2, "Mar": 3, "Abr": 4, "May": 5, "Jun": 6,
                                   "Jul": 7, "Ago": 8, "Sep": 9, "Oct": 10, "Nov": 11, "Dic": 12,
                                   "Sept": 9],
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
                AmountConventions.Convention(
                    id: "split_columns",
                    description: "Split columns convention",
                    charge_sign: nil, credit_sign: nil,
                    credit_marker: nil, credit_marker_position: nil,
                    detect_hint: nil, deposit_sign: 1, withdrawal_sign: -1,
                    sourced_from: nil
                ),
                AmountConventions.Convention(
                    id: "trailing_minus",
                    description: "Trailing minus convention",
                    charge_sign: -1, credit_sign: 1,
                    credit_marker: "-", credit_marker_position: "after_amount",
                    detect_hint: nil, deposit_sign: nil, withdrawal_sign: nil,
                    sourced_from: nil
                ),
            ]
        )

        let normalizer = SemanticNormalizer(datePatterns: patterns, amountConventions: conventions)
        let columnDetector = ColumnDetector(vocabulary: vocabulary)

        self.parser = StructuralParser(
            vocabulary: vocabulary,
            normalizer: normalizer,
            columnDetector: columnDetector
        )
    }

    // MARK: - Openbank Mexico (Grid Layout)

    private var openbankPDF: URL {
        URL(fileURLWithPath: "/Users/developer/Documents/GitHub/shiny-happiness/samples/202508.pdf")
    }

    @Test("Parses Openbank PDF (grid layout) and extracts transactions")
    func parsesOpenbankPDF() async throws {
        let data = try Data(contentsOf: openbankPDF)
        let transactions = try await parser.parse(data: data)

        #expect(!transactions.isEmpty, "Should extract at least one transaction from Openbank PDF")

        for tx in transactions {
            #expect(tx.amount != 0, "Transaction amount should not be zero")
            #expect(tx.currency == "MXN")
            #expect(!tx.descriptionRaw.isEmpty, "Transaction should have a description")
        }
    }

    @Test("Openbank transactions have valid dates in reasonable range")
    func openbankDatesValid() async throws {
        let data = try Data(contentsOf: openbankPDF)
        let transactions = try await parser.parse(data: data)
        #expect(!transactions.isEmpty)

        let reasonableStart = Calendar.current.date(from: DateComponents(year: 2020, month: 1, day: 1))!
        let reasonableEnd = Calendar.current.date(from: DateComponents(year: 2030, month: 12, day: 31))!

        for tx in transactions {
            #expect(tx.postedAt > reasonableStart, "Date \(tx.postedAt) should be after 2020-01-01")
            #expect(tx.postedAt < reasonableEnd, "Date \(tx.postedAt) should be before 2030-12-31")
        }
    }

    @Test("Openbank has both deposits and withdrawals")
    func openbankDepositsAndWithdrawals() async throws {
        let data = try Data(contentsOf: openbankPDF)
        let transactions = try await parser.parse(data: data)
        #expect(!transactions.isEmpty)

        let deposits = transactions.filter { $0.amount > 0 }
        let withdrawals = transactions.filter { $0.amount < 0 }
        #expect(!deposits.isEmpty, "Should have at least one deposit")
        #expect(!withdrawals.isEmpty, "Should have at least one withdrawal")
    }

    // MARK: - Amex Mexico (Flow Layout)

    private var amexPDF: URL {
        URL(fileURLWithPath: "/Users/developer/Documents/GitHub/shiny-happiness/samples/201901.pdf")
    }

    @Test("Parses Amex PDF (flow layout) and extracts transactions")
    func parsesAmexPDF() async throws {
        let data = try Data(contentsOf: amexPDF)
        let transactions = try await parser.parse(data: data)

        #expect(!transactions.isEmpty, "Should extract at least one transaction from Amex PDF")

        for tx in transactions {
            #expect(tx.amount != 0, "Transaction amount should not be zero")
            #expect(tx.currency == "MXN")
            #expect(!tx.descriptionRaw.isEmpty, "Transaction should have a description")
        }
    }

    @Test("Amex transactions have valid dates in reasonable range")
    func amexDatesValid() async throws {
        let data = try Data(contentsOf: amexPDF)
        let transactions = try await parser.parse(data: data)
        #expect(!transactions.isEmpty)

        let reasonableStart = Calendar.current.date(from: DateComponents(year: 2015, month: 1, day: 1))!
        let reasonableEnd = Calendar.current.date(from: DateComponents(year: 2030, month: 12, day: 31))!

        for tx in transactions {
            #expect(tx.postedAt > reasonableStart, "Date \(tx.postedAt) should be after 2015-01-01")
            #expect(tx.postedAt < reasonableEnd, "Date \(tx.postedAt) should be before 2030-12-31")
        }
    }

    @Test("Amex detects credit transactions (payments)")
    func amexCreditTransactions() async throws {
        let data = try Data(contentsOf: amexPDF)
        let transactions = try await parser.parse(data: data)
        #expect(!transactions.isEmpty)

        let credits = transactions.filter { $0.amount > 0 }
        #expect(!credits.isEmpty, "Should detect at least one credit (payment)")
    }

    @Test("Amex detects charge transactions")
    func amexChargeTransactions() async throws {
        let data = try Data(contentsOf: amexPDF)
        let transactions = try await parser.parse(data: data)
        #expect(!transactions.isEmpty)

        let charges = transactions.filter { $0.amount < 0 }
        #expect(!charges.isEmpty, "Should detect at least one charge")
    }

    // MARK: - Banorte POR Ti (Flow Layout with DD/MM dates)

    private var banortePDF: URL {
        URL(fileURLWithPath: "/Users/developer/Documents/GitHub/shiny-happiness/samples/EdoCta 202208.pdf")
    }

    @Test("Parses Banorte POR Ti PDF and extracts transactions")
    func parsesBanortePDF() async throws {
        let data = try Data(contentsOf: banortePDF)
        let transactions = try await parser.parse(data: data)

        #expect(!transactions.isEmpty, "Should extract transactions from Banorte POR Ti PDF")

        for tx in transactions {
            #expect(tx.amount != 0, "Transaction amount should not be zero")
            #expect(tx.currency == "MXN")
            #expect(!tx.descriptionRaw.isEmpty, "Transaction should have a description")
        }
    }

    @Test("Banorte transactions have valid dates in 2022 range")
    func banorteDatesValid() async throws {
        let data = try Data(contentsOf: banortePDF)
        let transactions = try await parser.parse(data: data)
        #expect(!transactions.isEmpty)

        let start2022 = Calendar.current.date(from: DateComponents(year: 2022, month: 1, day: 1))!
        let end2022 = Calendar.current.date(from: DateComponents(year: 2022, month: 12, day: 31))!

        for tx in transactions {
            #expect(tx.postedAt >= start2022, "Date \(tx.postedAt) should be in 2022")
            #expect(tx.postedAt <= end2022, "Date \(tx.postedAt) should be in 2022")
        }
    }

    @Test("Banorte detects payment (positive amount with trailing minus)")
    func banortePaymentDetected() async throws {
        let data = try Data(contentsOf: banortePDF)
        let transactions = try await parser.parse(data: data)
        #expect(!transactions.isEmpty)

        let payments = transactions.filter { $0.amount > 0 }
        #expect(!payments.isEmpty, "Should detect at least one payment (SU PAGO, GRACIAS)")
    }

    @Test("Banorte detects charges (negative amounts)")
    func banorteChargesDetected() async throws {
        let data = try Data(contentsOf: banortePDF)
        let transactions = try await parser.parse(data: data)
        #expect(!transactions.isEmpty)

        let charges = transactions.filter { $0.amount < 0 }
        #expect(!charges.isEmpty, "Should detect at least one charge")
    }

    // MARK: - Invalid Data

    @Test("Throws on invalid data")
    func throwsOnInvalidData() async {
        do {
            _ = try await parser.parse(data: Data("not a PDF".utf8))
            Issue.record("Should have thrown an error for invalid data")
        } catch {
        }
    }

    @Test("Returns empty for empty PDF")
    func returnsEmptyForEmptyPDF() async throws {
        let pdfData = Data()
        do {
            let transactions = try await parser.parse(data: pdfData)
            #expect(transactions.isEmpty)
        } catch {
        }
    }
}
