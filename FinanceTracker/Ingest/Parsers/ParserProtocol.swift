import Foundation

protocol StatementParser: Sendable {
    static var supportedIssuers: [String] { get }
    static var supportedFormats: [FileFormat] { get }
    func parse(data: Data) async throws -> [RawTransaction]
}
