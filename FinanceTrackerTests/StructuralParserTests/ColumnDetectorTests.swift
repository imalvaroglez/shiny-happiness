import Testing
import Foundation
@testable import FinanceTracker

@Suite("ColumnDetector")
struct ColumnDetectorTests {

    let detector: ColumnDetector

    init() {
        self.detector = ColumnDetector(vocabulary: HeaderVocabulary(
            from: [
                "date_column": ["Fecha", "Date"],
                "description_column": ["Detalle", "Concepto"],
                "amount_column": ["Importe", "Monto"],
                "debit_column": ["Retiro", "Cargo"],
                "credit_column": ["Depósito", "Abono"],
                "balance_column": ["Saldo"],
                "combined_headers": [
                    "Fecha y Detalle de las operaciones": ["date_column", "description_column"],
                    "Importe en MN": ["amount_column"]
                ],
                "section_start_markers": [
                    "Fecha y Detalle de las operaciones",
                    "Detalle de Transacciones"
                ],
                "section_end_markers": [
                    "Total de las transacciones",
                    "Número de Cuenta"
                ]
            ]
        ))
    }

    private func makeBlock(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat = 100) -> TextBlock {
        TextBlock(text: text, bounds: CGRect(x: x, y: y, width: width, height: 12))
    }

    private func makeRow(_ cells: [TextBlock], y: CGFloat) -> TableRow {
        TableRow(y: y, cells: cells)
    }

    @Test("Detects grid table with separate columns")
    func detectsGridTable() {
        let rows = [
            makeRow([
                makeBlock("Fecha", x: 50, y: 700),
                makeBlock("Concepto", x: 200, y: 700),
                makeBlock("Depósito", x: 400, y: 700),
                makeBlock("Retiro", x: 500, y: 700),
                makeBlock("Saldo", x: 600, y: 700),
            ], y: 700),
            makeRow([
                makeBlock("15/08/25", x: 50, y: 680),
                makeBlock("OXXO STORE", x: 200, y: 680),
                makeBlock("", x: 400, y: 680),
                makeBlock("115.00", x: 500, y: 680),
                makeBlock("24,885.00", x: 600, y: 680),
            ], y: 680),
        ]

        let table = detector.detectTable(in: rows)
        #expect(table != nil)
        #expect(table?.layout == .grid)
        #expect(table?.columns.count ?? 0 >= 3)
        #expect(table?.amountConvention == "split_columns")
    }

    @Test("Detects flow table with combined header (Amex style)")
    func detectsFlowTable() {
        let rows = [
            makeRow([
                makeBlock("Fecha y Detalle de las operaciones", x: 50, y: 700),
                makeBlock("Importe en MN", x: 450, y: 700),
            ], y: 700),
            makeRow([
                makeBlock("12 de", x: 50, y: 680),
            ], y: 680),
            makeRow([
                makeBlock("Diciembre", x: 50, y: 668),
            ], y: 668),
            makeRow([
                makeBlock("PAGO RECIBIDO, GRACIAS", x: 50, y: 656),
                makeBlock("5,429.12", x: 450, y: 656),
            ], y: 656),
            makeRow([
                makeBlock("CR", x: 450, y: 644),
            ], y: 644),
            makeRow([
                makeBlock("Total de las transacciones", x: 50, y: 600),
            ], y: 600),
        ]

        let table = detector.detectTable(in: rows)
        #expect(table != nil)
        #expect(table?.layout == .flow)
        #expect(table?.amountConvention == "cr_suffix")
        #expect(table?.dataRowRange.count == 4)
    }

    @Test("Returns nil when no table headers found")
    func returnsNilForNoTable() {
        let rows = [
            makeRow([makeBlock("Random text", x: 50, y: 700)], y: 700),
            makeRow([makeBlock("More text", x: 50, y: 680)], y: 680),
        ]

        let table = detector.detectTable(in: rows)
        #expect(table == nil)
    }

    @Test("Assigns cell roles based on column proximity")
    func assignsCellRoles() {
        let columns = [
            DetectedColumn(role: .date, xCenter: 100, xRange: 50...150, headerText: "Fecha"),
            DetectedColumn(role: .description, xCenter: 250, xRange: 150...350, headerText: "Concepto"),
            DetectedColumn(role: .amount, xCenter: 450, xRange: 400...500, headerText: "Importe"),
        ]

        let row = makeRow([
            makeBlock("15/08/25", x: 80, y: 600),
            makeBlock("OXXO", x: 200, y: 600),
            makeBlock("115.00", x: 440, y: 600),
        ], y: 600)

        let assignments = detector.assignCellRoles(in: row, columns: columns)
        #expect(assignments.count == 3)
        #expect(assignments[0].role == .date)
        #expect(assignments[1].role == .description)
        #expect(assignments[2].role == .amount)
    }

    @Test("Detects section end markers")
    func detectsSectionEnd() {
        let rows = [
            makeRow([makeBlock("Fecha y Detalle de las operaciones", x: 50, y: 700)], y: 700),
            makeRow([makeBlock("Some data", x: 50, y: 680)], y: 680),
            makeRow([makeBlock("Total de las transacciones", x: 50, y: 660)], y: 660),
            makeRow([makeBlock("Other content", x: 50, y: 640)], y: 640),
        ]

        let table = detector.detectTable(in: rows)
        #expect(table != nil)
        #expect(table?.dataRowRange.count == 1)
    }
}
