import Foundation

protocol HTTPRequesting: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPRequesting {}

struct DataBursatilClient: Sendable {
    enum Error: Swift.Error, LocalizedError {
        case missingToken
        case requestFailed
        case http(Int)
        case noQuotes
        case decodeFailed

        var errorDescription: String? {
            switch self {
            case .missingToken: "DataBursatil token is not set."
            case .requestFailed: "DataBursatil request failed."
            case .http(let code): "DataBursatil returned HTTP \(code)."
            case .noQuotes: "DataBursatil returned no quotes."
            case .decodeFailed: "Could not decode DataBursatil response."
            }
        }
    }

    struct PriceSnapshot: Sendable, Equatable {
        let price: Decimal
        let timestamp: Date?
    }

    private let token: String
    private let transport: HTTPRequesting

    init(token: String, transport: HTTPRequesting = URLSession.shared) {
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        self.transport = transport
    }

    func quotes(for tickers: [String]) async throws -> [String: PriceSnapshot] {
        guard !token.isEmpty else { throw Error.missingToken }

        var components = URLComponents(string: "https://api.databursatil.com/v2/cotizaciones")!
        components.queryItems = [
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "emisora_serie", value: tickers.map(PortfolioTicker.providerTicker).joined(separator: ",")),
            URLQueryItem(name: "concepto", value: "U"),
            URLQueryItem(name: "bolsa", value: "BMV,BIVA"),
        ]
        let request = URLRequest(url: components.url!)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch {
            throw Error.requestFailed
        }

        guard let http = response as? HTTPURLResponse else { throw Error.requestFailed }
        guard (200..<300).contains(http.statusCode) else { throw Error.http(http.statusCode) }
        return try Self.decode(data)
    }

    private struct BolsaQuote: Decodable {
        let u: Decimal?
        let f: String?
    }

    static func decode(_ data: Data) throws -> [String: PriceSnapshot] {
        let payload: [String: [String: BolsaQuote]]
        do {
            payload = try JSONDecoder().decode([String: [String: BolsaQuote]].self, from: data)
        } catch {
            throw Error.decodeFailed
        }

        var quotes: [String: PriceSnapshot] = [:]
        for (ticker, exchanges) in payload {
            let normalizedExchanges = exchanges.reduce(into: [String: BolsaQuote]()) { result, exchange in
                result[exchange.key.uppercased()] = exchange.value
            }
            let quote = normalizedExchanges["BMV"] ?? normalizedExchanges["BIVA"]
            guard let price = quote?.u, price > 0 else { continue }
            quotes[PortfolioTicker.normalize(ticker)] = PriceSnapshot(price: price, timestamp: parseDate(quote?.f))
        }
        guard !quotes.isEmpty else { throw Error.noQuotes }
        return quotes
    }

    static func parseDate(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/Mexico_City")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: string)
    }

}
