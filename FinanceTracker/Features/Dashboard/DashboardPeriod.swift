import Foundation
import Charts

enum DashboardPeriodKind: String, CaseIterable, Sendable {
    case month = "Month"
    case quarter = "Quarter"
    case year = "Year"
    case all = "All"
    case custom = "Custom"

    func resolvedRange(now: Date = .now, customRange: DateRange? = nil) -> DateRange {
        let calendar = Calendar(identifier: .gregorian)
        switch self {
        case .month:
            let start = calendar.startOfMonth(for: now)
            return DateRange(start: start, end: now)
        case .quarter:
            let month = calendar.component(.month, from: now)
            let quarterStartMonth = ((month - 1) / 3) * 3 + 1
            var components = calendar.dateComponents([.year], from: now)
            components.month = quarterStartMonth
            components.day = 1
            let start = calendar.date(from: components)!
            return DateRange(start: start, end: now)
        case .year:
            let start = calendar.date(from: calendar.dateComponents([.year], from: now))!
            return DateRange(start: start, end: now)
        case .all:
            return DateRange(start: .distantPast, end: now)
        case .custom:
            guard let customRange else {
                return DateRange(start: .distantPast, end: now)
            }
            let start = calendar.startOfDay(for: min(customRange.start, customRange.end))
            let requestedEnd = max(customRange.start, customRange.end)
            let endOfRequestedDay = calendar.endOfDay(for: requestedEnd)
            return DateRange(start: start, end: min(endOfRequestedDay, now))
        }
    }
}

enum DashboardBucket: Equatable, Sendable {
    case day
    case week
    case month
    case year

    var component: Calendar.Component {
        switch self {
        case .day: return .day
        case .week: return .weekOfYear
        case .month: return .month
        case .year: return .year
        }
    }

    func start(for date: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> Date {
        switch self {
        case .day:
            return calendar.startOfDay(for: date)
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
        case .month:
            return calendar.startOfMonth(for: date)
        case .year:
            return calendar.date(from: calendar.dateComponents([.year], from: date))!
        }
    }

    func nextStart(after start: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> Date {
        switch self {
        case .day:
            return calendar.date(byAdding: .day, value: 1, to: start)!
        case .week:
            return calendar.date(byAdding: .weekOfYear, value: 1, to: start)!
        case .month:
            return calendar.date(byAdding: .month, value: 1, to: start)!
        case .year:
            return calendar.date(byAdding: .year, value: 1, to: start)!
        }
    }

    func contains(_ date: Date, in bucketStart: Date, periodEnd: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> Bool {
        let next = nextStart(after: bucketStart, calendar: calendar)
        return date >= bucketStart && date < min(next, periodEnd)
    }

    func matches(_ lhs: Date, _ rhs: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> Bool {
        calendar.isDate(lhs, equalTo: rhs, toGranularity: component)
    }
}

struct DashboardBucketInterval: Identifiable, Sendable {
    let bucketStart: Date
    let start: Date
    let end: Date

    var id: Date { bucketStart }

    func center(calendar: Calendar = Calendar(identifier: .gregorian)) -> Date {
        calendar.midpoint(from: start, to: end)
    }
}

struct DashboardPeriodContext: Sendable {
    let kind: DashboardPeriodKind
    let dateRange: DateRange
    let effectiveNetWorthDate: Date
    let chartDomain: ClosedRange<Date>
    let plotDomain: ClosedRange<Date>
    let bucket: DashboardBucket

    func intervals(calendar: Calendar = Calendar(identifier: .gregorian)) -> [DashboardBucketInterval] {
        guard dateRange.start <= dateRange.end else { return [] }

        var intervals: [DashboardBucketInterval] = []
        var cursor = bucket.start(for: dateRange.start, calendar: calendar)
        let maxIntervals = 1_500

        while cursor <= dateRange.end && intervals.count < maxIntervals {
            let next = bucket.nextStart(after: cursor, calendar: calendar)
            let end = min(calendar.date(byAdding: .second, value: -1, to: next)!, dateRange.end)
            if end >= dateRange.start {
                intervals.append(DashboardBucketInterval(bucketStart: cursor, start: max(cursor, dateRange.start), end: end))
            }
            cursor = next
        }
        return intervals
    }

    func interval(forBucketStart bucketStart: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> DashboardBucketInterval? {
        intervals(calendar: calendar).first { $0.bucketStart == bucketStart }
    }

    func barXValue(forBucketStart bucketStart: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> Date {
        interval(forBucketStart: bucketStart, calendar: calendar)?.center(calendar: calendar) ?? bucketStart
    }

    func plotDomain(forPopulatedBucketStarts bucketStarts: [Date], calendar: Calendar = Calendar(identifier: .gregorian)) -> ClosedRange<Date> {
        let populatedIntervals = bucketStarts
            .compactMap { interval(forBucketStart: $0, calendar: calendar) }
            .sorted { $0.start < $1.start }
        guard let first = populatedIntervals.first,
              let last = populatedIntervals.last else {
            return plotDomain
        }

        return paddedDomain(from: first, to: last, calendar: calendar)
    }

    func barWidth(forVisibleBucketCount visibleBucketCount: Int? = nil, calendar: Calendar = Calendar(identifier: .gregorian)) -> MarkDimension {
        .fixed(barWidthPoints(forVisibleBucketCount: visibleBucketCount, calendar: calendar))
    }

    func barWidthPoints(forVisibleBucketCount visibleBucketCount: Int? = nil, calendar: Calendar = Calendar(identifier: .gregorian)) -> CGFloat {
        let count = visibleBucketCount ?? intervals(calendar: calendar).count
        switch bucket {
        case .day:
            if count > 90 { return 3 }
            if count > 45 { return 5 }
            return 8
        case .week:
            if count > 26 { return 8 }
            if count > 12 { return 10 }
            return 14
        case .month:
            if count > 24 { return 8 }
            if count > 12 { return 12 }
            if count > 6 { return 18 }
            if count > 3 { return 24 }
            return 30
        case .year:
            if count > 12 { return 16 }
            if count > 6 { return 22 }
            return 28
        }
    }

    func bucketStart(forSelection date: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> Date {
        bucket.start(for: date, calendar: calendar)
    }

    func axisMarkValues(calendar: Calendar = Calendar(identifier: .gregorian)) -> [Date] {
        let centers = intervals(calendar: calendar).map { $0.center(calendar: calendar) }
        guard !centers.isEmpty else { return [] }

        switch bucket {
        case .day:
            let step = centers.count > 21 ? 3 : (centers.count > 14 ? 2 : 1)
            return centers.enumerated().compactMap { index, date in index.isMultiple(of: step) ? date : nil }
        case .week:
            let step = centers.count > 14 ? 2 : 1
            return centers.enumerated().compactMap { index, date in index.isMultiple(of: step) ? date : nil }
        case .month:
            let step = centers.count > 18 ? 3 : 1
            return centers.enumerated().compactMap { index, date in index.isMultiple(of: step) ? date : nil }
        case .year:
            return centers
        }
    }

    private func paddedDomain(from first: DashboardBucketInterval, to last: DashboardBucketInterval, calendar: Calendar) -> ClosedRange<Date> {
        let firstMidpoint = calendar.midpoint(from: first.start, to: first.end)
        let firstHalfDuration = calendar.dateComponents([.day, .hour, .minute, .second], from: first.start, to: firstMidpoint)
        let paddedStart = calendar.date(byAdding: firstHalfDuration.negated, to: first.start) ?? first.start

        let lastMidpoint = calendar.midpoint(from: last.start, to: last.end)
        let lastHalfDuration = calendar.dateComponents([.day, .hour, .minute, .second], from: lastMidpoint, to: last.end)
        let paddedEnd = calendar.date(byAdding: lastHalfDuration, to: last.end) ?? last.end

        return min(paddedStart, first.start)...max(paddedEnd, last.end)
    }
}

enum DashboardPeriodResolver {
    static func context(
        kind: DashboardPeriodKind,
        requestedRange: DateRange,
        dataRange: DateRange?,
        now: Date = .now
    ) -> DashboardPeriodContext {
        let calendar = Calendar(identifier: .gregorian)

        if kind == .all {
            let dataStart = dataRange?.start ?? calendar.startOfDay(for: now)
            let start = min(dataStart, now)
            let range = DateRange(start: start, end: now)
            let days = calendar.dateComponents([.day], from: start, to: now).day ?? 0
            let bucket: DashboardBucket = days > 730 ? .year : .month
            let domainStart = bucket.start(for: start, calendar: calendar)
            return DashboardPeriodContext(
                kind: kind,
                dateRange: range,
                effectiveNetWorthDate: now,
                chartDomain: domainStart...now,
                plotDomain: Self.plotDomain(for: range, bucket: bucket, calendar: calendar),
                bucket: bucket
            )
        }

        let normalized = DateRange(start: requestedRange.start, end: min(requestedRange.end, now))
        let bucket = bucketFor(kind: kind, range: normalized, calendar: calendar)
        let domainStart = bucket.start(for: normalized.start, calendar: calendar)
        return DashboardPeriodContext(
            kind: kind,
            dateRange: normalized,
            effectiveNetWorthDate: normalized.end,
            chartDomain: domainStart...normalized.end,
            plotDomain: Self.plotDomain(for: normalized, bucket: bucket, calendar: calendar),
            bucket: bucket
        )
    }

    private static func bucketFor(kind: DashboardPeriodKind, range: DateRange, calendar: Calendar) -> DashboardBucket {
        switch kind {
        case .month:
            return .day
        case .quarter, .year:
            return .month
        case .all:
            return calendar.dateComponents([.day], from: range.start, to: range.end).day ?? 0 > 730 ? .year : .month
        case .custom:
            let days = calendar.dateComponents([.day], from: range.start, to: range.end).day ?? 0
            if days <= 45 { return .day }
            if days <= 120 { return .week }
            if days <= 730 { return .month }
            return .year
        }
    }

    private static func plotDomain(for range: DateRange, bucket: DashboardBucket, calendar: Calendar) -> ClosedRange<Date> {
        let startBucket = bucket.start(for: range.start, calendar: calendar)
        let startIntervalStart = max(startBucket, range.start)
        let startIntervalEnd = min(calendar.date(byAdding: .second, value: -1, to: bucket.nextStart(after: startBucket, calendar: calendar))!, range.end)
        let startMidpoint = calendar.midpoint(from: startIntervalStart, to: startIntervalEnd)
        let startHalfDuration = calendar.dateComponents([.day, .hour, .minute, .second], from: startIntervalStart, to: startMidpoint)
        let paddedStart = calendar.date(byAdding: startHalfDuration.negated, to: startIntervalStart) ?? range.start

        let endBucket = bucket.start(for: range.end, calendar: calendar)
        let endIntervalStart = max(endBucket, range.start)
        let endIntervalEnd = range.end
        let endMidpoint = calendar.midpoint(from: endIntervalStart, to: endIntervalEnd)
        let endHalfDuration = calendar.dateComponents([.day, .hour, .minute, .second], from: endIntervalStart, to: endMidpoint)
        let paddedEnd = calendar.date(byAdding: endHalfDuration, to: endIntervalEnd) ?? range.end

        return min(paddedStart, range.start)...max(paddedEnd, range.end)
    }
}

private extension Calendar {
    func startOfMonth(for date: Date) -> Date {
        self.date(from: self.dateComponents([.year, .month], from: date))!
    }

    func endOfDay(for date: Date) -> Date {
        let start = startOfDay(for: date)
        return self.date(byAdding: DateComponents(day: 1, second: -1), to: start)!
    }

    func midpoint(from start: Date, to end: Date) -> Date {
        guard start < end else { return start }
        let components = dateComponents([.day, .hour, .minute, .second], from: start, to: end)
        let halfComponents = DateComponents(
            day: (components.day ?? 0) / 2,
            hour: ((components.day ?? 0) % 2) * 12 + (components.hour ?? 0) / 2,
            minute: ((components.hour ?? 0) % 2) * 30 + (components.minute ?? 0) / 2,
            second: ((components.minute ?? 0) % 2) * 30 + (components.second ?? 0) / 2
        )
        return date(byAdding: halfComponents, to: start) ?? start.addingTimeInterval(end.timeIntervalSince(start) / 2)
    }
}

private extension DateComponents {
    var negated: DateComponents {
        DateComponents(
            day: -(day ?? 0),
            hour: -(hour ?? 0),
            minute: -(minute ?? 0),
            second: -(second ?? 0)
        )
    }
}
