import Foundation

extension Date {
    func formattedMX(date: Date.FormatStyle.DateStyle = .abbreviated,
                     time: Date.FormatStyle.TimeStyle = .omitted) -> String {
        formatted(Date.FormatStyle(date: date, time: time, locale: Locale(identifier: "es-MX")))
    }
}
