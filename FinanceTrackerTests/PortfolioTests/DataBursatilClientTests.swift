import Testing
import Foundation
@testable import FinanceTracker

@Suite("DataBursatil Client")
struct DataBursatilClientTests {
    private struct FakeTransport: HTTPRequesting {
        let body: Data
        let status: Int
        var expectedTickers: String?

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            if let expectedTickers {
                let actual = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first { $0.name == "emisora_serie" }?
                    .value
                #expect(actual == expectedTickers)
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
            )!
            return (body, response)
        }
    }

    private func json(_ string: String) -> Data {
        Data(string.utf8)
    }

    @Test("Decodes BMV price to Decimal")
    func decodesBMV() async throws {
        let body = json(#"{"FEMSAUBD":{"bmv":{"u":19.86,"f":"2026-06-25 15:30:00"}}}"#)
        let client = DataBursatilClient(token: "t", transport: FakeTransport(body: body, status: 200))
        let quotes = try await client.quotes(for: ["FEMSAUBD"])
        #expect(quotes["FEMSAUBD"]?.price == 19.86)
        #expect(quotes["FEMSAUBD"]?.timestamp != nil)
    }

    @Test("Falls back to BIVA when BMV absent")
    func bivaFallback() async throws {
        let body = json(#"{"FEMSAUBD":{"BIVA":{"u":19.85,"f":"2026-06-25 15:30:00"}}}"#)
        let client = DataBursatilClient(token: "t", transport: FakeTransport(body: body, status: 200))
        let quotes = try await client.quotes(for: ["FEMSAUBD"])
        #expect(quotes["FEMSAUBD"]?.price == 19.85)
    }

    @Test("Request normalizes spaced BMV series")
    func requestNormalizesSpacedBMVSeries() async throws {
        let body = json(#"{"AMXB":{"BMV":{"u":15.00}},"CEMEXCPO":{"BMV":{"u":20.00}},"GFNORTEO":{"BMV":{"u":30.00}}}"#)
        let transport = FakeTransport(body: body, status: 200, expectedTickers: "AMXB,CEMEXCPO,GFNORTEO")
        let client = DataBursatilClient(token: "t", transport: transport)
        let quotes = try await client.quotes(for: ["AMX B", "CEMEX CPO", "GFNORTE O"])

        #expect(quotes["AMXB"]?.price == 15)
        #expect(quotes["CEMEXCPO"]?.price == 20)
        #expect(quotes["GFNORTEO"]?.price == 30)
    }

    @Test("Request uses SIC marker for known US tickers")
    func requestUsesSICMarkerForKnownUSTickers() async throws {
        let body = json(#"{"VOO*":{"bmv":{"u":100.00}},"IBM*":{"biva":{"u":200.00}},"NVDA*":{"bmv":{"u":300.00}}}"#)
        let transport = FakeTransport(body: body, status: 200, expectedTickers: "VOO*,IBM*,NVDA*")
        let client = DataBursatilClient(token: "t", transport: transport)
        let quotes = try await client.quotes(for: ["VOO.MX", "IBM", "NVDA*"])

        #expect(quotes["VOO"]?.price == 100)
        #expect(quotes["IBM"]?.price == 200)
        #expect(quotes["NVDA"]?.price == 300)
    }

    @Test("Missing token throws without URL")
    func missingToken() async throws {
        let client = DataBursatilClient(token: "", transport: FakeTransport(body: json("{}"), status: 200))
        do {
            _ = try await client.quotes(for: ["FEMSAUBD"])
            Issue.record("expected throw")
        } catch let error as DataBursatilClient.Error {
            #expect(String(describing: error) == "missingToken")
        }
    }

    @Test("HTTP error does not leak token")
    func httpError() async throws {
        let client = DataBursatilClient(token: "secret-token", transport: FakeTransport(body: json("{}"), status: 401))
        do {
            _ = try await client.quotes(for: ["FEMSAUBD"])
            Issue.record("expected throw")
        } catch let error as DataBursatilClient.Error {
            let description = String(describing: error)
            #expect(!description.contains("secret-token"))
            #expect(!description.contains("token="))
        }
    }
}
