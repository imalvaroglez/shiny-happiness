import Testing
import Foundation
@testable import FinanceTracker

@Suite("Openbank Mexico Parser")
struct OpenbankMexicoParserTests {

    var parser: OpenbankMexicoParser {
        OpenbankMexicoParser()
    }

    var sampleAccount: Account {
        Account(institution: "Openbank Mexico", type: .checking, currency: "MXN")
    }

    private var sampleDataURL: URL {
        FixtureLoader.url("01.pdf")
    }

    private var fixtureExists: Bool {
        FileManager.default.fileExists(atPath: sampleDataURL.path)
    }

    // SKIPPED: fixture PDF not in samples/ — re-enable when 202508.pdf is restored
    @Test("Detects Openbank from PDF data")
    func detectsOpenbank() async throws {
        guard fixtureExists else { return }
        let data = try Data(contentsOf: sampleDataURL)
        let result = Detector.detect(data: data, fileExtension: "pdf")
        #expect(result.issuer == .openbankMexico)
        #expect(result.format == .pdf)
        #expect(result.confidence > 0.9)
    }

    @Test("Parses Openbank PDF and extracts transactions")
    func parsesOpenbankPDF() async throws {
        guard fixtureExists else { return }
        let data = try Data(contentsOf: sampleDataURL)

        let transactions = try await parser.parse(data: data)

        #expect(!transactions.isEmpty)

        let deposits = transactions.filter { $0.amount > 0 }
        let withdrawals = transactions.filter { $0.amount < 0 }
        #expect(!deposits.isEmpty)
        #expect(!withdrawals.isEmpty)

        for tx in transactions {
            #expect(tx.currency == "MXN")
            #expect(!tx.descriptionRaw.isEmpty)
        }
    }

    @Test("Transaction amounts are Decimal, never zero for non-empty transactions")
    func amountsAreValid() async throws {
        guard fixtureExists else { return }
        let data = try Data(contentsOf: sampleDataURL)

        let transactions = try await parser.parse(data: data)

        for tx in transactions {
            #expect(tx.amount != 0)
        }
    }

    @Test("Dates are valid and within reasonable range")
    func datesAreValid() async throws {
        guard fixtureExists else { return }
        let data = try Data(contentsOf: sampleDataURL)

        let transactions = try await parser.parse(data: data)
        let reasonableStart = Calendar.current.date(from: DateComponents(year: 2020, month: 1, day: 1))!
        let reasonableEnd = Calendar.current.date(from: DateComponents(year: 2030, month: 12, day: 31))!

        for tx in transactions {
            #expect(tx.postedAt > reasonableStart)
            #expect(tx.postedAt < reasonableEnd)
        }
    }

    @Test("Transfer detection works for SPEI transactions")
    func transferDetection() async throws {
        guard fixtureExists else { return }
        let data = try Data(contentsOf: sampleDataURL)

        let transactions = try await parser.parse(data: data)
        let transfers = transactions.filter { $0.isTransfer }

        guard !transfers.isEmpty else {
            return
        }
        for tx in transfers {
            #expect(
                tx.descriptionRaw.contains("Transferencia") ||
                tx.descriptionRaw.contains("Traspaso")
            )
        }
    }

    @Test("Parser supports correct issuers and formats")
    func supportedFormats() {
        #expect(OpenbankMexicoParser.supportedIssuers.contains("Openbank Mexico"))
        #expect(OpenbankMexicoParser.supportedFormats.contains(.pdf))
    }
}
