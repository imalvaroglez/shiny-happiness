import Foundation
import SwiftData

@Model
final class HouseholdPartnerIncomeEstimate: LastModifiedTracking {
    var id: UUID
    var monthStart: Date
    var amount: Decimal
    var useUserIncomeManualOverride: Bool = false
    var userIncomeManualOverride: Decimal?
    var splitMethodRaw: String?
    var customUserPercent: Decimal?
    var customPartnerPercent: Decimal?
    var notes: String?
    var createdAt: Date
    var lastModifiedAt: Date = Date.now

    init(
        id: UUID = UUID(),
        monthStart: Date,
        amount: Decimal,
        useUserIncomeManualOverride: Bool = false,
        userIncomeManualOverride: Decimal? = nil,
        splitMethodRaw: String? = nil,
        customUserPercent: Decimal? = nil,
        customPartnerPercent: Decimal? = nil,
        notes: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.monthStart = monthStart
        self.amount = amount
        self.useUserIncomeManualOverride = useUserIncomeManualOverride
        self.userIncomeManualOverride = userIncomeManualOverride
        self.splitMethodRaw = splitMethodRaw
        self.customUserPercent = customUserPercent
        self.customPartnerPercent = customPartnerPercent
        self.notes = notes
        self.createdAt = createdAt
    }

    var splitMethod: HouseholdSplitMethod {
        splitMethodRaw.flatMap(HouseholdSplitMethod.init(rawValue:)) ?? .monthlyDefault
    }

    func setSplitMethod(_ method: HouseholdSplitMethod) {
        splitMethodRaw = method == .monthlyDefault ? nil : method.rawValue
    }
}
