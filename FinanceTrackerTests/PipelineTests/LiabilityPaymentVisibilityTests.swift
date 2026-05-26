import Testing
import Foundation
import SwiftData
@testable import FinanceTracker

@Suite("Liability Payment Visibility")
@MainActor
struct LiabilityPaymentVisibilityTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            Account.self,
            Transaction.self,
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

    private func dateFromComponents(year: Int, month: Int, day: Int) -> Date {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day
        c.timeZone = TimeZone(identifier: "America/Mexico_City")
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    @Test("Transfer-kind payment on credit card counts as liability payment")
    func transferKindPaymentOnCC() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let account = Account(institution: "Banamex", type: .creditCard, currency: "MXN")
        context.insert(account)

        let transfers = FinanceTracker.Category(name: "Transfers", kind: .transfer)
        let ccPay = FinanceTracker.Category(name: "Credit Card Payments", parent: transfers, kind: .transfer)
        context.insert(transfers)
        context.insert(ccPay)

        let stmt = Statement(
            account: account,
            periodStart: dateFromComponents(year: 2026, month: 1, day: 1),
            periodEnd: dateFromComponents(year: 2026, month: 5, day: 31),
            sourceFileHash: "test-hash",
            closingBalance: -10000
        )
        context.insert(stmt)

        let charge = Transaction(
            account: account,
            postedAt: dateFromComponents(year: 2026, month: 3, day: 15),
            amount: -5000,
            descriptionRaw: "Amazon Purchase",
            category: FinanceTracker.Category(name: "Shopping", kind: .expense)
        )
        let payment = Transaction(
            account: account,
            postedAt: dateFromComponents(year: 2026, month: 4, day: 1),
            amount: 25986,
            descriptionRaw: "SPEI enviada a TDC Explora",
            category: ccPay
        )
        context.insert(charge)
        context.insert(payment)
        try context.save()

        let viewModel = DashboardViewModel()
        viewModel.dateRange = DateRange(start: .distantPast, end: .distantFuture)
        viewModel.scope = .account(account.id)
        viewModel.configure(context: context)

        guard case .liability(let snap) = viewModel.snapshot else {
            Issue.record("Expected liability snapshot"); return
        }

        #expect(snap.totalPayments == 25986,
                "Transfer-kind payment should count as liability payment, got \(snap.totalPayments)")

        let marchPayments = snap.chargesVsPayments.first {
            Calendar.current.isDate($0.month, equalTo: dateFromComponents(year: 2026, month: 4, day: 1), toGranularity: .month)
        }
        #expect(marchPayments?.payments == 25986,
                "Charges vs Payments chart should include the transfer-kind payment")
    }

    @Test("Credit card payment kind counts as liability payment")
    func creditCardPaymentKindOnCC() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let account = Account(institution: "HSBC", type: .creditCard, currency: "MXN")
        context.insert(account)

        let ccPayCategory = FinanceTracker.Category(name: "Credit Card Payments", kind: .creditCardPayment)
        context.insert(ccPayCategory)

        let stmt = Statement(
            account: account,
            periodStart: dateFromComponents(year: 2026, month: 1, day: 1),
            periodEnd: dateFromComponents(year: 2026, month: 5, day: 31),
            sourceFileHash: "test-hash",
            closingBalance: -20000
        )
        context.insert(stmt)

        let payment = Transaction(
            account: account,
            postedAt: dateFromComponents(year: 2026, month: 4, day: 29),
            amount: 25986,
            descriptionRaw: "SU PAGO GRACIAS SPEI",
            category: ccPayCategory
        )
        context.insert(payment)
        try context.save()

        let viewModel = DashboardViewModel()
        viewModel.dateRange = DateRange(start: .distantPast, end: .distantFuture)
        viewModel.scope = .account(account.id)
        viewModel.configure(context: context)

        guard case .liability(let snap) = viewModel.snapshot else {
            Issue.record("Expected liability snapshot"); return
        }

        #expect(snap.totalPayments == 25986,
                "CreditCardPayment-kind payment should count as liability payment")
    }

    @Test("Positive refund with no special category counts as payment")
    func refundCountsAsPayment() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let account = Account(institution: "Amex", type: .creditCard, currency: "MXN")
        context.insert(account)

        let stmt = Statement(
            account: account,
            periodStart: dateFromComponents(year: 2026, month: 1, day: 1),
            periodEnd: dateFromComponents(year: 2026, month: 5, day: 31),
            sourceFileHash: "test-hash",
            closingBalance: -5000
        )
        context.insert(stmt)

        let refund = Transaction(
            account: account,
            postedAt: dateFromComponents(year: 2026, month: 3, day: 10),
            amount: 1500,
            descriptionRaw: "GRACIAS POR SU PAGO EN LINEA"
        )
        context.insert(refund)
        try context.save()

        let viewModel = DashboardViewModel()
        viewModel.dateRange = DateRange(start: .distantPast, end: .distantFuture)
        viewModel.scope = .account(account.id)
        viewModel.configure(context: context)

        guard case .liability(let snap) = viewModel.snapshot else {
            Issue.record("Expected liability snapshot"); return
        }

        #expect(snap.totalPayments == 1500,
                "Uncategorized positive refund should count as payment")
    }

    @Test("Consolidated cash flow still excludes transfer and credit card payments")
    func consolidatedStillExcludesTransfers() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let checking = Account(institution: "Openbank", type: .checking, currency: "MXN")
        context.insert(checking)

        let ccCategory = FinanceTracker.Category(name: "Credit Card Payments", kind: .creditCardPayment)
        context.insert(ccCategory)

        let outgoing = Transaction(
            account: checking,
            postedAt: dateFromComponents(year: 2026, month: 4, day: 29),
            amount: -25986,
            descriptionRaw: "SPEI enviada a 2now HSBC",
            category: ccCategory
        )
        context.insert(outgoing)
        try context.save()

        let viewModel = DashboardViewModel()
        viewModel.dateRange = DateRange(start: .distantPast, end: .distantFuture)
        viewModel.scope = .consolidated
        viewModel.configure(context: context)

        guard case .consolidated(let snap) = viewModel.snapshot else {
            Issue.record("Expected consolidated snapshot"); return
        }

        #expect(snap.totalIncome == 0, "Credit card payment should not appear as consolidated income")
        #expect(snap.totalExpenses == 0, "Credit card payment should not appear as consolidated expense")
    }

    @Test("MSI synthesized original purchase excluded from charges, monthly cuota included")
    func msiSynthesizedExcludedCuotaIncluded() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let account = Account(institution: "HSBC", type: .creditCard, currency: "MXN")
        context.insert(account)

        let stmt = Statement(
            account: account,
            periodStart: dateFromComponents(year: 2026, month: 1, day: 1),
            periodEnd: dateFromComponents(year: 2026, month: 5, day: 31),
            sourceFileHash: "test-hash",
            closingBalance: -45000
        )
        context.insert(stmt)

        let plan = InstallmentPlan(
            account: account,
            originalAmount: 12000,
            totalMonths: 12,
            currentMonth: 2,
            monthlyAmount: 1000,
            ratePercent: 0,
            firstChargeDate: dateFromComponents(year: 2026, month: 4, day: 1),
            merchantDescription: "HOME DEPOT"
        )
        context.insert(plan)

        let synthesized = Transaction(
            account: account,
            postedAt: dateFromComponents(year: 2026, month: 4, day: 1),
            amount: -12000,
            descriptionRaw: "HOME DEPOT MSI",
            installmentPlan: plan
        )
        let cuota = Transaction(
            account: account,
            postedAt: dateFromComponents(year: 2026, month: 5, day: 1),
            amount: -1000,
            descriptionRaw: "HOME DEPOT MSI 2/12"
        )
        context.insert(synthesized)
        context.insert(cuota)
        try context.save()

        let viewModel = DashboardViewModel()
        viewModel.dateRange = DateRange(start: .distantPast, end: .distantFuture)
        viewModel.scope = .account(account.id)
        viewModel.configure(context: context)

        guard case .liability(let snap) = viewModel.snapshot else {
            Issue.record("Expected liability snapshot"); return
        }

        #expect(snap.totalCharges == 1000,
                "Only monthly cuota should be a charge, not the synthesized original purchase. Got \(snap.totalCharges)")

        let mayEntry = snap.chargesVsPayments.first {
            Calendar.current.isDate($0.month, equalTo: dateFromComponents(year: 2026, month: 5, day: 1), toGranularity: .month)
        }
        #expect(mayEntry?.charges == 1000,
                "Chart should show monthly cuota as charge")

        let aprEntry = snap.chargesVsPayments.first {
            Calendar.current.isDate($0.month, equalTo: dateFromComponents(year: 2026, month: 4, day: 1), toGranularity: .month)
        }
        #expect(aprEntry == nil || aprEntry?.charges == 0,
                "Chart should not show the synthesized original purchase as a charge")
    }
}
