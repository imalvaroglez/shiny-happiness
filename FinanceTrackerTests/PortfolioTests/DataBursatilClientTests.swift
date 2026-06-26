import Testing
import Foundation
@testable import FinanceTracker

@Suite("DataBursatil Client")
struct DataBursatilClientTests {
    private struct FakeTransport: HTTPRequesting {
        let body: Data
        let status: Int

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
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
        let body = json(#"{"FEMSAUBD":{"BMV":{"u":19.86,"f":"2026-06-25 15:30:00"}}}"#)
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
