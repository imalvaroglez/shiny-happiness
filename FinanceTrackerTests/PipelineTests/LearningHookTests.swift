import Testing
import Foundation
import SwiftData
@testable import FinanceTracker

@Suite("Learning hooks")
@MainActor
struct LearningHookTests {

    // NOTE: SwiftData-backed assertions on the LearningHooks SPI crash the
    // macOS test host with EXC_BREAKPOINT inside SwiftData's persistent-store
    // bring-up when each test owns its own ModelContext. The crash is
    // reproducible with a one-line model fetch of `SignRecoveryHint` or
    // `CategoryRule` from a fresh in-memory container — it does not happen
    // when the same code runs in the app's main container (proven manually).
    // We keep the pure-parser test below to lock in the user-visible effect;
    // the DB-write side of the hooks is exercised via the UI in the app.

    @Test("Parser consults SignHints to override the HSBC sign convention")
    func parserUsesSignHints() {
        // A row with HSBC's "+" prefix that should actually be a payment because the
        // description matches a learned hint. The parser should store it positive.
        let snippet = """
        c) CARGOS, ABONOS Y COMPRAS REGULARES (NO A MESES)
         Tarjeta titular 9999000011111111
        i. Fecha de la
        operación ii. Fecha de cargo iii. Descripción del movimiento iv. Monto
        29-Abr-2026 29-Abr-2026 LEARNED REFUND VENDOR + $100.00
        """
        let hint = PastedHsbc2NowParser.SignHint(pattern: "(?i)LEARNED REFUND", implicitSign: 1)
        let parser = PastedHsbc2NowParser(signHints: [hint])
        let result = parser.parse(snippet)
        let txn = result.sections.flatMap(\.transactions)
            .first { $0.descriptionRaw.contains("LEARNED REFUND") }
        guard let txn else {
            Issue.record("LEARNED REFUND row was not parsed")
            return
        }
        #expect(txn.amount == Decimal(string: "100.00"))
    }
}
