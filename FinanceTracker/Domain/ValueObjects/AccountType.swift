import Foundation

enum AccountType: String, Codable, CaseIterable {
    case checking
    case savings
    case creditCard
    case investment
    case loan
    case wallet
    case retirement
    case other
}
