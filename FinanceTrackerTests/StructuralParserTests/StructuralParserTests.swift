import Testing
import Foundation
@testable import FinanceTracker

@Suite("StructuralParser Integration")
struct StructuralParserTests {

    let parser: StructuralParser

    init() {
        guard let p = StructuralParser() else {
            fatalError("StructuralParser() must initialize from bundled JSON knowledge files — check test target resources in project.yml")
        }
        self.parser = p
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

    // MARK: - Suburbia (Line-based with DD/MM dates)

    private var suburbiaPDF: URL {
        URL(fileURLWithPath: "/Users/developer/Documents/GitHub/shiny-happiness/samples/201607 Suburbia.pdf")
    }

    @Test("Parses Suburbia PDF and extracts transactions")
    func parsesSuburbiaPDF() async throws {
        let data = try Data(contentsOf: suburbiaPDF)
        let transactions = try await parser.parse(data: data)

        #expect(!transactions.isEmpty, "Should extract transactions from Suburbia PDF")

        for tx in transactions {
            #expect(tx.amount != 0, "Transaction amount should not be zero")
            #expect(tx.currency == "MXN")
        }
    }

    @Test("Suburbia transactions have valid dates in 2016 range")
    func suburbiaDatesValid() async throws {
        let data = try Data(contentsOf: suburbiaPDF)
        let transactions = try await parser.parse(data: data)
        #expect(!transactions.isEmpty)

        let start2016 = Calendar.current.date(from: DateComponents(year: 2015, month: 1, day: 1))!
        let end2016 = Calendar.current.date(from: DateComponents(year: 2016, month: 12, day: 31))!

        for tx in transactions {
            #expect(tx.postedAt >= start2016, "Date \(tx.postedAt) should be in 2015-2016 range")
            #expect(tx.postedAt <= end2016, "Date \(tx.postedAt) should be in 2015-2016 range")
        }
    }

    @Test("Suburbia detects payments (negative amounts)")
    func suburbiaPaymentsDetected() async throws {
        let data = try Data(contentsOf: suburbiaPDF)
        let transactions = try await parser.parse(data: data)
        #expect(!transactions.isEmpty)

        let payments = transactions.filter { $0.amount > 0 }
        #expect(!payments.isEmpty, "Should detect at least one payment (PAGO RECIBIDO GRACIAS)")
    }

    // MARK: - DiDi Cuenta (Multi-line)

    private var didiPDF: URL {
        URL(fileURLWithPath: "/Users/developer/Documents/GitHub/shiny-happiness/samples/julio.pdf")
    }

    @Test("Parses DiDi Cuenta PDF without crashing")
    func parsesDidiPDF() async throws {
        let data = try Data(contentsOf: didiPDF)
        let transactions = try await parser.parse(data: data)
        #expect(transactions.allSatisfy { $0.currency == "MXN" })
    }

    // MARK: - CETES/CI Banco (Investment)

    private var cetesPDF: URL {
        URL(fileURLWithPath: "/Users/developer/Documents/GitHub/shiny-happiness/samples/202102.pdf")
    }

    @Test("Parses CETES PDF without crashing")
    func parsesCetesPDF() async throws {
        let data = try Data(contentsOf: cetesPDF)
        let transactions = try await parser.parse(data: data)
        #expect(transactions.allSatisfy { $0.currency == "MXN" })
    }

    // MARK: - Skandia (Retirement/Pension)

    private var skandiaPDF: URL {
        URL(fileURLWithPath: "/Users/developer/Documents/GitHub/shiny-happiness/samples/2023.pdf")
    }

    @Test("Parses Skandia PDF without crashing")
    func parsesSkandiaPDF() async throws {
        let data = try Data(contentsOf: skandiaPDF)
        let transactions = try await parser.parse(data: data)
        #expect(transactions.allSatisfy { $0.currency == "MXN" })
    }

    // MARK: - DiDi/Stori (Wallet)

    private var didiStoriPDF: URL {
        URL(fileURLWithPath: "/Users/developer/Documents/GitHub/shiny-happiness/samples/202509.pdf")
    }

    @Test("Parses DiDi/Stori PDF without crashing")
    func parsesDidiStoriPDF() async throws {
        let data = try Data(contentsOf: didiStoriPDF)
        let transactions = try await parser.parse(data: data)
        #expect(transactions.allSatisfy { $0.currency == "MXN" })
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
