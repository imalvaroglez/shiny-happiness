import Foundation

extension Date {
    var startOfMonth: Date {
        let calendar = Calendar(identifier: .gregorian)
        return calendar.date(from: calendar.dateComponents([.year, .month], from: self))!
    }

    var endOfMonth: Date {
        let calendar = Calendar(identifier: .gregorian)
        let start = startOfMonth
        return calendar.date(byAdding: DateComponents(month: 1, second: -1), to: start)!
    }

    var yearMonth: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: self)
    }

    var monthName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        formatter.locale = Locale(identifier: "es_MX")
        return formatter.string(from: self)
    }
}
