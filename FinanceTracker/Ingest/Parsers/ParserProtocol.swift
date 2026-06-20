import Foundation

protocol StatementParser: Sendable {
    func parse(data: Data) async throws -> [RawTransaction]
}
