import Foundation
import Testing
@testable import FinanceTracker

@Suite("Ventana promocional (días civiles, límites inclusivos)")
struct PromotionWindowTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = MexicoBankingCalendar.timeZone
        return calendar
    }()

    /// Promoción Platinum real: 2026-09-09 → 2026-12-07 (90 días).
    private let platinumStart = Self.date("2026-09-09")
    private let platinumEnd = Self.date("2026-12-07")

    private static func date(_ value: String) -> Date {
        Self.date(value, calendar: Self.calendar)
    }

    private static func date(_ value: String, calendar: Calendar) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)!
    }

    @Test("Sin ventana no hay contador")
    func noWindow() {
        #expect(PromotionWindowCalculator.state(windowStart: nil, windowEnd: nil,
                                                 asOf: Self.date("2026-09-30"),
                                                 calendar: Self.calendar) == .none)
    }

    @Test("El primer día de ventana es día 1 (límite inclusivo)")
    func firstDayIsOne() {
        #expect(PromotionWindowCalculator.state(windowStart: platinumStart, windowEnd: platinumEnd,
                                                 asOf: Self.date("2026-09-09"),
                                                 calendar: Self.calendar)
                == .during(dayNumber: 1, totalDays: 90, daysRemaining: 90))
    }

    @Test("Ventana Platinum: 30-sep es día 22 de 90 con 69 restantes")
    func platinumMidWindow() {
        #expect(PromotionWindowCalculator.state(windowStart: platinumStart, windowEnd: platinumEnd,
                                                 asOf: Self.date("2026-09-30"),
                                                 calendar: Self.calendar)
                == .during(dayNumber: 22, totalDays: 90, daysRemaining: 69))
    }

    @Test("El último día de ventana sigue siendo durante (end inclusivo)")
    func lastDayIsStillDuring() {
        #expect(PromotionWindowCalculator.state(windowStart: platinumStart, windowEnd: platinumEnd,
                                                 asOf: Self.date("2026-12-07"),
                                                 calendar: Self.calendar)
                == .during(dayNumber: 90, totalDays: 90, daysRemaining: 1))
    }

    @Test("Antes de la ventana reporta días para el inicio")
    func beforeWindow() {
        #expect(PromotionWindowCalculator.state(windowStart: platinumStart, windowEnd: platinumEnd,
                                                 asOf: Self.date("2026-09-08"),
                                                 calendar: Self.calendar)
                == .before(start: platinumStart, daysUntilStart: 1))
    }

    @Test("Después de la ventana reporta días desde el cierre")
    func afterWindow() {
        #expect(PromotionWindowCalculator.state(windowStart: platinumStart, windowEnd: platinumEnd,
                                                 asOf: Self.date("2026-12-08"),
                                                 calendar: Self.calendar)
                == .after(end: platinumEnd, daysSinceEnd: 1))
    }

    @Test("Ventana abierta (solo inicio): día N sin total ni restantes")
    func openEndedStart() {
        #expect(PromotionWindowCalculator.state(windowStart: platinumStart, windowEnd: nil,
                                                 asOf: Self.date("2026-09-30"),
                                                 calendar: Self.calendar)
                == .during(dayNumber: 22, totalDays: nil, daysRemaining: nil))
    }

    @Test("Ventana con solo fin: restantes sin número de día")
    func endOnly() {
        #expect(PromotionWindowCalculator.state(windowStart: nil, windowEnd: platinumEnd,
                                                 asOf: Self.date("2026-12-05"),
                                                 calendar: Self.calendar)
                == .during(dayNumber: nil, totalDays: nil, daysRemaining: 3))
    }

    @Test("Los días civiles no se rompen al cruzar un cambio de horario de verano")
    func dstCrossingUsesCivilDays() {
        var ny = Calendar(identifier: .gregorian)
        ny.timeZone = TimeZone(identifier: "America/New_York")!
        // El horario de verano de EE. UU. empieza el 8-mar-2026: un día de 23 h en medio de la ventana.
        let start = Self.date("2026-03-07", calendar: ny)
        let end = Self.date("2026-03-11", calendar: ny)
        #expect(PromotionWindowCalculator.state(windowStart: start, windowEnd: end,
                                                 asOf: Self.date("2026-03-09", calendar: ny),
                                                 calendar: ny)
                == .during(dayNumber: 3, totalDays: 5, daysRemaining: 3))
    }

    @Test("Una hora cerca de medianoche no cambia el día civil")
    func lateHourSameCivilDay() {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 30; components.hour = 23
        let lateNight = Self.calendar.date(from: components)!
        #expect(PromotionWindowCalculator.state(windowStart: platinumStart, windowEnd: platinumEnd,
                                                 asOf: lateNight,
                                                 calendar: Self.calendar)
                == .during(dayNumber: 22, totalDays: 90, daysRemaining: 69))
    }
}
