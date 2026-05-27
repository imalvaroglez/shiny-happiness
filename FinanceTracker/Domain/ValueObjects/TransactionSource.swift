import Foundation

enum TransactionSource: String, Codable, CaseIterable {
    case imported
    case manual
    case pendingResolution
}
