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
