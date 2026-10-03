import Foundation
import Testing
@testable import FinanceTracker

@Suite("Promotion editor input")
struct PromotionEditorInputTests {
    @Test func unchangedTargetRoundTrips() throws {
        #expect(try PromotionEditorInput.target(from: PromotionEditorInput.editableTarget(100_000)) == 100_000)
        #expect(try PromotionEditorInput.target(from: "100,000.00") == 100_000)
        #expect(try PromotionEditorInput.target(from: " ") == nil)
        let precise = Decimal(string: "100.001")!
        #expect(try PromotionEditorInput.target(from: PromotionEditorInput.editableTarget(precise)) == precise)
    }

    @Test(arguments: ["100abc", "$100,000.00", "1,00", "0", "-10", "NaN"])
    func invalidTargetIsNotSilentlyRemoved(_ text: String) {
        #expect(throws: PromotionEditorInput.InputError.self) { try PromotionEditorInput.target(from: text) }
    }

    @Test func openWindowBoundsRemainIndependent() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try PromotionEditorInput.validateWindow(start: date, end: nil)
        try PromotionEditorInput.validateWindow(start: nil, end: date)
        #expect(throws: PromotionEditorInput.InputError.self) {
            try PromotionEditorInput.validateWindow(start: date, end: date.addingTimeInterval(-86_400))
        }
    }
}
