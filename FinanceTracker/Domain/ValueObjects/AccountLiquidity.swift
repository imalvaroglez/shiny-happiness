import Foundation

enum AccountLiquidity: String, Codable, CaseIterable {
    case liquid
    case restricted
    case lockedUntilRetirement
}
