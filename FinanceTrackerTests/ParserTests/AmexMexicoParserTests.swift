import Testing
import Foundation
@testable import FinanceTracker

@Suite("Amex Mexico Parser")
struct AmexMexicoParserTests {

    var parser: AmexMexicoParser {
        AmexMexicoParser()
    }

    var sampleAccount: Account {
        Account(institution: "American Express Mexico", type: .creditCard, currency: "MXN")
    }

    var sampleDataURL: URL? {
        FixtureLoader.optionalURL("201901.pdf")
    }

    @Test("Detects Amex from PDF data")
    func detectsAmex() async throws {
        // SKIPPED: fixture PDF not in samples/
        guard let sampleDataURL else { return }
        let data = try Data(contentsOf: sampleDataURL)
        let result = Detector.detect(data: data, fileExtension: "pdf")
        #expect(result.issuer == .amexMexico)
        #expect(result.suggestedAccountType == .creditCard)
    }

    @Test("Parses Amex PDF without crashing (encrypted/restricted PDFs handled)")
    func parsesWithoutCrashing() async throws {
        // SKIPPED: fixture PDF not in samples/
        guard let sampleDataURL else { return }
        let data = try Data(contentsOf: sampleDataURL)
        let transactions = try await parser.parse(data: data)
        for tx in transactions {
            #expect(tx.currency == "MXN")
            #expect(!tx.descriptionRaw.isEmpty)
        }
    }
}
