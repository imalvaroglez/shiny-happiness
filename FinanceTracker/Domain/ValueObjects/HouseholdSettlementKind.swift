import Foundation

enum ExpenseAssignment: String, Codable, CaseIterable, Identifiable {
    case unassigned
    case user
    case shared
    case partner

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .unassigned: "Unassigned"
        case .user: "User"
        case .shared: "Shared"
        case .partner: "Fer"
        }
    }
}

enum SettlementPaidBy: String, Codable, CaseIterable, Identifiable {
    case user
    case partner
    case unknown

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .user: "User"
        case .partner: "Partner"
        case .unknown: "Unknown"
        }
    }
}

enum HouseholdSplitMethod: String, Codable, CaseIterable, Identifiable {
    case monthlyDefault
    case fiftyFifty
    case customPercent

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .monthlyDefault: "Proportional by income"
        case .fiftyFifty: "50/50"
        case .customPercent: "Custom"
        }
    }
}
