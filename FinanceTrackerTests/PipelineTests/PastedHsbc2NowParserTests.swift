import Testing
import Foundation
@testable import FinanceTracker

@Suite("Pasted HSBC 2Now Parser")
@MainActor
struct PastedHsbc2NowParserTests {

    private var fixture: String {
        get throws {
            let url = FixtureLoader.url("2026-05-08_HSBC_2Now_paste.txt")
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    @Test("Header extracts period, due date, balances, credit limit")
    func parsesHeader() throws {
        let text = try fixture
        let parser = PastedHsbc2NowParser()
        let header = parser.parseHeader(lines: text.components(separatedBy: .newlines))

        #expect(header.paymentForNoInterest == Decimal(string: "30892.20"))
        #expect(header.minimumPayment == Decimal(string: "5812.50"))
        #expect(header.previousBalance == Decimal(string: "25985.49"))
        #expect(header.totalBalance == Decimal(string: "45054.70"))
        #expect(header.creditLimit == Decimal(string: "465000.00"))
        #expect(header.titularCardLast4 == "7827")

        if let due = header.paymentDueDate {
            let cal = Calendar(identifier: .gregorian)
            let c = cal.dateComponents([.year, .month, .day], from: due)
            #expect(c.year == 2026 && c.month == 5 && c.day == 30)
        } else {
            Issue.record("paymentDueDate missing")
        }
    }

    @Test("MSI parser detects HOME DEPOT @ 02 de 12 / $16,995 / $1,416.25")
    func parsesInstallments() throws {
        let text = try fixture
        let parser = PastedHsbc2NowParser()
        let hints = parser.parseInstallments(lines: text.components(separatedBy: .newlines), fallbackYear: 2026)
        let homeDepot = hints.first { $0.merchantDescription.localizedCaseInsensitiveContains("HOME DEPOT") }
        guard let plan = homeDepot else {
            Issue.record("HOME DEPOT MSI hint missing")
            return
        }
        #expect(plan.currentMonth == 2)
        #expect(plan.totalMonths == 12)
        #expect(plan.originalAmount == Decimal(string: "16995.00"))
        #expect(plan.monthlyAmount == Decimal(string: "1416.25"))
    }

    @Test("Both card sections recovered; supplementary tagged 7801")
    func parsesBothCards() throws {
        let text = try fixture
        let parser = PastedHsbc2NowParser()
        let result = parser.parse(text)

        #expect(result.sections.count == 2)
        let titular = result.sections.first { $0.nickname == "HSBC 2Now Oro" }
        let suppl = result.sections.first { $0.nickname == "HSBC 2Now Oro (Adicional)" }
        #expect(titular != nil)
        #expect(suppl != nil)
        #expect((suppl?.transactions.count ?? 0) == 8)
        #expect(titular?.accountNumber == suppl?.accountNumber,
                "Both sections should share the titular's accountNumber")
    }

    @Test("Combined card totals reconcile to documented summary")
    func reconcilesTotals() throws {
        let text = try fixture
        let parser = PastedHsbc2NowParser()
        let result = parser.parse(text)

        // HSBC's documented "Total cargos $29,491.46" / "Total abonos $26,001.00" at the
        // bottom of the statement aggregates BOTH the titular and supplementary cards.
        // Reconcile against the combined totals across both parsed sections.
        _ = result.pendings.count
        let allTxns = result.sections.flatMap(\.transactions)
        let charges = allTxns
            .filter { $0.amount < 0 && $0.installmentHint == nil }
            .reduce(Decimal(0)) { $0 + abs($1.amount) }
        let payments = allTxns
            .filter { $0.amount > 0 }
            .reduce(Decimal(0)) { $0 + $1.amount }

        let expectedCharges = Decimal(string: "29491.46")!
        let chargesDelta = abs(((charges - expectedCharges) as NSDecimalNumber).doubleValue)
        // Allow $1 tolerance for the one OCR-style ".3" truncated tail in the fixture
        // (`+ $104.3` instead of `+ $104.30` on the supplementary card).
        #expect(chargesDelta < 1.0,
                "Charges parsed=\((charges as NSDecimalNumber).doubleValue) expected=\((expectedCharges as NSDecimalNumber).doubleValue) Δ=\(chargesDelta)")

        let expectedPayments = Decimal(string: "26001.00")!
        let paymentsDelta = abs(((payments - expectedPayments) as NSDecimalNumber).doubleValue)
        #expect(paymentsDelta < 1.0,
                "Payments parsed=\((payments as NSDecimalNumber).doubleValue) expected=\((expectedPayments as NSDecimalNumber).doubleValue) Δ=\(paymentsDelta)")
    }

    @Test("SU PAGO GRACIAS row parses as a payment (positive amount in app convention)")
    func suPagoIsPayment() throws {
        let text = try fixture
        let parser = PastedHsbc2NowParser()
        let result = parser.parse(text)
        let su = result.sections
            .flatMap(\.transactions)
            .first { $0.descriptionRaw.localizedCaseInsensitiveContains("SU PAGO GRACIAS") }
        guard let su else {
            Issue.record("SU PAGO row not parsed")
            return
        }
        #expect(su.amount > 0, "Expected positive amount (payment in), got \(su.amount)")
        #expect(su.amount == Decimal(string: "25986.00"))
    }

    @Test("A line missing its amount becomes a PendingImport")
    func pendingImportForBrokenLine() {
        let snippet = """
        c) CARGOS, ABONOS Y COMPRAS REGULARES (NO A MESES)
         Tarjeta titular 5470748031607827
        i. Fecha de la
        operación ii. Fecha de cargo iii. Descripción del movimiento iv. Monto
        09-Abr-2026 10-Abr-2026 SOMETHING THAT LOOKS LIKE A TXN BUT NO AMOUNT
        09-Abr-2026 10-Abr-2026 GOOD ROW + $50.00
        """
        let parser = PastedHsbc2NowParser()
        let result = parser.parse(snippet)
        #expect(result.pendings.count == 1)
        #expect(result.pendings.first?.cardLast4 == "7827")
        #expect(result.sections.first?.transactions.count == 1)
    }
}
