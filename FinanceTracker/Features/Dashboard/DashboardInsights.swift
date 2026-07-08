import Foundation

// MARK: - Snapshot value types for the redesigned dashboard's Insight row.
//
// These are pure `Sendable` value types. The numeric/threshold logic is split
// into `*Builder` namespaces so it can be unit-tested without a ModelContext;
// `DashboardViewModel` fetches the raw data and hands it to the builders.

// MARK: Credit Card Pace

/// Credit Card Pace is selector-independent and always calendar-month-to-date
/// (D5). Status is threshold-based and degrades gracefully with limited
/// history (refinement #3): it uses whatever prior calendar months exist and
/// only reports "not enough history" when there is zero usable prior data.
struct CardPaceSnapshot: Hashable {
    enum PaceStatus: Hashable {
        case calm
        case watch
        case critical
        case insufficientHistory   // zero usable prior months
    }

    let spentToDate: Decimal
    let dailyAverage: Decimal
    let projectedMonthEnd: Decimal
    let baselineAverage: Decimal?     // nil when insufficient history
    let dayOfMonth: Int
    let daysInMonth: Int
    let status: PaceStatus

    var hasHistory: Bool { baselineAverage != nil }
}

enum CardPaceBuilder {
    /// - Parameters:
    ///   - priorMonthlyCharges: total card charges for each prior calendar
    ///     month, any order. Used as the baseline; degrades to 1–2 months.
    ///   - spentToDate: charges in the current calendar month so far.
    ///   - dayOfMonth: 1-based day of month for "today".
    ///   - daysInMonth: total days in the current calendar month.
    static func build(
        priorMonthlyCharges: [Decimal],
        spentToDate: Decimal,
        dayOfMonth: Int,
        daysInMonth: Int
    ) -> CardPaceSnapshot {
        let safeDays = max(daysInMonth, 1)
        let elapsed = max(min(dayOfMonth, safeDays), 1)
        let dailyAverage = spentToDate / Decimal(elapsed)
        let projected = dailyAverage * Decimal(safeDays)

        let baseline: Decimal? = {
            let usable = priorMonthlyCharges.filter { $0 > 0 }
            guard !usable.isEmpty else { return nil }
            return usable.reduce(0, +) / Decimal(usable.count)
        }()

        let status: CardPaceSnapshot.PaceStatus
        if let baseline, baseline > 0 {
            let ratio = (projected as NSDecimalNumber).doubleValue / (baseline as NSDecimalNumber).doubleValue
            if ratio > 1.30 { status = .critical }
            else if ratio > 1.0 { status = .watch }
            else { status = .calm }
        } else {
            status = .insufficientHistory
        }

        return CardPaceSnapshot(
            spentToDate: spentToDate,
            dailyAverage: dailyAverage,
            projectedMonthEnd: projected,
            baselineAverage: baseline,
            dayOfMonth: elapsed,
            daysInMonth: safeDays,
            status: status
        )
    }
}

// MARK: Upcoming Payments

/// Amount priority is strict (D12): `paymentForNoInterest` is primary when
/// present; `minimumPayment` is the fallback. Never sum minimums when
/// no-interest data is available.
struct UpcomingPayment: Hashable, Identifiable {
    let id: UUID
    let institution: String
    let noInterestAmount: Decimal?     // primary ("pay to avoid interest")
    let minimumAmount: Decimal?        // fallback
    let dueDate: Date

    /// The actionable primary amount: no-interest if present, else minimum.
    var primaryAmount: Decimal? { noInterestAmount ?? minimumAmount }
    var hasNoInterest: Bool { noInterestAmount != nil }
}

struct UpcomingPaymentsSnapshot: Hashable {
    enum PaymentStatus: Hashable {
        case calm        // none due in window
        case watch       // due within 14 days
        case critical    // due within 3 days
    }

    let due: [UpcomingPayment]          // sorted by dueDate ascending, within [now, now+14d]
    let totalPrimary: Decimal           // sum of primaryAmount across due
    let status: PaymentStatus
}

enum UpcomingPaymentsBuilder {
    static func build(due: [UpcomingPayment], today: Date, calendar: Calendar) -> UpcomingPaymentsSnapshot {
        let windowEnd = calendar.date(byAdding: .day, value: 14, to: calendar.startOfDay(for: today)) ?? today
        let inWindow = due
            .filter { $0.dueDate >= calendar.startOfDay(for: today) && $0.dueDate <= windowEnd }
            .sorted { $0.dueDate < $1.dueDate }

        let total = inWindow.reduce(Decimal(0)) { $0 + ($1.primaryAmount ?? 0) }

        let soonestDays: Int? = inWindow.first.map {
            calendar.dateComponents([.day], from: calendar.startOfDay(for: today), to: $0.dueDate).day ?? 0
        }

        let status: UpcomingPaymentsSnapshot.PaymentStatus
        if let days = soonestDays {
            status = days <= 3 ? .critical : .watch
        } else {
            status = .calm
        }

        return UpcomingPaymentsSnapshot(due: inWindow, totalPrimary: total, status: status)
    }
}

// MARK: Spending Anomaly

/// Per-category change vs the previous equal-length period. Materiality floor
/// prevents tiny categories from firing the card (refinement #3/D4).
struct CategoryAnomaly: Hashable, Identifiable {
    let id: UUID
    let categoryName: String
    let current: Decimal
    let previous: Decimal
    let percentChange: Double       // signed; e.g. 32 = +32%
}

struct SpendingAnomalySnapshot: Hashable {
    /// Why no anomaly is shown. Distinguishes "calculated and nothing
    /// qualified" from "intentionally not calculated for this range" so the
    /// card never presents a skipped check as a clean bill of health.
    enum EmptyReason: Hashable {
        case calculatedNothingQualified
        case skippedForRange            // .year / .all — perf guardrail
    }

    let strongest: CategoryAnomaly?
    let others: [CategoryAnomaly]   // up to 2, sorted by |percentChange|
    /// Present only when `strongest == nil`. Nil when there IS an anomaly.
    let emptyReason: EmptyReason?

    var isCalm: Bool { strongest == nil }
    var wasSkipped: Bool { strongest == nil && emptyReason == .skippedForRange }

    /// Snapshot used when the anomaly pass is intentionally skipped for a range
    /// (`.year` / `.all` — see perf guardrail in `DashboardViewModel`). Kept
    /// distinct from a calculated-clean result so the UI can say so honestly.
    static let skippedForRange = SpendingAnomalySnapshot(
        strongest: nil, others: [], emptyReason: .skippedForRange
    )
}

enum SpendingAnomalyBuilder {
    /// - Parameters:
    ///   - current: this period's per-category spend.
    ///   - previous: previous period's per-category spend.
    ///   - totalExpenses: this period's total expenses (materiality floor ref).
    ///   - materialityPercent: a category must be ≥ this fraction of total
    ///     expenses to qualify (default 5%). Ignored when totalExpenses <= 0.
    ///   - changeThresholdPercent: |%change| must exceed this to qualify (default 30).
    static func build(
        current: [CategorySpending],
        previous: [CategorySpending],
        totalExpenses: Decimal,
        materialityPercent: Double = 5.0,
        changeThresholdPercent: Double = 30.0
    ) -> SpendingAnomalySnapshot {
        let prevByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0.amount) })
        let floor = (totalExpenses as NSDecimalNumber).doubleValue * (materialityPercent / 100.0)

        let anomalies: [CategoryAnomaly] = current.compactMap { entry in
            let cur = (entry.amount as NSDecimalNumber).doubleValue
            guard totalExpenses <= 0 || cur >= floor else { return nil }
            let prevValue = prevByID[entry.id] ?? 0
            let prev = (prevValue as NSDecimalNumber).doubleValue
            let pct: Double
            if prev > 0 {
                pct = ((cur - prev) / prev) * 100
            } else if cur > 0 {
                pct = 100   // genuinely new spending
            } else {
                return nil
            }
            guard abs(pct) >= changeThresholdPercent else { return nil }
            return CategoryAnomaly(
                id: entry.id,
                categoryName: entry.category.name,
                current: entry.amount,
                previous: prevByID[entry.id] ?? 0,
                percentChange: pct
            )
        }

        let sorted = anomalies.sorted { abs($0.percentChange) > abs($1.percentChange) }
        let strongest = sorted.first
        return SpendingAnomalySnapshot(
            strongest: strongest,
            others: Array(sorted.dropFirst().prefix(2)),
            emptyReason: strongest == nil ? .calculatedNothingQualified : nil
        )
    }
}

// MARK: Net worth delta helpers

/// Pure helpers for the available-net-worth delta (refinement #2). The hero is
/// Available Net Worth, so the delta must come from the available series — not
/// the total series. Returns nil when a delta can't be computed (< 2 points).
enum NetWorthDeltaBuilder {
    struct Delta: Hashable {
        let absolute: Decimal
        let percent: Double?      // nil when previous was zero
    }

    static func delta(series: [NetWorthPoint]) -> Delta? {
        guard let first = series.first, let last = series.last, first.month != last.month else {
            return nil
        }
        let absolute = last.balance - first.balance
        let percent: Double?
        if first.balance != 0 {
            let ratio = ((absolute / first.balance) as NSDecimalNumber).doubleValue * 100
            percent = ratio
        } else {
            percent = nil
        }
        return Delta(absolute: absolute, percent: percent)
    }
}
