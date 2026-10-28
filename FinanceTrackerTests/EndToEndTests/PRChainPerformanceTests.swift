import Foundation
import SwiftData
import Testing
@testable import FinanceTracker

/// Opt-in backend measurements. These do not measure SwiftUI's first frame.
@Suite("PR chain backend performance")
@MainActor
struct PRChainPerformanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PR_CHAIN_PERFORMANCE"] == "1"))
    func representativeLedger() throws {
        let container = try ModelContainer(for: AppSchema.schema,
            configurations: ModelConfiguration(schema: AppSchema.schema, isStoredInMemoryOnly: true))
        let context = container.mainContext
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pr-performance-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let ledgerURL = root.appendingPathComponent("PromotionLedger.json")
        let customURL = root.appendingPathComponent("CategoryCustomization.json")
        let accounts = (0..<5).map { Account(institution: "Synthetic", type: .checking, currency: "MXN", nickname: "Fixture \($0)") }
        for account in accounts { context.insert(account) }
        var rows: [Transaction] = []
        for index in 0..<10_000 {
            let row = Transaction(account: accounts[index % 5], postedAt: Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(index * 60)),
                                  amount: -100, descriptionRaw: "Synthetic \(index)")
            context.insert(row)
            rows.append(row)
        }
        try context.save()
        let now = Date(timeIntervalSince1970: Date.now.timeIntervalSince1970.rounded(.down))
        let accountCatalog = (0..<10_000).map { index in
            Account(institution: "Synthetic", type: .checking, nickname: "Archive fixture \(index)",
                    archivedAt: index.isMultiple(of: 2) ? nil : now)
        }
        let promotion = PromotionRecord(id: UUID(), name: "Fixture", accountID: accounts[0].id, currency: "MXN",
            windowStart: nil, windowEnd: nil, targetAmount: 100_000, rewardNote: nil, notes: nil,
            archivedAt: nil, createdAt: now, updatedAt: now, deletedAt: nil)
        var ledger = PromotionLedger()
        ledger.promotions = [promotion]
        ledger.attributions = rows.prefix(1_000).map {
            PromotionAttribution(id: UUID(), promotionID: promotion.id, transactionID: $0.id,
                                 createdAt: now, updatedAt: now, deletedAt: nil)
        }
        try PromotionLedgerStore.replace(with: ledger, at: ledgerURL, notify: false)
        let model = PromotionLedgerViewModel()
        let category = Category(name: "Fixture")
        context.insert(category)
        try context.save()

        measure("capture-date preference", iterations: 25) {
            _ = ManualCaptureDateStore.suggestedDate(accountID: accounts[0].id)
        }
        measure("active account projection over 10000 cached accounts", iterations: 25) {
            let active = AccountArchiveService.activeAccounts(from: accountCatalog)
            #expect(active.count == 5_000)
        }
        var archiveCycle = 0
        try measure("archive and restore save with 10000 transaction rows", iterations: 25) {
            let timestamp = now.addingTimeInterval(TimeInterval(archiveCycle * 2))
            archiveCycle += 1
            try AccountArchiveService.archive(account: accounts[0], at: timestamp, context: context)
            try AccountArchiveService.restore(account: accounts[0], at: timestamp.addingTimeInterval(1), context: context)
        }
        measure("account filter over 10000 cached rows", iterations: 25) {
            let filtered = rows.filter { $0.account?.id == accounts[0].id }
            #expect(filtered.count == 2_000)
        }
        measure("promotion reload 1000 attributed / 10000 rows", iterations: 25) {
            model.reload(context: context, ledgerURL: ledgerURL)
            #expect(model.loadError == nil)
            #expect(model.entries.count == 1_000)
        }
        try measure("manual attribution write 1000 entries", iterations: 25) {
            try PromotionLedgerStore.attribute(transactionID: rows[1_001].id, promotionID: promotion.id, at: ledgerURL)
            try PromotionLedgerStore.unattribute(transactionID: rows[1_001].id, promotionID: promotion.id, at: ledgerURL)
        }
        try measure("color write and observable index refresh", iterations: 25) {
            try CategoryCustomizationStore.setTint(categoryID: category.id, hex: "#112233", at: customURL)
            CategoryCustomizationState.shared.refresh(fileURL: customURL)
            _ = CategoryBadgeColor.color(for: category)
            try CategoryCustomizationStore.clearTint(categoryID: category.id, at: customURL)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PR_CHAIN_PERFORMANCE"] == "1"))
    func accountBalanceChartWithManualInterest() throws {
        let container = try ModelContainer(for: AppSchema.schema,
            configurations: ModelConfiguration(schema: AppSchema.schema, isStoredInMemoryOnly: true))
        let context = container.mainContext
        let calendar = Calendar.current
        let now = Date.now
        let openedAt = calendar.date(byAdding: .year, value: -10, to: now)!
        let account = Account(institution: "Synthetic", type: .checking, openedAt: openedAt)
        let interest = Category(name: "Interest", kind: .income)
        context.insert(account)
        context.insert(interest)
        context.insert(AccountBalanceSnapshot(account: account, date: openedAt, amount: 100_000, kind: .manualOpening))

        let span = now.timeIntervalSince(openedAt)
        for index in 0..<10_000 {
            let fraction = Double(index) / 10_000
            context.insert(Transaction(
                account: account,
                postedAt: openedAt.addingTimeInterval(span * fraction),
                amount: -1,
                descriptionRaw: "Synthetic movement \(index)"
            ))
        }
        for month in 1...120 {
            guard let postedAt = calendar.date(byAdding: .month, value: month, to: openedAt), postedAt <= now else { continue }
            context.insert(Transaction(
                account: account,
                postedAt: postedAt,
                amount: 100,
                descriptionRaw: "Monthly interest capture \(month)",
                category: interest,
                source: .manual
            ))
        }
        try context.save()

        measure("initial month asset dashboard build with 10000 movements and 120 interest captures", iterations: 5) {
            let viewModel = DashboardViewModel()
            viewModel.scope = .account(account.id)
            viewModel.setPeriod(.month, now: now)
            viewModel.configure(context: context)
            guard case .asset(let snapshot) = viewModel.snapshot else {
                Issue.record("Expected asset snapshot during initial chart performance measurement")
                return
            }
            #expect(!snapshot.balanceOverTime.isEmpty)
        }

        let viewModel = DashboardViewModel()
        viewModel.scope = .account(account.id)
        viewModel.setPeriod(.month, now: now)
        viewModel.configure(context: context)

        viewModel.setPeriod(.all, now: now)
        viewModel.refresh()
        guard case .asset(let allTimeSnapshot) = viewModel.snapshot else {
            Issue.record("Expected all-time asset snapshot for chart measurement")
            return
        }
        let history = AccountBalanceResolver.history(account: account, context: context)
        let basePoints = AccountBalanceResolver.balanceSeries(account: account, history: history)
        let monthPeriod = DashboardPeriodResolver.context(
            kind: .month,
            requestedRange: DashboardPeriodKind.month.resolvedRange(now: now),
            dataRange: nil,
            now: now
        )
        let sampleDates = Array(Set(
            [monthPeriod.dateRange.start, monthPeriod.dateRange.end]
                + monthPeriod.intervals().map(\.end)
        )).sorted()
        measure("chart projection from cached 10000-movement baseline and 3650 accrual days", iterations: 25) {
            let adjustments = AccountBalanceResolver.chartInterestAdjustments(
                account: account,
                history: history,
                manualInterestAllocations: allTimeSnapshot.interestAllocations
            )
            let points = AccountBalanceResolver.balanceSeries(
                basePoints: basePoints,
                sampleDates: sampleDates,
                adjustments: adjustments
            )
            #expect(!points.isEmpty)
        }

        let kinds: [DashboardPeriodKind] = [.month, .quarter, .year]
        var iteration = 0
        measure("asset dashboard period refresh with 10000 movements and 120 interest captures", iterations: 25) {
            let kind = kinds[iteration % kinds.count]
            iteration += 1
            viewModel.setPeriod(kind, now: now)
            viewModel.refresh()
            guard case .asset(let snapshot) = viewModel.snapshot else {
                Issue.record("Expected asset snapshot during chart performance measurement")
                return
            }
            #expect(!snapshot.balanceOverTime.isEmpty)
        }
    }

    private func measure(_ name: String, iterations: Int, operation: () throws -> Void) rethrows {
        var times: [Double] = []
        for _ in 0..<iterations {
            let start = ContinuousClock.now
            try operation()
            let duration = start.duration(to: .now).components
            times.append(Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15)
        }
        times.sort()
        print("PR-PERF \(name): median=\(times[times.count / 2])ms max=\(times.last!)ms n=\(iterations)")
    }
}
