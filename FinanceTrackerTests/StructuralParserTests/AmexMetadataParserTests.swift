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

    private func extractMetadata(from text: String) -> ParsedSection? {
        let sections = parser.parseSectionsFromText(text)
        return sections.first
    }

    private func dateComponents(_ date: Date?) -> DateComponents {
        Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date ?? .distantPast)
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

        #expect(meta?.paymentDueDate != nil, "Should parse due date from exact-colon format")
        if let due = meta?.paymentDueDate {
            let comps = dateComponents(due)
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

        #expect(meta?.paymentDueDate != nil, "Should parse date with second 'de'")
        if let due = meta?.paymentDueDate {
            let comps = dateComponents(due)
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

        #expect(meta?.minimumPayment == 3600.00,
                "Expected 3600.00, got \(meta?.minimumPayment?.description ?? "nil")")
    }

    @Test("Exact-colon Pago Mínimo does not collide with Pago mínimo mas meses sin intereses")
    func noCollisionWithInstallmentsMinimum() {
        let text = """
        American Express
        Pago Mínimo: $ 3,600.00
        Pago mínimo mas meses sin intereses $ 5,200.00
        """
        let meta = extractMetadata(from: text)

        #expect(meta?.minimumPayment == 3600.00,
                "Should use exact-colon match, not the installments line. Got \(meta?.minimumPayment?.description ?? "nil")")
    }

    @Test("Falls back to near-label when no colon format present")
    func fallsBackToNearLabel() {
        let text = """
        American Express
        Fecha Límite de Pago 08-May-2026
        """
        let meta = extractMetadata(from: text)

        #expect(meta?.paymentDueDate != nil, "Should fall back to near-label date parsing")
        if let due = meta?.paymentDueDate {
            let comps = dateComponents(due)
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

        #expect(meta?.paymentDueDate != nil)
        #expect(meta?.minimumPayment == 3600.00)
        #expect(meta?.paymentForNoInterest == 45054.70)
    }

    @Test("Amex summary row maps arithmetic and credit values")
    func summaryRowMapsArithmeticAndCreditValues() {
        let text = """
        American Express
        Saldo Anterior
        Pagos y
        Créditos
        Nuevos
        Cargos
        Saldo Actual /
        Pago para no
        generar intereses
        Pago
        Mínimo
        6,195.33 - 32,338.41 + 39,946.03 = 13,802.95 3,600.00
        Resumen de Crédito Límite de Crédito Límite Disponible
        a Mayo 11,2026 288,000.00 MN 254,003.13 MN
        """
        let meta = extractMetadata(from: text)

        #expect(meta?.creditLimit == 288000.00)
        #expect(meta?.closingBalance == -33996.87)
        #expect(meta?.paymentForNoInterest == 13802.95)
        #expect(meta?.minimumPayment == 3600.00)
    }

    @Test("Parses label date without year by inferring statement year")
    func parsesColonDateWithoutYear() {
        let text = """
        American Express
        Período de Facturación Del 12 de Abril al 11 de Mayo de 2026 Días del periodo: 30 días
        Fecha límite de pago: 1 de Junio
        """
        let meta = extractMetadata(from: text)
        let comps = dateComponents(meta?.paymentDueDate)

        #expect(comps.year == 2026)
        #expect(comps.month == 6)
        #expect(comps.day == 1)
    }

    @Test("Non-Amex text returns nil metadata")
    func nonAmexTextReturnsNil() {
        let text = """
        HSBC 2Now
        Fecha de corte: 08/05/2026
        """
        let meta = extractMetadata(from: text)

        #expect(meta?.paymentDueDate == nil)
        #expect(meta?.minimumPayment == nil)
    }

    @Test("Parses May 2026 Gold Elite PDF metadata")
    func parsesMayGoldElitePDFMetadata() async throws {
        guard let url = FixtureLoader.optionalURL("12_abr_2026_-_11_may_2026.pdf") else { return }

        let sections = try await parser.parseSections(data: Data(contentsOf: url))
        let section = try #require(sections.first)
        let due = dateComponents(section.paymentDueDate)

        #expect(section.accountNumber == "5375257001")
        #expect(section.creditLimit == 288000.00)
        #expect(section.closingBalance == -33996.87)
        #expect(section.paymentForNoInterest == 13802.95)
        #expect(section.minimumPayment == 3600.00)
        #expect(due.year == 2026 && due.month == 6 && due.day == 1)
        #expect(section.transactions.contains {
            $0.descriptionRaw.localizedCaseInsensitiveContains("GRACIAS POR SU PAGO EN LINEA") && $0.amount == 6195.33
        })
    }

    @Test("Parses March 2026 Gold Elite PDF metadata")
    func parsesMarchGoldElitePDFMetadata() async throws {
        guard let url = FixtureLoader.optionalURL("202603.pdf") else { return }

        let sections = try await parser.parseSections(data: Data(contentsOf: url))
        let section = try #require(sections.first)
        let due = dateComponents(section.paymentDueDate)

        #expect(section.creditLimit == 288000.00)
        #expect(section.closingBalance == -3876.05)
        #expect(section.paymentForNoInterest == 3876.05)
        #expect(section.minimumPayment == 3600.00)
        #expect(due.year == 2026 && due.month == 3 && due.day == 31)
    }
}
