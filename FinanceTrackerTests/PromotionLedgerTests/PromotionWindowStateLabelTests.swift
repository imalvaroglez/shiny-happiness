
import Foundation
import Testing
@testable import FinanceTracker

@Suite("Etiquetas es-MX de la ventana promocional")
struct PromotionWindowStateLabelTests {
    private static func state(_ start: String?, _ end: String?, asOf: String) -> PromotionWindowState {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = MexicoBankingCalendar.timeZone
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let date: (String) -> Date = { formatter.date(from: $0)! }
        return PromotionWindowCalculator.state(windowStart: start.map(date), windowEnd: end.map(date),
                                               asOf: date(asOf), calendar: calendar)
    }

    @Test("none no produce etiqueta")
    func noneHasNoLabel() {
        #expect(Self.state(nil, nil, asOf: "2026-09-30").label == nil)
    }

    @Test("antes con 1 día dice mañana")
    func beforeOneDay() {
        #expect(Self.state("2026-09-09", "2026-12-07", asOf: "2026-09-08").label == "comienza el 9 sep (mañana)")
    }

    @Test("antes con N días los cuenta")
    func beforeSeveralDays() {
        #expect(Self.state("2026-09-09", "2026-12-07", asOf: "2026-09-01").label == "comienza el 9 sep (en 8 días)")
    }

    @Test("durante completo: día N de M con restantes")
    func duringFull() {
        #expect(Self.state("2026-09-09", "2026-12-07", asOf: "2026-09-30").label == "día 22 de 90 · quedan 69")
    }

    @Test("solo inicio: solo el día")
    func openStart() {
        #expect(Self.state("2026-09-09", nil, asOf: "2026-09-30").label == "día 22")
    }

    @Test("solo fin: solo los restantes")
    func endOnly() {
        #expect(Self.state(nil, "2026-12-07", asOf: "2026-12-05").label == "quedan 3 días")
    }

    @Test("después: ventana cerrada con fecha")
    func after() {
        #expect(Self.state("2026-09-09", "2026-12-07", asOf: "2026-12-08").label == "ventana cerrada el 7 dic")
    }
}
