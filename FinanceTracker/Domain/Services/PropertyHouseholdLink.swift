import Foundation

/// Optional v2 extension. Missing keys in v1 archives remain readable without a disk rewrite.
struct PropertyHouseholdLink: Codable, Equatable, Sendable {
    var propertyID: UUID
    var userID: UUID
    var partnerID: UUID
    var updatedAt: Date
}

struct PropertyHouseholdMonth: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var monthStart: Date
    var partnerIncome: Decimal
    var userIncome: Decimal?
    var useUserOverride: Bool
    var splitMethod: String
    var customUserPercent: Decimal?
    var customPartnerPercent: Decimal?
    var notes: String?
    var userConfirmedAt: Date?
    var partnerConfirmedAt: Date?
    var updatedAt: Date
    var deletedAt: Date?

    /// Typed view of the persisted raw string; unknown values fall back to the
    /// default instead of failing the sidecar decode.
    var splitMethodValue: HouseholdSplitMethod {
        HouseholdSplitMethod(rawValue: splitMethod) ?? .monthlyDefault
    }
}

enum PropertyParticipation {
    static func firstInactiveMonth(selected: Date, today: Date, calendar: Calendar = .current) -> Date {
        max(calendar.propertyMonthStart(for: selected), calendar.propertyMonthStart(for: today))
    }

    /// activeThrough is inclusive; exit starts at max(selected month, actual current month).
    static func lastActiveMonth(selected: Date, today: Date, calendar: Calendar = .current) -> Date {
        let firstInactive = firstInactiveMonth(selected: selected, today: today, calendar: calendar)
        return calendar.date(byAdding: .month, value: -1, to: firstInactive) ?? firstInactive
    }
}
