import Foundation

struct DateRange: Hashable, Sendable {
    var start: Date
    var end: Date

    var duration: TimeInterval {
        end.timeIntervalSince(start)
    }

    func contains(_ date: Date) -> Bool {
        date >= start && date <= end
    }

    static func month(_ date: Date) -> DateRange {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: date))!
        let end = calendar.date(byAdding: DateComponents(month: 1, second: -1), to: start)!
        return DateRange(start: start, end: end)
    }

    static func year(_ date: Date) -> DateRange {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: calendar.dateComponents([.year], from: date))!
        let end = calendar.date(byAdding: DateComponents(year: 1, second: -1), to: start)!
        return DateRange(start: start, end: end)
    }
}
