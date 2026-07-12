import Foundation
import Testing
@testable import FinanceTracker

@Suite("Household Inclusion preset + filters")
struct HouseholdInclusionTests {
    @Test("Each TransactionFilterPreset carries a unique one-shot token")
    func presetTokensAreUnique() {
        let month = YearMonth(year: 2026, month: 7)
        let a = TransactionFilterPreset(month: month, inclusion: .notIncluded)
        let b = TransactionFilterPreset(month: month, inclusion: .notIncluded)
        // Structurally identical inputs still produce distinct events, so the
        // consume guard (`preset.id != consumedPresetID`) treats a re-issued
        // preset as a fresh, applicable navigation intent.
        #expect(a.id != b.id)
        #expect(a != b)
        #expect(a.month == month)
        #expect(a.inclusion == .notIncluded)
    }

    @Test("HouseholdInclusionFilter covers all + included + not included")
    func inclusionFilterCases() {
        #expect(HouseholdInclusionFilter.allCases.count == 3)
        #expect(HouseholdInclusionFilter.allCases.contains(.notIncluded))
        #expect(HouseholdInclusionFilter.allCases.contains(.included))
    }

    @Test("HouseholdScopeResolver maps legacy assignments deterministically")
    func resolverMapping() {
        #expect(HouseholdScopeResolver.resolveScope(assignmentRaw: nil) == .excluded)
        #expect(HouseholdScopeResolver.resolveScope(assignmentRaw: "user") == .excluded)
        #expect(HouseholdScopeResolver.resolveScope(assignmentRaw: "unassigned") == .excluded)
        #expect(HouseholdScopeResolver.resolveScope(assignmentRaw: "future") == .excluded)
        #expect(HouseholdScopeResolver.resolveScope(assignmentRaw: ExpenseAssignment.shared.rawValue) == .included)
        #expect(HouseholdScopeResolver.resolveScope(assignmentRaw: ExpenseAssignment.partner.rawValue) == .included)
        #expect(HouseholdScopeResolver.resolveScope(assignmentRaw: ExpenseAssignment.custom.rawValue) == .included)
    }
}
