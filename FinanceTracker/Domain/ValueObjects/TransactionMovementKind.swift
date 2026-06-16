import Foundation

enum TransactionMovementKind: String, Codable, CaseIterable {
    case income
    case expense
    case transfer
    case adjustment
}
