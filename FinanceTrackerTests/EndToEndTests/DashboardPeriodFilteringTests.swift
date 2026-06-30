import Testing
import Foundation
import SwiftData
@testable import FinanceTracker

@Suite("Dashboard Period Filtering")
@MainActor
struct DashboardPeriodFilteringTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            Account.self, AccountBalanceSnapshot.self, Transaction.self,
            Statement.self,
            FinanceTracker.Category.self,
            CategoryRule.self,
            InstallmentPlan.self,
            PendingImport.self,
            SignRecoveryHint.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    @Test("Month range includes current month only and uses daily buckets")
    func monthRangeUsesCurrentMonthDailyBuckets() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let calendar = Calendar(identifier: .gregorian)
        let now = Date.now
        let account = Account(institution: "Test Bank", type: .checking)
        context.insert(account)
        context.insert(Transaction(account: account, postedAt: now, amount: 100, descriptionRaw: "Current month income"))
        context.insert(Transaction(
            account: account,
            postedAt: calendar.date(byAdding: .month, value: -1, to: now)!,
            amount: 900,
            descriptionRaw: "Previous month income"
        ))
        try context.save()

        let viewModel = DashboardViewModel()
        viewModel.setPeriod(.month, now: now)
        viewModel.configure(context: context)

        guard case .consolidated(let snap) = viewModel.snapshot else {
            Issue.record("Expected consolidated snapshot"); return
        }

        let expectedDays = (calendar.dateComponents([.day], from: calendar.startOfDay(for: viewModel.dateRange.start), to: now).day ?? 0) + 1
        #expect(snap.totalIncome == 100)
        #expect(snap.period.bucket == .day)
        #expect(snap.monthlyCashFlow.count == expectedDays)
    }

    @Test("Quarter and year ranges include only their current calendar windows")
    func quarterAndYearRangesUseCurrentCalendarWindows() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let calendar = Calendar(identifier: .gregorian)
        let now = Date.now
        let account = Account(institution: "Test Bank", type: .checking)
        context.insert(account)

        context.insert(Transaction(account: account, postedAt: now, amount: 100, descriptionRaw: "Current window income"))
        let previousQuarterDate = calendar.date(byAdding: .month, value: -4, to: now)!
        context.insert(Transaction(
            account: account,
            postedAt: previousQuarterDate,
            amount: 400,
            descriptionRaw: "Previous quarter income"
        ))
        context.insert(Transaction(
            account: account,
            postedAt: calendar.date(byAdding: .year, value: -1, to: now)!,
            amount: 800,
            descriptionRaw: "Previous year income"
        ))
        try context.save()

        let quarterVM = DashboardViewModel()
        quarterVM.setPeriod(.quarter, now: now)
        quarterVM.configure(context: context)

        guard case .consolidated(let quarter) = quarterVM.snapshot else {
            Issue.record("Expected quarter snapshot"); return
        }
        #expect(quarter.totalIncome == 100)
        #expect(quarter.period.bucket == .month)

        let yearVM = DashboardViewModel()
        yearVM.setPeriod(.year, now: now)
        yearVM.configure(context: context)

        guard case .consolidated(let year) = yearVM.snapshot else {
            Issue.record("Expected year snapshot"); return
        }
        let previousQuarterIsCurrentYear = calendar.component(.year, from: previousQuarterDate) == calendar.component(.year, from: now)
        #expect(year.totalIncome == (previousQuarterIsCurrentYear ? 500 : 100))
        #expect(year.period.bucket == .month)
    }

    @Test("All range includes all non-future available data")
    func allRangeExcludesFutureData() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let now = Date.now
        let account = Account(institution: "Test Bank", type: .checking)
        context.insert(account)
        context.insert(Transaction(account: account, postedAt: now.addingTimeInterval(-30 * 86400), amount: 100, descriptionRaw: "Past income"))
        context.insert(Transaction(account: account, postedAt: now.addingTimeInterval(30 * 86400), amount: 900, descriptionRaw: "Future income"))
        try context.save()

        let viewModel = DashboardViewModel()
        viewModel.setPeriod(.all, now: now)
        viewModel.configure(context: context)

        guard case .consolidated(let snap) = viewModel.snapshot else {
            Issue.record("Expected consolidated snapshot"); return
        }

        #expect(snap.totalIncome == 100)
        #expect(snap.period.dateRange.start <= now.addingTimeInterval(-30 * 86400))
        #expect(snap.period.dateRange.end <= Date.now)
    }

    @Test("Income and expenses exclude transfers and credit-card payments")
    func cashFlowExcludesTransfersAndCardPayments() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let now = Date.now
        let account = Account(institution: "Test Bank", type: .checking)
        let transfer = FinanceTracker.Category(name: "Transfer", kind: .transfer)
        let cardPayment = FinanceTracker.Category(name: "Card Payment", kind: .creditCardPayment)
        context.insert(account)
        context.insert(transfer)
        context.insert(cardPayment)
        context.insert(Transaction(account: account, postedAt: now, amount: 1_000, descriptionRaw: "Transfer in", category: transfer))
        context.insert(Transaction(account: account, postedAt: now, amount: -700, descriptionRaw: "Card payment", category: cardPayment))
        context.insert(Transaction(account: account, postedAt: now, amount: 300, descriptionRaw: "Salary"))
        context.insert(Transaction(account: account, postedAt: now, amount: -50, descriptionRaw: "Coffee"))
        try context.save()

        let viewModel = DashboardViewModel()
        viewModel.setPeriod(.month, now: now)
        viewModel.configure(context: context)

        guard case .consolidated(let snap) = viewModel.snapshot else {
            Issue.record("Expected consolidated snapshot"); return
        }

        #expect(snap.totalIncome == 300)
        #expect(snap.totalExpenses == -50)
    }

    @Test("Net worth is point-in-time balance and card matches last chart point")
    func netWorthUsesBalanceAsOfPeriodEnd() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let calendar = Calendar(identifier: .gregorian)
        let account = Account(institution: "Test Bank", type: .checking)
        context.insert(account)

        let jan31 = date(year: 2026, month: 1, day: 31)
        context.insert(Statement(
            account: account,
            periodStart: date(year: 2026, month: 1, day: 1),
            periodEnd: jan31,
            sourceFileHash: "jan",
            closingBalance: 1_000
        ))
        context.insert(Transaction(
            account: account,
            postedAt: date(year: 2026, month: 2, day: 10),
            amount: 500,
            descriptionRaw: "Manual correction",
            source: .manual
        ))
        context.insert(Transaction(
            account: account,
            postedAt: date(year: 2026, month: 3, day: 10),
            amount: 200,
            descriptionRaw: "After period",
            source: .manual
        ))
        try context.save()

        let viewModel = DashboardViewModel()
        viewModel.setPeriod(.custom, customRange: DateRange(start: jan31, end: date(year: 2026, month: 2, day: 28)), now: date(year: 2026, month: 3, day: 1))
        viewModel.configure(context: context)

        guard case .consolidated(let snap) = viewModel.snapshot else {
            Issue.record("Expected consolidated snapshot"); return
        }

        #expect(snap.netWorth == 1_500)
        #expect(snap.netWorth != snap.totalIncome)
        #expect(snap.netWorthOverTime.last?.balance == snap.netWorth)
        #expect(snap.netWorthOverTime.last?.month == snap.period.effectiveNetWorthDate)
        #expect(snap.netWorthOverTime.allSatisfy { $0.month <= calendar.endOfDay(for: date(year: 2026, month: 2, day: 28)) })
    }

    @Test("Cash flow and net worth chart buckets change between period selections")
    func chartBucketsChangeBetweenPeriods() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let calendar = Calendar(identifier: .gregorian)
        let now = Date.now
        let account = Account(institution: "Test Bank", type: .checking)
        context.insert(account)
        context.insert(Statement(
            account: account,
            periodStart: calendar.date(byAdding: .year, value: -1, to: now)!,
            periodEnd: calendar.date(byAdding: .year, value: -1, to: now)!,
            sourceFileHash: "prior-year",
            closingBalance: 500
        ))
        context.insert(Statement(
            account: account,
            periodStart: calendar.date(byAdding: .month, value: -1, to: now)!,
            periodEnd: calendar.date(byAdding: .month, value: -1, to: now)!,
            sourceFileHash: "prior-month",
            closingBalance: 1_000
        ))
        context.insert(Transaction(account: account, postedAt: now, amount: 100, descriptionRaw: "Current income", source: .manual))
        try context.save()

        let month = snapshot(for: .month, now: now, context: context)
        let quarter = snapshot(for: .quarter, now: now, context: context)
        let year = snapshot(for: .year, now: now, context: context)
        let all = snapshot(for: .all, now: now, context: context)

        #expect(month?.period.bucket == .day)
        #expect(quarter?.period.bucket == .month)
        #expect(year?.period.bucket == .month)
        #expect(all?.netWorthOverTime.count != month?.netWorthOverTime.count)
        #expect(all?.period.dateRange.start != year?.period.dateRange.start)
        #expect(month?.monthlyCashFlow.count != quarter?.monthlyCashFlow.count)
    }

    @Test("Refreshing after period changes recomputes snapshot totals")
    func refreshRecomputesWhenPeriodChanges() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(institution: "Test Bank", type: .checking)
        context.insert(account)
        context.insert(Transaction(account: account, postedAt: date(year: 2026, month: 5, day: 5), amount: 100, descriptionRaw: "May income"))
        context.insert(Transaction(account: account, postedAt: date(year: 2026, month: 6, day: 5), amount: 300, descriptionRaw: "June income"))
        try context.save()

        let viewModel = DashboardViewModel()
        viewModel.setPeriod(.custom, customRange: DateRange(start: date(year: 2026, month: 5, day: 1), end: date(year: 2026, month: 5, day: 31)), now: date(year: 2026, month: 6, day: 10))
        viewModel.configure(context: context)

        guard case .consolidated(let may) = viewModel.snapshot else {
            Issue.record("Expected May snapshot"); return
        }
        #expect(may.totalIncome == 100)

        viewModel.setPeriod(.custom, customRange: DateRange(start: date(year: 2026, month: 6, day: 1), end: date(year: 2026, month: 6, day: 30)), now: date(year: 2026, month: 6, day: 10))
        viewModel.refresh()

        guard case .consolidated(let june) = viewModel.snapshot else {
            Issue.record("Expected June snapshot"); return
        }
        #expect(june.totalIncome == 300)
    }

    @Test("Latest snapshot metrics stay independent from selected period")
    func latestSnapshotMetricsIgnoreSelectedPeriod() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(institution: "Test Bank", type: .checking, openedAt: date(year: 2026, month: 1, day: 1))
        context.insert(account)
        context.insert(AccountBalanceSnapshot(account: account, date: date(year: 2026, month: 5, day: 1), amount: 1_000, kind: .manualOpening))
        context.insert(Transaction(account: account, postedAt: date(year: 2026, month: 6, day: 5), amount: 500, descriptionRaw: "June income", source: .manual))
        try context.save()

        let viewModel = DashboardViewModel()
        viewModel.setPeriod(
            .custom,
            customRange: DateRange(start: date(year: 2026, month: 5, day: 1), end: date(year: 2026, month: 5, day: 31)),
            now: date(year: 2026, month: 6, day: 10)
        )
        viewModel.configure(context: context)

        guard case .consolidated(let may) = viewModel.snapshot else {
            Issue.record("Expected May snapshot"); return
        }
        #expect(may.netWorth == 1_000)
        #expect(may.latestNetWorth == 1_500)
        #expect(may.snapshotAsOfDate == date(year: 2026, month: 6, day: 5))
        #expect(may.netWorthComposition.availableNetWorth == 1_500)

        viewModel.setPeriod(
            .custom,
            customRange: DateRange(start: date(year: 2026, month: 6, day: 1), end: date(year: 2026, month: 6, day: 30)),
            now: date(year: 2026, month: 6, day: 10)
        )
        viewModel.refresh()

        guard case .consolidated(let june) = viewModel.snapshot else {
            Issue.record("Expected June snapshot"); return
        }
        #expect(june.netWorth == 1_500)
        #expect(june.latestNetWorth == may.latestNetWorth)
        #expect(june.netWorthComposition.availableNetWorth == may.netWorthComposition.availableNetWorth)
    }

    @Test("Historical net worth breakdown uses period-end balances and excludes later changes")
    func historicalNetWorthBreakdownUsesPeriodEndBalances() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let checking = Account(institution: "Test Bank", type: .checking, nickname: "Checking")
        let savings = Account(institution: "Savings Bank", type: .savings, nickname: "Savings")
        let noHistory = Account(institution: "New Bank", type: .checking, nickname: "No History")
        context.insert(checking)
        context.insert(savings)
        context.insert(noHistory)

        context.insert(Statement(
            account: checking,
            periodStart: date(year: 2026, month: 4, day: 1),
            periodEnd: date(year: 2026, month: 4, day: 30),
            sourceFileHash: "checking-apr",
            closingBalance: 1_000
        ))
        context.insert(Transaction(
            account: checking,
            postedAt: date(year: 2026, month: 5, day: 10),
            amount: 100,
            descriptionRaw: "May activity",
            source: .manual
        ))
        context.insert(Transaction(
            account: checking,
            postedAt: date(year: 2026, month: 6, day: 5),
            amount: 900,
            descriptionRaw: "June activity",
            source: .manual
        ))
        context.insert(Statement(
            account: savings,
            periodStart: date(year: 2026, month: 5, day: 1),
            periodEnd: date(year: 2026, month: 5, day: 31),
            sourceFileHash: "savings-may",
            closingBalance: 500
        ))
        context.insert(Transaction(
            account: savings,
            postedAt: date(year: 2026, month: 6, day: 2),
            amount: 50,
            descriptionRaw: "June savings activity",
            source: .manual
        ))
        try context.save()

        let viewModel = DashboardViewModel()
        viewModel.setPeriod(
            .custom,
            customRange: DateRange(start: date(year: 2026, month: 5, day: 1), end: date(year: 2026, month: 5, day: 31)),
            now: date(year: 2026, month: 6, day: 11)
        )
        viewModel.configure(context: context)

        guard case .consolidated(let snap) = viewModel.snapshot else {
            Issue.record("Expected consolidated snapshot"); return
        }

        let calendar = Calendar(identifier: .gregorian)
        let asOf = calendar.dateComponents([.year, .month, .day], from: snap.period.effectiveNetWorthDate)
        #expect(asOf.year == 2026 && asOf.month == 5 && asOf.day == 31)
        #expect(snap.netWorth == 1_600)
        #expect(snap.netWorthOverTime.last?.balance == snap.netWorth)
        #expect(snap.netWorthOverTime.last?.month == snap.period.effectiveNetWorthDate)
        #expect(accountBreakdownTotal(snap.accountSummaries) == snap.netWorth)

        let checkingSummary = snap.accountSummaries.first { $0.displayName == "Checking" }
        #expect(checkingSummary?.latestBalance == 1_100)
        #expect(checkingSummary?.balanceSourceKind == .reconstructedBalance)
        #expect(checkingSummary?.balanceAsOf == snap.period.effectiveNetWorthDate)

        let savingsSummary = snap.accountSummaries.first { $0.displayName == "Savings" }
        #expect(savingsSummary?.latestBalance == 500)
        #expect(savingsSummary?.balanceSourceKind == .exactBalanceSnapshot)

        let noHistorySummary = snap.accountSummaries.first { $0.displayName == "No History" }
        #expect(noHistorySummary?.balanceSourceKind == .insufficientHistory)
        #expect(noHistorySummary?.latestBalance == 0)
    }

    @Test("Current month net worth breakdown uses today's effective date")
    func currentMonthNetWorthBreakdownUsesToday() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let now = date(year: 2026, month: 6, day: 11)
        let account = Account(institution: "Test Bank", type: .checking)
        context.insert(account)
        context.insert(Statement(
            account: account,
            periodStart: date(year: 2026, month: 5, day: 1),
            periodEnd: date(year: 2026, month: 5, day: 31),
            sourceFileHash: "may",
            closingBalance: 1_000
        ))
        context.insert(Transaction(
            account: account,
            postedAt: date(year: 2026, month: 6, day: 5),
            amount: -200,
            descriptionRaw: "June change",
            source: .manual
        ))
        try context.save()

        let viewModel = DashboardViewModel()
        viewModel.setPeriod(.month, now: now)
        viewModel.configure(context: context)

        guard case .consolidated(let snap) = viewModel.snapshot else {
            Issue.record("Expected consolidated snapshot"); return
        }

        let calendar = Calendar(identifier: .gregorian)
        let asOf = calendar.dateComponents([.year, .month, .day], from: snap.period.effectiveNetWorthDate)
        #expect(asOf.year == 2026 && asOf.month == 6 && asOf.day == 11)
        #expect(snap.netWorth == 800)
        #expect(snap.netWorthOverTime.last?.balance == snap.netWorth)
        #expect(snap.netWorthOverTime.last?.month == snap.period.effectiveNetWorthDate)
        #expect(accountBreakdownTotal(snap.accountSummaries) == snap.netWorth)
        #expect(snap.accountSummaries.first?.balanceSourceKind == .reconstructedBalance)
    }

    @Test("Chart rendering metadata pads domains and centers quarter bars")
    func chartRenderingMetadataPadsAndCentersQuarterBuckets() {
        let calendar = Calendar(identifier: .gregorian)
        let now = date(year: 2026, month: 6, day: 11)
        let range = DashboardPeriodKind.quarter.resolvedRange(now: now)
        let period = DashboardPeriodResolver.context(kind: .quarter, requestedRange: range, dataRange: nil, now: now)

        #expect(period.dateRange.start == date(year: 2026, month: 4, day: 1))
        #expect(period.dateRange.end == now)
        #expect(period.plotDomain.lowerBound < period.dateRange.start)
        #expect(period.plotDomain.upperBound > period.dateRange.end)
        #expect(period.dateRange.start == range.start)
        #expect(period.dateRange.end == range.end)

        let intervals = period.intervals(calendar: calendar)
        #expect(intervals.count == 3)
        guard let april = intervals.first else {
            Issue.record("Expected an April interval"); return
        }
        let aprilCenter = april.center(calendar: calendar)
        let aprilBarX = period.barXValue(forBucketStart: april.bucketStart, calendar: calendar)
        #expect(april.bucketStart == date(year: 2026, month: 4, day: 1))
        #expect(aprilCenter > april.start)
        #expect(aprilCenter < april.end)
        #expect(aprilBarX == aprilCenter)
        #expect(aprilBarX > april.start)
        #expect(aprilBarX < april.end)
        #expect(period.axisMarkValues(calendar: calendar).count == 3)
        #expect(period.barWidthPoints(forVisibleBucketCount: intervals.count, calendar: calendar) == 30)
    }

    @Test("Month buckets and rendered chart dates stay within the selected period")
    func monthBucketsAndRenderedDatesStayInsideSelectedPeriod() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let now = date(year: 2026, month: 6, day: 11)
        let account = Account(institution: "Test Bank", type: .checking)
        context.insert(account)
        context.insert(Statement(
            account: account,
            periodStart: date(year: 2026, month: 5, day: 1),
            periodEnd: date(year: 2026, month: 5, day: 31),
            sourceFileHash: "may-balance",
            closingBalance: 1_000
        ))
        context.insert(Transaction(
            account: account,
            postedAt: date(year: 2026, month: 6, day: 5),
            amount: 100,
            descriptionRaw: "June income",
            source: .manual
        ))
        try context.save()

        let viewModel = DashboardViewModel()
        viewModel.setPeriod(.month, now: now)
        viewModel.configure(context: context)

        guard case .consolidated(let snap) = viewModel.snapshot else {
            Issue.record("Expected consolidated snapshot"); return
        }

        #expect(snap.monthlyCashFlow.allSatisfy { $0.month >= snap.period.dateRange.start && $0.month <= snap.period.dateRange.end })
        for entry in snap.monthlyCashFlow {
            let barX = snap.period.barXValue(forBucketStart: entry.month)
            #expect(barX >= snap.period.dateRange.start)
            #expect(barX <= snap.period.dateRange.end)
        }
        #expect(snap.netWorthOverTime.allSatisfy { $0.month >= snap.period.dateRange.start && $0.month <= snap.period.dateRange.end })
        #expect(snap.netWorthOverTime.last?.month == snap.period.effectiveNetWorthDate)
    }

    @Test("Dense chart buckets use narrower bars than sparse buckets")
    func denseChartBucketsUseNarrowerBars() {
        let now = date(year: 2026, month: 6, day: 11)
        let monthRange = DashboardPeriodKind.month.resolvedRange(now: now)
        let monthPeriod = DashboardPeriodResolver.context(kind: .month, requestedRange: monthRange, dataRange: nil, now: now)
        let quarterRange = DashboardPeriodKind.quarter.resolvedRange(now: now)
        let quarterPeriod = DashboardPeriodResolver.context(kind: .quarter, requestedRange: quarterRange, dataRange: nil, now: now)

        #expect(quarterPeriod.barWidthPoints(forVisibleBucketCount: 3) > quarterPeriod.barWidthPoints(forVisibleBucketCount: 12))
        #expect(monthPeriod.barWidthPoints(forVisibleBucketCount: 120) < monthPeriod.barWidthPoints(forVisibleBucketCount: 11))
        #expect(monthPeriod.barWidthPoints(forVisibleBucketCount: 11) < quarterPeriod.barWidthPoints(forVisibleBucketCount: 3))
    }

    @Test("All chart rendering domain trims to populated buckets")
    func allChartRenderingDomainTrimsToPopulatedBuckets() {
        let calendar = Calendar(identifier: .gregorian)
        let now = date(year: 2026, month: 6, day: 11)
        let dataRange = DateRange(start: date(year: 2026, month: 1, day: 1), end: now)
        let requestedRange = DashboardPeriodKind.all.resolvedRange(now: now)
        let period = DashboardPeriodResolver.context(kind: .all, requestedRange: requestedRange, dataRange: dataRange, now: now)
        let april = date(year: 2026, month: 4, day: 1)
        let may = date(year: 2026, month: 5, day: 1)
        let june = date(year: 2026, month: 6, day: 1)

        let trimmedDomain = period.plotDomain(forPopulatedBucketStarts: [april, may, june], calendar: calendar)
        let firstBarX = period.barXValue(forBucketStart: april, calendar: calendar)
        let daysFromDomainToFirstBar = calendar.dateComponents([.day], from: trimmedDomain.lowerBound, to: firstBarX).day ?? .max

        #expect(period.plotDomain.lowerBound < date(year: 2026, month: 1, day: 1))
        #expect(trimmedDomain.lowerBound > date(year: 2026, month: 2, day: 15))
        #expect(daysFromDomainToFirstBar <= 31)
        #expect(trimmedDomain.upperBound > period.barXValue(forBucketStart: june, calendar: calendar))
    }

    @Test("Empty populated bucket domain falls back to full plot domain")
    func emptyPopulatedBucketDomainFallsBackToFullPlotDomain() {
        let now = date(year: 2026, month: 6, day: 11)
        let range = DashboardPeriodKind.all.resolvedRange(now: now)
        let period = DashboardPeriodResolver.context(
            kind: .all,
            requestedRange: range,
            dataRange: DateRange(start: date(year: 2026, month: 1, day: 1), end: now),
            now: now
        )

        let fallbackDomain = period.plotDomain(forPopulatedBucketStarts: [])
        #expect(fallbackDomain.lowerBound == period.plotDomain.lowerBound)
        #expect(fallbackDomain.upperBound == period.plotDomain.upperBound)
    }

    @Test("All grouped period bars skip inactive buckets")
    func allGroupedPeriodBarsSkipInactiveBuckets() {
        let now = date(year: 2026, month: 6, day: 11)
        let period = DashboardPeriodResolver.context(
            kind: .all,
            requestedRange: DashboardPeriodKind.all.resolvedRange(now: now),
            dataRange: DateRange(start: date(year: 2026, month: 1, day: 1), end: now),
            now: now
        )

        let groups = DashboardPeriodBarGroupBuilder.groups(
            period: period,
            buckets: [
                displayBucket(year: 2026, month: 1, first: 0, second: 0),
                displayBucket(year: 2026, month: 2, first: 0, second: 0),
                displayBucket(year: 2026, month: 3, first: 0, second: 0),
                displayBucket(year: 2026, month: 4, first: 114_872.17, second: 34_575.72),
                displayBucket(year: 2026, month: 5, first: 18_200, second: 12_400),
                displayBucket(year: 2026, month: 6, first: 902.82, second: 12_649.92)
            ]
        )

        #expect(groups.map(\.label) == ["Apr", "May", "Jun"])
        #expect(groups.map(\.bucketStart) == [
            date(year: 2026, month: 4, day: 1),
            date(year: 2026, month: 5, day: 1),
            date(year: 2026, month: 6, day: 1)
        ])
        #expect(groups.allSatisfy { !$0.isPlaceholder })
    }

    @Test("Bounded grouped period bars trim edges and preserve internal inactivity")
    func boundedGroupedPeriodBarsTrimEdgesAndPreserveInternalInactiveBuckets() {
        let now = date(year: 2026, month: 6, day: 11)
        let period = DashboardPeriodResolver.context(
            kind: .year,
            requestedRange: DashboardPeriodKind.year.resolvedRange(now: now),
            dataRange: nil,
            now: now
        )

        let groups = DashboardPeriodBarGroupBuilder.groups(
            period: period,
            buckets: [
                displayBucket(year: 2026, month: 1, first: 0, second: 0),
                displayBucket(year: 2026, month: 2, first: 1_000, second: 500),
                displayBucket(year: 2026, month: 3, first: 0, second: 0),
                displayBucket(year: 2026, month: 4, first: 0, second: 250),
                displayBucket(year: 2026, month: 5, first: 0, second: 0),
                displayBucket(year: 2026, month: 6, first: 0, second: 0)
            ]
        )

        #expect(groups.map(\.label) == ["Feb", "Mar", "Apr"])
        #expect(groups.map(\.isPlaceholder) == [false, true, false])
        #expect(groups.map(\.order) == [0, 1, 2])
    }

    @Test("Grouped period layout keeps sparse charts compact")
    func groupedPeriodLayoutKeepsSparseChartsCompact() {
        let sparse = DashboardGroupedBarLayout(groupCount: 3, availableWidth: 1_100, showsFirstSeries: true, showsSecondSeries: true)
        let fullYear = DashboardGroupedBarLayout(groupCount: 12, availableWidth: 1_100, showsFirstSeries: true, showsSecondSeries: true)

        #expect(sparse.contentWidth <= 220)
        #expect(sparse.barWidth >= 18 && sparse.barWidth <= 24)
        #expect(sparse.intraGroupSpacing <= 6)
        #expect(sparse.groupSpacing <= 36)
        #expect(fullYear.contentWidth > sparse.contentWidth)
        #expect(sparse.barWidth > fullYear.barWidth)
    }

    @Test("Dashboard compact currency labels avoid scientific notation")
    func dashboardCompactCurrencyLabelsAvoidScientificNotation() {
        #expect(dashboardCompactAmount(0, code: "MXN") == "$0")
        #expect(dashboardCompactAmount(50_000, code: "MXN") == "$50K")
        #expect(dashboardCompactAmount(123_400, code: "MXN") == "$123K")
        #expect(dashboardCompactAmount(2_100_000, code: "MXN") == "$2.1M")
        #expect(!dashboardCompactAmount(4_000_000, code: "MXN").contains("E"))
    }

    @Test("Positive net worth chart domain does not go negative")
    func positiveNetWorthChartDomainDoesNotGoNegative() {
        let points = [
            NetWorthPoint(month: date(year: 2026, month: 4, day: 30), balance: 240_000),
            NetWorthPoint(month: date(year: 2026, month: 5, day: 31), balance: 310_000),
            NetWorthPoint(month: date(year: 2026, month: 6, day: 11), balance: 3_850_000)
        ]

        let domain = DashboardBalanceChartScale.domain(for: points)

        #expect(domain.lowerBound == 0)
        #expect(domain.upperBound > 3_850_000)
    }

    @Test("Negative net worth chart domain includes negative values")
    func negativeNetWorthChartDomainIncludesNegativeValues() {
        let points = [
            NetWorthPoint(month: date(year: 2026, month: 4, day: 30), balance: -95_000),
            NetWorthPoint(month: date(year: 2026, month: 5, day: 31), balance: -40_000),
            NetWorthPoint(month: date(year: 2026, month: 6, day: 11), balance: 12_000)
        ]

        let domain = DashboardBalanceChartScale.domain(for: points)

        #expect(domain.lowerBound < -95_000)
        #expect(domain.upperBound > 12_000)
    }

    @Test("Grouped period bars preserve display magnitudes and chronology")
    func groupedPeriodBarsPreserveDisplayMagnitudesAndChronology() {
        let now = date(year: 2026, month: 6, day: 11)
        let period = DashboardPeriodResolver.context(
            kind: .quarter,
            requestedRange: DashboardPeriodKind.quarter.resolvedRange(now: now),
            dataRange: nil,
            now: now
        )

        let groups = DashboardPeriodBarGroupBuilder.groups(
            period: period,
            buckets: [
                displayBucket(year: 2026, month: 6, first: 10, second: 3),
                displayBucket(year: 2026, month: 4, first: 5, second: 12),
                displayBucket(year: 2026, month: 5, first: 0, second: 0)
            ]
        )

        #expect(groups.map(\.bucketStart) == [
            date(year: 2026, month: 4, day: 1),
            date(year: 2026, month: 5, day: 1),
            date(year: 2026, month: 6, day: 1)
        ])
        #expect(groups[0].firstMagnitude == 5)
        #expect(groups[0].secondMagnitude == 12)
        #expect(groups[0].id == groups[0].bucketStart)
        #expect(groups[1].isPlaceholder)
    }

    @Test("Consolidated month cash flow uses the trend card")
    func consolidatedMonthCashFlowUsesTrendCard() {
        let now = date(year: 2026, month: 6, day: 11)
        let period = DashboardPeriodResolver.context(
            kind: .month,
            requestedRange: DashboardPeriodKind.month.resolvedRange(now: now),
            dataRange: nil,
            now: now
        )
        let quarter = DashboardPeriodResolver.context(
            kind: .quarter,
            requestedRange: DashboardPeriodKind.quarter.resolvedRange(now: now),
            dataRange: nil,
            now: now
        )

        #expect(DashboardCashFlowTrendBuilder.usesTrendCard(period: period))
        #expect(!DashboardCashFlowTrendBuilder.usesTrendCard(period: quarter))
    }

    @Test("Cash flow trend points carry daily net and cumulative net")
    func cashFlowTrendPointsCarryDailyNetAndCumulativeNet() {
        let points = DashboardCashFlowTrendBuilder.points(from: [
            MonthlyCashFlow(month: date(year: 2026, month: 6, day: 1), income: 100, expenses: -40),
            MonthlyCashFlow(month: date(year: 2026, month: 6, day: 2), income: 0, expenses: -20),
            MonthlyCashFlow(month: date(year: 2026, month: 6, day: 3), income: 10, expenses: 0),
        ])

        #expect(points.map(\.net) == [60, -20, 10])
        #expect(points.map(\.cumulativeNet) == [60, 40, 50])
    }

    @Test("Grouped period empty input renders no groups")
    func groupedPeriodEmptyInputRendersNoGroups() {
        let now = date(year: 2026, month: 6, day: 11)
        let period = DashboardPeriodResolver.context(
            kind: .month,
            requestedRange: DashboardPeriodKind.month.resolvedRange(now: now),
            dataRange: nil,
            now: now
        )

        let groups = DashboardPeriodBarGroupBuilder.groups(
            period: period,
            buckets: [
                displayBucket(year: 2026, month: 6, first: 0, second: 0)
            ]
        )

        #expect(groups.isEmpty)
    }

    @Test("Spending bars sort top categories and group the rest")
    func spendingBarsSortAndGroupOther() {
        let rows = DashboardSpendingBarBuilder.rows(from: [
            categorySpend("Furniture", 100),
            categorySpend("Maintenance", 90),
            categorySpend("Rent", 80),
            categorySpend("Events", 70),
            categorySpend("Food", 60),
            categorySpend("Coffee", 10),
            categorySpend("Books", 5),
        ])

        #expect(rows.map(\.name) == ["Furniture", "Maintenance", "Rent", "Events", "Food", "Other"])
        #expect(rows.last?.amount == 15)
        #expect(rows.last?.isOther == true)
        #expect(rows.first?.percentage.map { abs($0 - 24.096) < 0.01 } == true)
    }

    @Test("Dashboard account groups follow net worth composition buckets")
    func dashboardAccountGroupsFollowCompositionBuckets() {
        let composition = NetWorthComposition.calculate(from: [
            accountSummary("Checking", type: .checking, amount: 1_000),
            accountSummary("Brokerage", type: .investment, amount: 500, liquidity: .restricted),
            accountSummary("AFORE", type: .retirement, amount: 700, liquidity: .lockedUntilRetirement, retirementKind: .afore),
            accountSummary("Card", type: .creditCard, amount: -300),
            accountSummary("Mystery", type: .other, amount: 40),
        ])

        let groups = DashboardAccountGroupBuilder.groups(from: composition, currencyCode: "MXN")

        #expect(groups.map(\.bucket) == [.liquidity, .patrimonial, .retirement, .liabilities, .uncategorized])
        #expect(groups.first { $0.bucket == .liquidity }?.subtotal == 700)
        #expect(groups.first { $0.bucket == .liabilities }?.subtotal == -300)
        #expect(groups.first { $0.bucket == .uncategorized }?.accounts.map(\.displayName) == ["Mystery"])
    }

    @Test("Net worth trend skips intervals before known accounts all have balances")
    func netWorthTrendSkipsIncompleteHistory() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let checking = Account(institution: "Bank", type: .checking)
        let retirement = Account(institution: "AFORE", type: .retirement, retirementKindRaw: RetirementKind.afore.rawValue)
        context.insert(checking)
        context.insert(retirement)
        context.insert(AccountBalanceSnapshot(account: checking, date: date(year: 2026, month: 1, day: 1), amount: 1_000, kind: .manualOpening))
        context.insert(AccountBalanceSnapshot(account: retirement, date: date(year: 2026, month: 6, day: 1), amount: 5_000, kind: .manualOpening))
        try context.save()

        let viewModel = DashboardViewModel()
        viewModel.setPeriod(.all, now: date(year: 2026, month: 6, day: 30))
        viewModel.configure(context: context)

        guard case .consolidated(let snap) = viewModel.snapshot else {
            Issue.record("Expected consolidated snapshot"); return
        }

        #expect(snap.netWorthOverTime.first?.month ?? .distantPast >= date(year: 2026, month: 6, day: 1))
        #expect(snap.netWorthOverTime.allSatisfy { $0.balance >= 6_000 })
    }

    @Test("Hover snapping maps raw dates inside a bucket to the same bucket start")
    func hoverSnappingMapsRawDatesToBucketStart() {
        let calendar = Calendar(identifier: .gregorian)
        let now = date(year: 2026, month: 6, day: 11)
        let range = DashboardPeriodKind.quarter.resolvedRange(now: now)
        let period = DashboardPeriodResolver.context(kind: .quarter, requestedRange: range, dataRange: nil, now: now)
        let aprilStart = date(year: 2026, month: 4, day: 1)
        let aprilMiddle = date(year: 2026, month: 4, day: 15)
        let aprilEnd = calendar.date(byAdding: DateComponents(day: 29, hour: 23), to: aprilStart)!

        #expect(period.bucketStart(forSelection: aprilStart, calendar: calendar) == aprilStart)
        #expect(period.bucketStart(forSelection: aprilMiddle, calendar: calendar) == aprilStart)
        #expect(period.bucketStart(forSelection: aprilEnd, calendar: calendar) == aprilStart)
    }

    @Test("Liability chart buckets stay within the selected period")
    func liabilityChartBucketsStayInsideSelectedPeriod() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let now = date(year: 2026, month: 6, day: 11)
        let card = Account(institution: "Test Card", type: .creditCard)
        context.insert(card)
        context.insert(Transaction(
            account: card,
            postedAt: date(year: 2026, month: 6, day: 5),
            amount: -500,
            descriptionRaw: "June charge",
            source: .manual
        ))
        try context.save()

        let viewModel = DashboardViewModel()
        viewModel.scope = .account(card.id)
        viewModel.setPeriod(.month, now: now)
        viewModel.configure(context: context)

        guard case .liability(let snap) = viewModel.snapshot else {
            Issue.record("Expected liability snapshot"); return
        }

        #expect(snap.chargesVsPayments.allSatisfy { $0.month >= snap.period.dateRange.start && $0.month <= snap.period.dateRange.end })
        for entry in snap.chargesVsPayments {
            let barX = snap.period.barXValue(forBucketStart: entry.month)
            #expect(barX >= snap.period.dateRange.start)
            #expect(barX <= snap.period.dateRange.end)
            #expect(barX >= snap.period.plotDomain.lowerBound)
            #expect(barX <= snap.period.plotDomain.upperBound)
        }
    }

    @Test("Net worth breakdown copy distinguishes provenance from period activity")
    func netWorthBreakdownCopyUsesProvenanceWording() throws {
        let period = DashboardPeriodResolver.context(
            kind: .custom,
            requestedRange: DateRange(start: date(year: 2026, month: 6, day: 1), end: date(year: 2026, month: 6, day: 11)),
            dataRange: nil,
            now: date(year: 2026, month: 6, day: 11)
        )

        let exact = accountSummary(
            kind: .exactBalanceSnapshot,
            asOf: period.effectiveNetWorthDate,
            sourceDate: date(year: 2026, month: 6, day: 11)
        )
        let prior = accountSummary(
            kind: .latestPriorBalanceSnapshot,
            asOf: period.effectiveNetWorthDate,
            sourceDate: date(year: 2026, month: 1, day: 1)
        )
        let reconstructed = accountSummary(
            kind: .reconstructedBalance,
            asOf: period.effectiveNetWorthDate,
            sourceDate: date(year: 2026, month: 1, day: 1)
        )
        let estimated = accountSummary(
            kind: .reconstructedBalance,
            asOf: period.effectiveNetWorthDate,
            sourceDate: nil
        )
        let insufficient = accountSummary(
            kind: .insufficientHistory,
            asOf: period.effectiveNetWorthDate,
            sourceDate: nil
        )

        let request = BreakdownRequest.netWorth(period: period, accounts: [exact, prior, reconstructed, estimated, insufficient])
        guard case .netWorth(let requestPeriod, let accounts) = request else {
            Issue.record("Expected net worth breakdown request"); return
        }

        #expect(requestPeriod.effectiveNetWorthDate == period.effectiveNetWorthDate)
        #expect(requestPeriod.dateRange.start == period.dateRange.start)
        #expect(requestPeriod.dateRange.end == period.dateRange.end)
        #expect(accounts.count == 5)
        #expect(request.title == "Net Worth as of 11 June 2026")
        #expect(NetWorthBreakdownCopy.subtitle(for: period) == "Point-in-time account balances. This is not a sum of transactions during Jun 1-11.")
        #expect(NetWorthBreakdownCopy.sourceText(exact) == "Snapshot on 11 Jun 2026")
        #expect(NetWorthBreakdownCopy.sourceText(prior) == "Using latest balance snapshot before 11 Jun 2026 · Snapshot date: 1 Jan 2026")
        #expect(NetWorthBreakdownCopy.sourceText(reconstructed) == "Balance reconstructed up to 11 Jun 2026 · Starting snapshot: 1 Jan 2026")
        #expect(NetWorthBreakdownCopy.sourceText(estimated) == "Balance estimated from available transactions up to 11 Jun 2026 · No starting balance snapshot")
        #expect(NetWorthBreakdownCopy.sourceText(insufficient) == "Insufficient balance history before 11 Jun 2026")

        let priorText = NetWorthBreakdownCopy.sourceText(prior)
        #expect(priorText.contains("1 Jan 2026"))
        #expect(!priorText.localizedCaseInsensitiveContains("activity"))
        #expect(!priorText.localizedCaseInsensitiveContains("transaction"))
    }

    @Test("Net worth breakdown date labels handle compact range shapes")
    func netWorthBreakdownDateRangeLabels() {
        let singleDay = DateRange(start: date(year: 2026, month: 6, day: 1), end: date(year: 2026, month: 6, day: 1))
        let sameMonth = DateRange(start: date(year: 2026, month: 6, day: 1), end: date(year: 2026, month: 6, day: 11))
        let crossMonth = DateRange(start: date(year: 2026, month: 6, day: 26), end: date(year: 2026, month: 7, day: 5))
        let crossYear = DateRange(start: date(year: 2026, month: 12, day: 28), end: date(year: 2027, month: 1, day: 3))

        #expect(NetWorthBreakdownCopy.periodRange(singleDay) == "Jun 1")
        #expect(NetWorthBreakdownCopy.periodRange(sameMonth) == "Jun 1-11")
        #expect(NetWorthBreakdownCopy.periodRange(crossMonth) == "Jun 26-Jul 5")
        #expect(NetWorthBreakdownCopy.periodRange(crossYear) == "Dec 28, 2026-Jan 3, 2027")
    }

    private func snapshot(for period: DashboardPeriodKind, now: Date, context: ModelContext) -> ConsolidatedSnapshot? {
        let viewModel = DashboardViewModel()
        viewModel.setPeriod(period, now: now)
        viewModel.configure(context: context)
        guard case .consolidated(let snap) = viewModel.snapshot else { return nil }
        return snap
    }

    private func accountBreakdownTotal(_ summaries: [AccountSummary]) -> Decimal {
        summaries.reduce(Decimal.zero) { partial, summary in
            summary.balanceSourceKind == .insufficientHistory ? partial : partial + summary.latestBalance
        }
    }

    private func accountSummary(
        kind: AccountBalanceResolution.SourceKind,
        asOf: Date,
        sourceDate: Date?
    ) -> AccountSummary {
        AccountSummary(
            id: UUID(),
            displayName: "Test Account",
            institution: "Test Bank",
            type: .checking,
            currency: "MXN",
            latestBalance: kind == .insufficientHistory ? 0 : 100,
            balanceAsOf: asOf,
            balanceSourceKind: kind,
            balanceSourceDate: sourceDate,
            creditLimit: nil,
            utilizationPercent: nil
        )
    }

    private func accountSummary(
        _ name: String,
        type: AccountType,
        amount: Decimal,
        liquidity: AccountLiquidity = .liquid,
        retirementKind: RetirementKind? = nil
    ) -> AccountSummary {
        AccountSummary(
            id: UUID(),
            displayName: name,
            institution: "Test Bank",
            type: type,
            currency: "MXN",
            latestBalance: amount,
            balanceAsOf: date(year: 2026, month: 6, day: 1),
            balanceSourceKind: .exactBalanceSnapshot,
            balanceSourceDate: date(year: 2026, month: 6, day: 1),
            creditLimit: nil,
            utilizationPercent: nil,
            liquidity: liquidity,
            retirementKind: retirementKind
        )
    }

    private func categorySpend(_ name: String, _ amount: Decimal) -> CategorySpending {
        CategorySpending(category: FinanceTracker.Category(name: name, kind: .expense), amount: amount)
    }

    private func displayBucket(year: Int, month: Int, first: Decimal, second: Decimal) -> DashboardPeriodBucketDisplayValue {
        DashboardPeriodBucketDisplayValue(
            bucketStart: date(year: year, month: month, day: 1),
            firstMagnitude: first,
            secondMagnitude: second
        )
    }

    private func date(year: Int, month: Int, day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.timeZone = TimeZone(identifier: "America/Mexico_City")
        return Calendar(identifier: .gregorian).date(from: components)!
    }
}

private extension Calendar {
    func endOfDay(for date: Date) -> Date {
        let start = startOfDay(for: date)
        return self.date(byAdding: DateComponents(day: 1, second: -1), to: start)!
    }
}
