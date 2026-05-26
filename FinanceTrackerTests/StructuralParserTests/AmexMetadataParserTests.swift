import Testing
import Foundation
@testable import FinanceTracker

@Suite("Amex Metadata Parser")
struct AmexMetadataParserTests {

    let parser: StructuralParser

    init() {
        guard let p = StructuralParser() else {
            fatalError("StructuralParser() must initialize from bundled JSON knowledge files")
        }
        self.parser = p
    }

    private func extractMetadata(from text: String) -> (minimumPayment: Decimal?, noInterest: Decimal?, dueDate: Date?) {
        let sections = parser.parseSectionsFromText(text)
        let section = sections.first
        return (section?.minimumPayment, section?.paymentForNoInterest, section?.paymentDueDate)
    }

    @Test("Parses exact-colon date: Fecha límite de pago: 31 de Marzo 2026")
    func parsesExactColonDateWithoutSecondDe() {
        let text = """
        American Express
        Resumen de Cuenta
        Fecha límite de pago: 31 de Marzo 2026
        Pago Mínimo: $ 3,600.00
        Pago para no generar intereses: $ 45,000.00
        """
        let meta = extractMetadata(from: text)

        #expect(meta.dueDate != nil, "Should parse due date from exact-colon format")
        if let due = meta.dueDate {
            let comps = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: due)
            #expect(comps.year == 2026 && comps.month == 3 && comps.day == 31,
                    "Expected 2026-03-31, got \(comps.year ?? 0)-\(comps.month ?? 0)-\(comps.day ?? 0)")
        }
    }

    @Test("Parses exact-colon date with second de: 31 de Marzo de 2026")
    func parsesExactColonDateWithSecondDe() {
        let text = """
        American Express
        Fecha límite de pago: 31 de Marzo de 2026
        """
        let meta = extractMetadata(from: text)

        #expect(meta.dueDate != nil, "Should parse date with second 'de'")
        if let due = meta.dueDate {
            let comps = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: due)
            #expect(comps.year == 2026 && comps.month == 3 && comps.day == 31)
        }
    }

    @Test("Parses exact-colon minimum payment: Pago Mínimo: $ 3,600.00")
    func parsesExactColonMinimumPayment() {
        let text = """
        American Express
        Pago Mínimo: $ 3,600.00
        """
        let meta = extractMetadata(from: text)

        #expect(meta.minimumPayment == 3600.00,
                "Expected 3600.00, got \(meta.minimumPayment?.description ?? "nil")")
    }

    @Test("Exact-colon Pago Mínimo does not collide with Pago mínimo mas meses sin intereses")
    func noCollisionWithInstallmentsMinimum() {
        let text = """
        American Express
        Pago Mínimo: $ 3,600.00
        Pago mínimo mas meses sin intereses $ 5,200.00
        """
        let meta = extractMetadata(from: text)

        #expect(meta.minimumPayment == 3600.00,
                "Should use exact-colon match, not the installments line. Got \(meta.minimumPayment?.description ?? "nil")")
    }

    @Test("Falls back to near-label when no colon format present")
    func fallsBackToNearLabel() {
        let text = """
        American Express
        Fecha Límite de Pago 08-May-2026
        """
        let meta = extractMetadata(from: text)

        #expect(meta.dueDate != nil, "Should fall back to near-label date parsing")
        if let due = meta.dueDate {
            let comps = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: due)
            #expect(comps.year == 2026 && comps.month == 5 && comps.day == 8)
        }
    }

    @Test("Full Amex metadata from Gold-style text")
    func fullGoldStyleMetadata() {
        let text = """
        American Express
        Tarjeta titular: ••••••••••••xxxx1234
        Fecha límite de pago: 31 de Marzo 2026
        Pago Mínimo: $ 3,600.00
        Pago para no generar intereses: $ 45,054.70
        """
        let meta = extractMetadata(from: text)

        #expect(meta.dueDate != nil)
        #expect(meta.minimumPayment == 3600.00)
        #expect(meta.noInterest == 45054.70)
    }

    @Test("Non-Amex text returns nil metadata")
    func nonAmexTextReturnsNil() {
        let text = """
        HSBC 2Now
        Fecha de corte: 08/05/2026
        """
        let meta = extractMetadata(from: text)

        #expect(meta.dueDate == nil)
        #expect(meta.minimumPayment == nil)
    }
}
