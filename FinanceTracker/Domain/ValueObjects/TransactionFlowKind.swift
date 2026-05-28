import Foundation

enum TransactionFlowKind: String, Codable, CaseIterable {
    case income
    case expense
    case transfer
    case charge
    case cardCredit
    case payment
}
