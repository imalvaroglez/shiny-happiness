import Foundation

enum CategoryKind: String, Codable, CaseIterable {
    case income
    case expense
    case transfer
    case investment
    case creditCardPayment
}
