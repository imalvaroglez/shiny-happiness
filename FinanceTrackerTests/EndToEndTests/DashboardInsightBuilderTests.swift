import Testing
import Foundation
@testable import FinanceTracker

/// Pure-logic tests for the redesigned dashboard's Insight builders, net-worth
/// delta, and period-label semantics. No ModelContext / @MainActor — these
/// exercise value types only, so they run safely in their own suite.
@Suite("Dashboard Insight Builders")
struct DashboardInsightBuilderTests {

    // MARK: - Credit Card Pace

    @Test("Pace projection scales daily average to month length")
    func paceProjectionScalesDailyAverage() {
        // 10 days into a 30-day month, $3,000 spent → $300/day → $9,000 projected.
        let pace = CardPaceBuilder.build(
            priorMonthlyCharges: [9_000, 9_000, 9_000],
            spentToDate: 3_000,
            dayOfMonth: 10,
            daysInMonth: 30
        )
        #expect(pace.dailyAverage == 300)
        #expect(pace.projectedMonthEnd == 9_000)
        #expect(pace.status == .calm)   // projected == baseline
    }

    @Test("Pace is critical when projected exceeds 130% of baseline")
    func paceCriticalAbove130Percent() {
        // Baseline 9,000/month. Day 10, $5,000 spent → $500/day → $15,000 projected (167%).
        let pace = CardPaceBuilder.build(
            priorMonthlyCharges: [9_000, 9_000, 9_000],
            spentToDate: 5_000,
            dayOfMonth: 10,
            daysInMonth: 30
        )
        #expect(pace.projectedMonthEnd == 15_000)
        #expect(pace.status == .critical)
    }

    @Test("Pace is watch between 100% and 130% of baseline")
    func paceWatchBetween100And130() {
        // Baseline 10,000. Day 15 (half month), $6,000 spent → $400/day → $12,000 (120%).
        let pace = CardPaceBuilder.build(
            priorMonthlyCharges: [10_000],
            spentToDate: 6_000,
            dayOfMonth: 15,
            daysInMonth: 30
        )
        #expect(pace.status == .watch)
    }

    @Test("Pace baseline degrades gracefully with one prior month")
    func paceDegradesToOneMonth() {
        // Only one prior month — baseline still usable (refinement #3).
        let pace = CardPaceBuilder.build(
            priorMonthlyCharges: [12_000],
            spentToDate: 4_000,
            dayOfMonth: 10,
            daysInMonth: 30
        )
        #expect(pace.hasHistory)
        #expect(pace.baselineAverage == 12_000)
        #expect(pace.status != .insufficientHistory)
    }

    @Test("Pace reports insufficient history with zero usable prior months")
    func paceInsufficientHistory() {
        let pace = CardPaceBuilder.build(
            priorMonthlyCharges: [],
            spentToDate: 4_000,
            dayOfMonth: 10,
            daysInMonth: 30
        )
        #expect(!pace.hasHistory)
        #expect(pace.status == .insufficientHistory)
    }

    // MARK: - Upcoming Payments

    @Test("Upcoming payments prefer no-interest amount over minimum")
    func upcomingPaymentsPreferNoInterest() {
        let today = Date(timeIntervalSince1970: 1_800_000_000)   // fixed
        let calendar = Calendar(identifier: .gregorian)
        let inFiveDays = calendar.date(byAdding: .day, value: 5, to: today)!
        let due = [
            UpcomingPayment(id: UUID(), institution: "Card A",
                            noInterestAmount: 24_600, minimumAmount: 18_200, dueDate: inFiveDays),
        ]
        let snap = UpcomingPaymentsBuilder.build(due: due, today: today, calendar: calendar)
        #expect(snap.totalPrimary == 24_600)          // no-interest, not minimum
        #expect(snap.due.first?.hasNoInterest ?? false)
        #expect(snap.status == .watch)                // 5 days out → watch
    }

    @Test("Upcoming payments fall back to minimum when no-interest absent")
    func upcomingPaymentsFallbackToMinimum() {
        let today = Date(timeIntervalSince1970: 1_800_000_000)
        let calendar = Calendar(identifier: .gregorian)
        let inTwoDays = calendar.date(byAdding: .day, value: 2, to: today)!
        let due = [
            UpcomingPayment(id: UUID(), institution: "Card B",
                            noInterestAmount: nil, minimumAmount: 5_000, dueDate: inTwoDays),
        ]
        let snap = UpcomingPaymentsBuilder.build(due: due, today: today, calendar: calendar)
        #expect(snap.totalPrimary == 5_000)
        #expect(snap.status == .critical)             // ≤3 days → critical
    }

    @Test("Upcoming payments are calm when nothing is due in window")
    func upcomingPaymentsCalmWhenNoneDue() {
        let today = Date(timeIntervalSince1970: 1_800_000_000)
        let calendar = Calendar(identifier: .gregorian)
        let far = calendar.date(byAdding: .day, value: 40, to: today)!
        let due = [
            UpcomingPayment(id: UUID(), institution: "Card C",
                            noInterestAmount: 1_000, minimumAmount: 500, dueDate: far),
        ]
        let snap = UpcomingPaymentsBuilder.build(due: due, today: today, calendar: calendar)
        #expect(snap.due.isEmpty)
        #expect(snap.totalPrimary == 0)
        #expect(snap.status == .calm)
    }

    // MARK: - Spending Anomaly

    @Test("Anomaly flags a category up materially vs previous period")
    func anomalyFlagsMaterialIncrease() {
        let cat = makeCategory("Transport")
        let current = [CategorySpending(category: cat, amount: 132)]   // +32% over 100
        let previous = [CategorySpending(category: cat, amount: 100)]
        // totalExpenses large enough that 132 clears the 5% floor.
        let snap = SpendingAnomalyBuilder.build(
            current: current, previous: previous, totalExpenses: 1_000
        )
        #expect(snap.strongest != nil)
        #expect(abs(snap.strongest!.percentChange - 32) < 0.5)
        #expect(!snap.isCalm)
    }

    @Test("Anomaly is calm below the change threshold")
    func anomalyCalmBelowThreshold() {
        let cat = makeCategory("Food")
        let current = [CategorySpending(category: cat, amount: 110)]   // +10%
        let previous = [CategorySpending(category: cat, amount: 100)]
        let snap = SpendingAnomalyBuilder.build(
            current: current, previous: previous, totalExpenses: 1_000
        )
        #expect(snap.isCalm)
        #expect(!snap.wasSkipped)                      // calculated, not skipped
        #expect(snap.emptyReason == .calculatedNothingQualified)
    }

    @Test("Skipped anomaly is distinct from calculated-clean")
    func anomalySkippedIsNotClean() {
        let snap = SpendingAnomalySnapshot.skippedForRange
        #expect(snap.isCalm)
        #expect(snap.wasSkipped)                       // honestly skipped
        #expect(snap.emptyReason == .skippedForRange)
    }

    @Test("Anomaly ignores tiny categories below the materiality floor")
    func anomalyIgnoresImmaterialCategory() {
        let cat = makeCategory("Tiny")
        // +100% but only $2 of $1,000 spend (0.2% < 5% floor).
        let current = [CategorySpending(category: cat, amount: 2)]
        let previous = [CategorySpending(category: cat, amount: 1)]
        let snap = SpendingAnomalyBuilder.build(
            current: current, previous: previous, totalExpenses: 1_000
        )
        #expect(snap.isCalm)
    }

    // MARK: - Net worth delta (available-NW source alignment)

    @Test("Net worth delta is computed from the provided series")
    func netWorthDeltaFromSeries() {
        let series = [
            NetWorthPoint(month: Date(timeIntervalSince1970: 0), balance: 100_000),
            NetWorthPoint(month: Date(timeIntervalSince1970: 86_400), balance: 124_350),
        ]
        let delta = NetWorthDeltaBuilder.delta(series: series)
        #expect(delta?.absolute == 24_350)
        // +24.35%
        #expect(delta?.percent != nil)
        #expect(abs(delta!.percent! - 24.35) < 0.1)
    }

    @Test("Net worth delta is nil for a single-point series")
    func netWorthDeltaNilForSinglePoint() {
        let series = [NetWorthPoint(month: Date(), balance: 100)]
        #expect(NetWorthDeltaBuilder.delta(series: series) == nil)
    }

    // MARK: - Period / as-of label semantics (refinement #7)

    @Test("As-of label renders the snapshot date")
    func asOfLabelRendersDate() {
        let date = Date(timeIntervalSince1970: 0)
        let label = DashboardPeriodLabel.asOf(date)
        #expect(label.text.hasPrefix("As of "))
    }

    @Test("Period label passes through the range text")
    func periodLabelPassThrough() {
        let label = DashboardPeriodLabel.period("Last 30 days")
        #expect(label.text == "Last 30 days")
    }

    @Test("Calendar-month-to-date label never reads 'Last 30 days'")
    func calendarMonthLabelNeverSaysLast30Days() {
        let label = DashboardPeriodLabel.calendarMonthToDate("Jul 1 – today")
        #expect(label.text == "Jul 1 – today")
        #expect(!label.text.contains("Last 30 days"))
    }

    // MARK: - "Other" warning threshold (refinement #5, exact 40%)

    @Test("Other warning logic triggers at or above 40 percent")
    func otherWarningThresholdLogic() {
        // Top 5 categories sum to 60% → Other = 40% → triggers.
        let total = Decimal(100)
        let topN = Decimal(60)
        let otherPercent = ((max(total - topN, 0) / total) as NSDecimalNumber).doubleValue * 100
        #expect(otherPercent >= 40)

        // Top 5 sum to 65% → Other = 35% → does not trigger.
        let topN2 = Decimal(65)
        let otherPercent2 = ((max(total - topN2, 0) / total) as NSDecimalNumber).doubleValue * 100
        #expect(otherPercent2 < 40)
    }

    // MARK: - Helpers

    private func makeCategory(_ name: String) -> FinanceTracker.Category {
        FinanceTracker.Category(name: name, kind: .expense)
    }
}
