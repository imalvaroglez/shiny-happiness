import Testing
import Foundation
import SwiftData
@testable import FinanceTracker

/// End-to-end verification of the Stage 3 dashboard.
///
/// These tests do NOT launch the app. They build an in-memory model
/// container, ingest the HSBC paste fixture (and optionally an Openbank PDF),
/// then assert that `DashboardViewModel.snapshot` matches the documented
/// expectations:
///   - liability scope renders with the right utilization, payment due, MSI
///   - consolidated scope nets liabilities against assets correctly
///   - SU PAGO GRACIAS payments don't double-count when both sides exist
@Suite("Dashboard Snapshot")
@MainActor
struct DashboardSnapshotTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            Account.self, AccountBalanceSnapshot.self, Transaction.self,
            Statement.self,
            Category.self,
            CategoryRule.self,
            InstallmentPlan.self,
            PendingImport.self,
            SignRecoveryHint.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    private var hsbcFixture: String {
        get throws {
            let url = URL(fileURLWithPath: "/Users/developer/Documents/GitHub/shiny-happiness/samples/2026-05-08_HSBC_2Now_paste.txt")
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    private var openbankFixturePath: String {
        "/Users/developer/Documents/GitHub/shiny-happiness/samples/01.pdf"
    }

    private func skipIfFixtureMissing(_ path: String) -> Bool {
        !FileManager.default.fileExists(atPath: path)
    }

    // MARK: - Liability scope

    @Test("HSBC liability snapshot has the documented utilization, due date, MSI")
    func liabilitySnapshotMatchesFixture() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        SeedDataLoader.bootstrapIfNeeded(context: context)

        let pipeline = IngestPipeline(context: context)
        let text = try hsbcFixture
        _ = await pipeline.ingestPastedText(text, sourceLabel: "HSBC paste")

        let accounts = try context.fetch(FetchDescriptor<Account>())
        guard let hsbc = accounts.first(where: { $0.institution == "HSBC 2Now" && $0.accountNumber == "1111" }) else {
            Issue.record("HSBC titular account not created from paste")
            return
        }

        let viewModel = DashboardViewModel()
        viewModel.dateRange = DateRange(start: .distantPast, end: .distantFuture)
        viewModel.scope = .account(hsbc.id)
        viewModel.configure(context: context)

        guard case .liability(let snap) = viewModel.snapshot else {
            Issue.record("Expected liability snapshot for credit-card account, got \(viewModel.snapshot)")
            return
        }

        // Documented totals from the fixture:
        //   creditLimit = $465,000.00
        //   amountOwed  = $45,054.70 (signed-negative in storage)
        //   utilization ≈ 9.69%
        #expect(snap.creditLimit == Decimal(string: "465000.00"))
        #expect(snap.amountOwed == Decimal(string: "45054.70"),
                "Expected $45,054.70 owed; got \(snap.amountOwed)")
        if let util = snap.utilizationPercent {
            #expect((util * 1000).rounded() / 1000 == 0.097,
                    "Expected utilization ≈ 9.7%; got \(util)")
        } else {
            Issue.record("Utilization not computed")
        }

        // Payment-due date: sábado, 30-May-2026
        if let due = snap.latestStatement?.paymentDueDate {
            let comps = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: due)
            #expect(comps.year == 2026 && comps.month == 5 && comps.day == 30)
        } else {
            Issue.record("paymentDueDate not stored on latestStatement")
        }

        // At least one active installment plan; HOME DEPOT must be present.
        #expect(!snap.activeInstallmentPlans.isEmpty,
                "Expected at least one active MSI plan")
        let homeDepot = snap.activeInstallmentPlans.first { $0.merchantDescription.localizedCaseInsensitiveContains("HOME DEPOT") }
        guard let plan = homeDepot else {
            Issue.record("HOME DEPOT MSI plan not surfaced in liability snapshot")
            return
        }
        #expect(plan.currentMonth == 2)
        #expect(plan.totalMonths == 12)
    }

    // MARK: - Consolidated net worth

    @Test("Consolidated net worth nets liabilities against assets (signed sum)")
    func consolidatedNetWorthSignedSum() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        SeedDataLoader.bootstrapIfNeeded(context: context)

        // Build a synthetic asset account so we can verify the cross-account math
        // without depending on Openbank's specific fixture numbers.
        let asset = Account(institution: "Synthetic Bank", type: .checking, currency: "MXN")
        context.insert(asset)
        let assetStatement = Statement(
            account: asset,
            periodStart: .now.addingTimeInterval(-30 * 86400),
            periodEnd: .now,
            sourceFileHash: "synthetic-asset-hash",
            openingBalance: Decimal(string: "100000.00"),
            closingBalance: Decimal(string: "100000.00")
        )
        context.insert(assetStatement)
        try context.save()

        // Now ingest the HSBC liability paste, which stores closingBalance as -45,054.70.
        let pipeline = IngestPipeline(context: context)
        _ = await pipeline.ingestPastedText(try hsbcFixture, sourceLabel: "HSBC paste")

        let viewModel = DashboardViewModel()
        viewModel.dateRange = DateRange(start: .distantPast, end: .distantFuture)
        viewModel.scope = .consolidated
        viewModel.configure(context: context)

        guard case .consolidated(let snap) = viewModel.snapshot else {
            Issue.record("Expected consolidated snapshot, got \(viewModel.snapshot)")
            return
        }

        // Expected: 100,000 - 45,054.70 = 54,945.30
        let expected = Decimal(string: "54945.30")!
        let delta = abs(((snap.netWorth - expected) as NSDecimalNumber).doubleValue)
        #expect(delta < 1.0,
                "Net worth should net liabilities; got \(snap.netWorth), expected \(expected)")
    }

    // MARK: - SU PAGO double-count guard

    @Test("Consolidated cash flow excludes credit-card payments (SU PAGO doesn't double-count)")
    func consolidatedCashFlowExcludesCardPayments() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        SeedDataLoader.bootstrapIfNeeded(context: context)

        // Ingest HSBC. The SU PAGO line creates a positive-amount payment Transaction
        // categorized as .creditCardPayment on the HSBC account.
        let pipeline = IngestPipeline(context: context)
        _ = await pipeline.ingestPastedText(try hsbcFixture, sourceLabel: "HSBC paste")

        // Manually add the matching outgoing SPEI on a synthetic checking account —
        // this is the side that *would* show on Openbank's statement.
        let checking = Account(institution: "Synthetic Bank", type: .checking, currency: "MXN")
        context.insert(checking)
        let ccPaymentsCategory = (try? context.fetch(FetchDescriptor<FinanceTracker.Category>()))?
            .first { $0.kind == .creditCardPayment }
        let outgoing = Transaction(
            account: checking,
            postedAt: dateFromComponents(year: 2026, month: 4, day: 29),
            amount: Decimal(string: "-25986.00")!,
            currency: "MXN",
            descriptionRaw: "SPEI enviada a 2now HSBC",
            merchantNormalized: "HSBC 2Now",
            category: ccPaymentsCategory
        )
        context.insert(outgoing)
        try context.save()

        let viewModel = DashboardViewModel()
        viewModel.dateRange = DateRange(start: .distantPast, end: .distantFuture)
        viewModel.scope = .consolidated
        viewModel.configure(context: context)

        guard case .consolidated(let snap) = viewModel.snapshot else {
            Issue.record("Expected consolidated snapshot")
            return
        }

        // Neither side of the credit-card payment should appear in income/expense
        // aggregates because both are categorized .creditCardPayment and excluded.
        // Specifically: there should be no $25,986 entry in cash flow.
        let suspect = snap.monthlyCashFlow.contains { entry in
            // Either side of the pair has magnitude 25986 in income or expenses.
            abs((entry.income as NSDecimalNumber).doubleValue - 25986) < 1
                || abs((abs(entry.expenses) as NSDecimalNumber).doubleValue - 25986) < 1
        }
        #expect(!suspect, "Cash flow appears to include a $25,986 row from the SU PAGO pair — both sides should be excluded as .creditCardPayment")
    }

    @Test("Interest Earned drill-down sees all matching transactions, not just recent-20")
    func interestDrilldownIsComplete() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        SeedDataLoader.bootstrapIfNeeded(context: context)

        let savings = Account(institution: "Synthetic Bank", type: .savings, currency: "MXN")
        context.insert(savings)
        let interestCategory = (try? context.fetch(FetchDescriptor<FinanceTracker.Category>()))?
            .first { $0.name == "Interest" }

        for i in 0..<5 {
            let tx = Transaction(
                account: savings,
                postedAt: .now.addingTimeInterval(TimeInterval(-(100 - i) * 86400)),
                amount: 100,
                currency: "MXN",
                descriptionRaw: "Abono de intereses #\(i)",
                category: interestCategory
            )
            context.insert(tx)
        }
        for i in 0..<20 {
            let tx = Transaction(
                account: savings,
                postedAt: .now.addingTimeInterval(TimeInterval(-i * 86400)),
                amount: -10,
                currency: "MXN",
                descriptionRaw: "Coffee #\(i)"
            )
            context.insert(tx)
        }
        try context.save()

        let viewModel = DashboardViewModel()
        viewModel.dateRange = DateRange(start: .distantPast, end: .distantFuture)
        viewModel.scope = .consolidated
        viewModel.configure(context: context)

        guard case .consolidated(let snap) = viewModel.snapshot else {
            Issue.record("Expected consolidated snapshot"); return
        }

        #expect(snap.recentTransactions.count >= 25,
                "recentTransactions should hold the full filtered set, got \(snap.recentTransactions.count)")

        let interestRows = snap.recentTransactions.filter {
            $0.category?.name == "Interest" && $0.amount > 0
        }
        #expect(interestRows.count == 5,
                "Expected all 5 interest rows visible to BreakdownSheet, got \(interestRows.count)")

        #expect(snap.totalInterestEarned == 500,
                "totalInterestEarned should sum the 5 interest rows ($100 each)")
    }

    @Test("Net worth series has no duplicate months after aggregation")
    func netWorthSeriesNoDuplicateMonths() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        SeedDataLoader.bootstrapIfNeeded(context: context)

        let account = Account(institution: "Test Bank", type: .checking, currency: "MXN")
        context.insert(account)

        let stmt1 = Statement(
            account: account,
            periodStart: dateFromComponents(year: 2026, month: 1, day: 1),
            periodEnd: dateFromComponents(year: 2026, month: 1, day: 31),
            sourceFileHash: "hash-jan",
            closingBalance: 10000
        )
        let stmt2 = Statement(
            account: account,
            periodStart: dateFromComponents(year: 2026, month: 2, day: 1),
            periodEnd: dateFromComponents(year: 2026, month: 2, day: 15),
            sourceFileHash: "hash-feb-early",
            closingBalance: 12000
        )
        let stmt3 = Statement(
            account: account,
            periodStart: dateFromComponents(year: 2026, month: 2, day: 16),
            periodEnd: dateFromComponents(year: 2026, month: 2, day: 28),
            sourceFileHash: "hash-feb-late",
            closingBalance: 15000
        )
        context.insert(stmt1)
        context.insert(stmt2)
        context.insert(stmt3)
        try context.save()

        let viewModel = DashboardViewModel()
        viewModel.dateRange = DateRange(start: .distantPast, end: .distantFuture)
        viewModel.scope = .consolidated
        viewModel.configure(context: context)

        guard case .consolidated(let snap) = viewModel.snapshot else {
            Issue.record("Expected consolidated snapshot"); return
        }

        let months = snap.netWorthOverTime.map { $0.month }
        let calendar = Calendar(identifier: .gregorian)
        let monthKeys = months.map { calendar.dateComponents([.year, .month], from: $0) }
        let uniqueKeys = Set(monthKeys)
        #expect(monthKeys.count == uniqueKeys.count,
                "Net worth series should have one point per month, got \(monthKeys.count) points for \(uniqueKeys.count) unique months")
    }

    @Test("Manual balance snapshot creates step change in net worth series")
    func manualBalanceCreatesStep() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        SeedDataLoader.bootstrapIfNeeded(context: context)

        let account = Account(institution: "Test Bank", type: .checking, currency: "MXN")
        context.insert(account)

        let stmt = Statement(
            account: account,
            periodStart: dateFromComponents(year: 2026, month: 3, day: 1),
            periodEnd: dateFromComponents(year: 2026, month: 3, day: 31),
            sourceFileHash: "hash-mar",
            closingBalance: 10000
        )
        context.insert(stmt)

        let snapshot = AccountBalanceSnapshot(
            account: account,
            date: dateFromComponents(year: 2026, month: 5, day: 1),
            amount: 50000,
            kind: .manualOpening
        )
        context.insert(snapshot)
        try context.save()

        let viewModel = DashboardViewModel()
        viewModel.dateRange = DateRange(start: .distantPast, end: .distantFuture)
        viewModel.scope = .consolidated
        viewModel.configure(context: context)

        guard case .consolidated(let snap) = viewModel.snapshot else {
            Issue.record("Expected consolidated snapshot"); return
        }

        #expect(snap.netWorthOverTime.count >= 2,
                "Series should have at least 2 points (March statement + May snapshot), got \(snap.netWorthOverTime.count)")

        let calendar = Calendar(identifier: .gregorian)
        let mayPoint = snap.netWorthOverTime.first {
            let comps = calendar.dateComponents([.year, .month], from: $0.month)
            return comps.year == 2026 && comps.month == 5
        }
        #expect(mayPoint != nil, "Series should include a May point for the manual snapshot")
        if let may = mayPoint {
            #expect(may.balance == 50000,
                    "May balance should be 50,000 from manual snapshot, got \(may.balance)")
        }
    }

    private func dateFromComponents(year: Int, month: Int, day: Int) -> Date {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day
        c.timeZone = TimeZone(identifier: "America/Mexico_City")
        return Calendar(identifier: .gregorian).date(from: c)!
    }
}
