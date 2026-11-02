import Foundation

/// Kills the poisoned time-of-day loop: the capture sheet suggests the last
/// capture's `postedAt`, and a date-only picker swap keeps its time-of-day. If
/// that time is an evening hour inherited from the historical +6 h incident,
/// "today" captures land at 20:00 tonight — in the future, silently excluded
/// from every as-of-now balance.
///
/// Rule: a capture on **today's** date can never be in the future (you cannot
/// have spent money later today), so it clamps to `now`. Captures on a future
/// **day** stay untouched: postdating is a legitimate user choice.
enum CaptureDateSanitizer {
    static func sanitize(_ chosen: Date, now: Date = .now, calendar: Calendar = .current) -> Date {
        guard chosen > now, calendar.isDate(chosen, inSameDayAs: now) else { return chosen }
        return now
    }
}
