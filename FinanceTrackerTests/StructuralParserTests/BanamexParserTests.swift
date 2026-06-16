import Testing
import Foundation
@testable import FinanceTracker

@Suite("Banamex Statement Parser")
struct BanamexParserTests {
    let parser: StructuralParser

    init() {
        guard let parser = StructuralParser() else {
            fatalError("StructuralParser() must initialize from bundled JSON knowledge files")
        }
        self.parser = parser
    }

    private var priorityPDF: URL? {
        FixtureLoader.optionalURL("202603.pdf")
    }

    private var exploraPDF: URL? {
        FixtureLoader.optionalURL("04.pdf")
    }

    @Test("Detects Banamex Priority checking statement")
    func detectsBanamexPriority() throws {
        guard let priorityPDF else { return }
        let data = try Data(contentsOf: priorityPDF)
        let detection = Detector.detect(data: data, fileExtension: "pdf")

        #expect(detection.issuer == .banamexPriority)
        #expect(detection.suggestedAccountType == .checking)
    }

    @Test("Parses Banamex Priority movements and balances")
    func parsesBanamexPriority() async throws {
        guard let priorityPDF else { return }
        let data = try Data(contentsOf: priorityPDF)
        let sections = try await parser.parseSections(data: data)

        #expect(sections.count == 1)
        let section = try #require(sections.first)
        #expect(section.accountType == .checking)
        #expect(section.nickname == "Banamex Priority")
        #expect(section.closingBalance == 3_876.05)
        #expect(section.transactions.count >= 20)

        let amexPayment = section.transactions.first {
            $0.descriptionRaw.localizedCaseInsensitiveContains("AMERICAN EXPRESS")
        }
        #expect(amexPayment?.amount == Decimal(string: "-5214.53"))
    }

    @Test("Detects Banamex Explora credit-card statement")
    func detectsBanamexExplora() throws {
        guard let exploraPDF else { return }
        let data = try Data(contentsOf: exploraPDF)
        let detection = Detector.detect(data: data, fileExtension: "pdf")

        #expect(detection.issuer == .banamexExplora)
        #expect(detection.suggestedAccountType == .creditCard)
    }

    @Test("Parses Banamex Explora statement metadata and transactions")
    func parsesBanamexExplora() async throws {
        guard let exploraPDF else { return }
        let data = try Data(contentsOf: exploraPDF)
        let sections = try await parser.parseSections(data: data)

        #expect(sections.count == 1)
        let section = try #require(sections.first)
        #expect(section.accountType == .creditCard)
        #expect(section.nickname == "Banamex Explora")
        #expect(section.closingBalance == Decimal(string: "-9799.37"))
        #expect(section.creditLimit == Decimal(619_000))
        #expect(section.minimumPayment == Decimal(7_740))
        #expect(section.paymentForNoInterest == Decimal(string: "9799.37"))
        #expect(section.transactions.count >= 6)

        let payment = section.transactions.first {
            $0.descriptionRaw.localizedCaseInsensitiveContains("PAGO INTERBANCARIO")
        }
        #expect(payment?.amount == Decimal(string: "1080.54"))
        #expect(payment?.cardLast4 == "5390")

        let claude = section.transactions.first {
            $0.descriptionRaw.localizedCaseInsensitiveContains("CLAUDE.AI")
        }
        #expect(claude?.amount == Decimal(string: "-348.67"))
        #expect(claude?.cardLast4 == "6311")

        let calendar = Calendar(identifier: .gregorian)
        let due = try #require(section.paymentDueDate)
        #expect(calendar.component(.year, from: due) == 2026)
        #expect(calendar.component(.month, from: due) == 5)
        #expect(calendar.component(.day, from: due) == 8)
    }
}
