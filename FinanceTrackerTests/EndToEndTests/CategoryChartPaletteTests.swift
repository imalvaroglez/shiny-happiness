import Foundation
import Testing
@testable import FinanceTracker

@Suite("Category Chart Palette")
struct CategoryChartPaletteTests {
    @Test("Visible categories receive stable, unique color slots regardless of input order")
    func slotsAreStableAndUniqueForTheVisibleSet() {
        let ids = [
            UUID(uuidString: "00000000-0000-0000-0000-000000000008")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000006")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000007")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        ]

        let slots = CategoryChartPalette.slots(for: ids)
        let shuffledSlots = CategoryChartPalette.slots(for: Array(ids.reversed()))

        #expect(slots == shuffledSlots)
        #expect(Set(slots.keys) == Set(ids))
        #expect(Set(slots.values).count == ids.count)
        #expect(Set(slots.values) == Set(0..<ids.count))
        #expect(CategoryChartPalette.colors(for: ids).count == ids.count)
        #expect(CategoryChartPalette.colors(for: []).isEmpty)
    }
}
