import Foundation

enum AccountBalanceSnapshotKind: String, Codable, CaseIterable {
    case manualOpening
    case manualAdjustment
    case portfolioValuation
}
