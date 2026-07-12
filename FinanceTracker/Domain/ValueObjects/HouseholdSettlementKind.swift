import Foundation

enum ExpenseAssignment: String, Codable, CaseIterable, Identifiable {
    case user
    case shared
    case partner
    case custom

    static let quickCases: [ExpenseAssignment] = [.user, .shared, .partner]

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .user: "User"
        case .shared: "Shared"
        case .partner: "Fer"
        case .custom: "Custom split"
        }
    }
}

enum HouseholdAllocationError: Error, Equatable {
    case negativeAmount
    case exceedsExpense
    case requiresCurrencyPrecision
}

enum HouseholdExpenseAllocation: Equatable {
    case user
    case shared
    case partner
    case custom(ferAmount: Decimal)
}

extension Decimal {
    var currencyRounded: Decimal {
        var input = self
        var output = Decimal()
        NSDecimalRound(&output, &input, 2, .plain)
        return output
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

/// Whether a transaction participates in Household Settlement. Inclusion is a
/// concept separate from `ExpenseAssignment`: an excluded transaction never
/// appears in the report regardless of its (latent) assignment.
enum HouseholdScope: String, Codable {
    case excluded
    case included
}

/// Single source of truth for deriving Household scope from legacy assignment
/// state. Shared by the live repair service and backup restore so the legacy
/// mapping cannot drift. Explicit (already-migrated) scope always wins and is
/// never re-derived — callers gate on `householdScopeRaw == nil` first.
enum HouseholdScopeResolver {
    static func resolveScope(assignmentRaw: String?) -> HouseholdScope {
        switch assignmentRaw {
        case ExpenseAssignment.shared.rawValue,
             ExpenseAssignment.partner.rawValue,
             ExpenseAssignment.custom.rawValue:
            return .included
        default:
            // nil, "user", "unassigned", unknown → excluded.
            return .excluded
        }
    }
}
