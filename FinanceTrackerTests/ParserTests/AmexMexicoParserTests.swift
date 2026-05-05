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

    var sampleDataURL: URL {
        URL(fileURLWithPath: "/Users/developer/Documents/GitHub/shiny-happiness/samples/201901.pdf")
    }

    @Test("Detects Amex from PDF data")
    func detectsAmex() async throws {
        let data = try Data(contentsOf: sampleDataURL)
        let result = Detector.detect(data: data, fileExtension: "pdf")
        #expect(result.issuer == .amexMexico)
        #expect(result.confidence > 0.9)
        #expect(result.suggestedAccountType == .creditCard)
    }

    @Test("Parses Amex PDF without crashing (encrypted/restricted PDFs handled)")
    func parsesWithoutCrashing() async throws {
        let data = try Data(contentsOf: sampleDataURL)
        let transactions = try await parser.parse(data: data, account: sampleAccount)
        for tx in transactions {
            #expect(tx.currency == "MXN")
            #expect(!tx.descriptionRaw.isEmpty)
        }
    }

    @Test("Parser supports correct issuers and formats")
    func supportedFormats() {
        #expect(AmexMexicoParser.supportedIssuers.contains("American Express Mexico"))
        #expect(AmexMexicoParser.supportedFormats.contains(.pdf))
    }

    @Test("StatementParser protocol conformance - two different parsers work")
    func protocolConformance() {
        #expect(OpenbankMexicoParser.supportedIssuers != AmexMexicoParser.supportedIssuers)
        #expect(!OpenbankMexicoParser.supportedIssuers.isEmpty)
        #expect(!AmexMexicoParser.supportedIssuers.isEmpty)
    }
}
