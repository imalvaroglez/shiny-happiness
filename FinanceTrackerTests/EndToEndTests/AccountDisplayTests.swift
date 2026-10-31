import Testing
import Foundation
@testable import FinanceTracker

@Suite("Account Display")
struct AccountDisplayTests {
    @Test("Institution identical to the display name is hidden")
    func identicalInstitutionIsHidden() {
        #expect(AccountDisplay.institutionLabel(displayName: "BBVA", institution: "BBVA") == nil)
        #expect(AccountDisplay.institutionLabel(displayName: "BBVA", institution: "bbva ") == nil)
        #expect(AccountDisplay.institutionLabel(displayName: "BBVA", institution: "Bbvá") == nil)
    }

    @Test("Institution already contained in the display name is hidden")
    func containedInstitutionIsHidden() {
        #expect(AccountDisplay.institutionLabel(displayName: "BBVA ···1234", institution: "BBVA") == nil)
        #expect(AccountDisplay.institutionLabel(displayName: "bbva", institution: "BBVA México") == nil)
    }

    @Test("Empty institution is hidden")
    func emptyInstitutionIsHidden() {
        #expect(AccountDisplay.institutionLabel(displayName: "BBVA", institution: "") == nil)
        #expect(AccountDisplay.institutionLabel(displayName: "BBVA", institution: "   ") == nil)
    }

    @Test("Institution that adds information is kept")
    func informativeInstitutionIsKept() {
        #expect(AccountDisplay.institutionLabel(displayName: "The Gold Card", institution: "American Express") == "American Express")
        #expect(AccountDisplay.institutionLabel(displayName: "Cuenta Nominativa", institution: "BBVA") == "BBVA")
    }

    @Test("A tiny nickname inside the institution does not hide it")
    func tinyNicknameInsideInstitutionIsKept() {
        #expect(AccountDisplay.institutionLabel(displayName: "N", institution: "Banorte") == "Banorte")
        #expect(AccountDisplay.institutionLabel(displayName: "Nu", institution: "Banorte") == "Banorte")
    }
}
