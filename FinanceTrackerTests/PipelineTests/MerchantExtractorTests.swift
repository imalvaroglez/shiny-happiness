import Testing
import Foundation
@testable import FinanceTracker

@Suite("MerchantExtractor")
struct MerchantExtractorTests {

    @Test("Extracts merchant from CINEPOLIS with numbers")
    func testCinepolis() {
        #expect(MerchantExtractor.extractMerchant(from: "CINEPOLIS0677 000000000 DF") == "CINEPOLIS")
    }

    @Test("Strips RFC pattern")
    func testStripsRFC() {
        #expect(MerchantExtractor.extractMerchant(from: "DIDICHUXING MEXICO RFCAME1405134M6") == "DIDICHUXING")
    }

    @Test("Extracts UBER from compound name")
    func testUber() {
        #expect(MerchantExtractor.extractMerchant(from: "UBER TRIP HELP.UBER.COM") == "UBER")
    }

    @Test("Extracts ITUNES from URL-like description")
    func testItunes() {
        #expect(MerchantExtractor.extractMerchant(from: "ITUNES.COM/BILL CUPERTINO") == "ITUNES")
    }

    @Test("Returns nil for short descriptions")
    func testShortReturnsNil() {
        #expect(MerchantExtractor.extractMerchant(from: "AB") == nil)
    }

    @Test("Returns nil for all-numeric descriptions")
    func testNumericReturnsNil() {
        #expect(MerchantExtractor.extractMerchant(from: "12345 67890") == nil)
    }

    @Test("Extracts from PAGO RECIBIDO")
    func testPagoRecibido() {
        #expect(MerchantExtractor.extractMerchant(from: "PAGO RECIBIDO, GRACIAS") == "PAGO")
    }

    @Test("Strips /REF patterns")
    func testStripsRef() {
        #expect(MerchantExtractor.extractMerchant(from: "STARBUCKS /REF12345 MX") == "STARBUCKS")
    }

    @Test("Handles MERCADO LIBRE compound name")
    func testMercadoLibre() {
        #expect(MerchantExtractor.extractMerchant(from: "MERCADO LIBRE ENVIO 12345") == "MERCADO")
    }
}
