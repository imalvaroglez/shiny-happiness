import Testing
import Foundation
import SwiftData
@testable import FinanceTracker

@Suite("Cash Flow Exclusion")
@MainActor
struct CashFlowExclusionTests {

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

    private func dateFromComponents(year: Int, month: Int, day: Int) -> Date {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day
        c.timeZone = TimeZone(identifier: "America/Mexico_City")
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    @Test("isTransfer == true excluded even with non-transfer category")
    func isTransferExcludedEvenWithNonTransferCategory() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let incomeCategory = FinanceTracker.Category(name: "Salary", kind: .income)
        let expenseCategory = FinanceTracker.Category(name: "Restaurants", kind: .expense)
        context.insert(incomeCategory)
        context.insert(expenseCategory)

        let account = Account(institution: "Openbank", type: .checking)
        context.insert(account)

        let transferTx = Transaction(
            account: account,
            postedAt: dateFromComponents(year: 2026, month: 5, day: 10),
            amount: 25000,
            descriptionRaw: "PAGO RECIBIDO DE STP POR ORDEN DE TITULAR",
            category: incomeCategory,
            isTransfer: true
        )
        let realExpense = Transaction(
            account: account,
            postedAt: dateFromComponents(year: 2026, month: 5, day: 11),
            amount: -500,
            descriptionRaw: "RESTAURANT LUNCH",
            category: expenseCategory
        )
        context.insert(transferTx)
        context.insert(realExpense)
        try context.save()

        let viewModel = DashboardViewModel()
        viewModel.dateRange = DateRange(start: .distantPast, end: .distantFuture)
        viewModel.scope = .consolidated
        viewModel.configure(context: context)

        guard case .consolidated(let snap) = viewModel.snapshot else {
            Issue.record("Expected consolidated snapshot"); return
        }

        #expect(snap.totalIncome == 0, "isTransfer=true should be excluded from income even with income category, got \(snap.totalIncome)")
        #expect(snap.totalExpenses == -500, "Only real expense should count, got \(snap.totalExpenses)")
    }

    @Test("Own-account movement fallback excludes stale income-categorized rows")
    func ownAccountMovementFallback() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let incomeCategory = FinanceTracker.Category(name: "Refund", kind: .income)
        context.insert(incomeCategory)

        let account = Account(institution: "Banamex", type: .checking)
        context.insert(account)

        let staleTransfer = Transaction(
            account: account,
            postedAt: dateFromComponents(year: 2026, month: 4, day: 1),
            amount: 15000,
            descriptionRaw: "recibida de la cuenta 4444 BANAMEX, TITULAR PRUEBA",
            category: incomeCategory,
            isTransfer: false
        )
        context.insert(staleTransfer)
        try context.save()

        let viewModel = DashboardViewModel()
        viewModel.dateRange = DateRange(start: .distantPast, end: .distantFuture)
        viewModel.scope = .consolidated
        viewModel.configure(context: context)

        guard case .consolidated(let snap) = viewModel.snapshot else {
            Issue.record("Expected consolidated snapshot"); return
        }

        #expect(snap.totalIncome == 0, "Own-account movement should be excluded via fallback, got \(snap.totalIncome)")
    }

    @Test("Real salary income is not excluded")
    func realSalaryNotExcluded() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let salaryCategory = FinanceTracker.Category(name: "Salary", kind: .income)
        context.insert(salaryCategory)

        let account = Account(institution: "Openbank", type: .checking)
        context.insert(account)

        let salary = Transaction(
            account: account,
            postedAt: dateFromComponents(year: 2026, month: 5, day: 15),
            amount: 50000,
            descriptionRaw: "ABONO NOMINA 20260515",
            category: salaryCategory,
            isTransfer: false
        )
        context.insert(salary)
        try context.save()

        let viewModel = DashboardViewModel()
        viewModel.dateRange = DateRange(start: .distantPast, end: .distantFuture)
        viewModel.scope = .consolidated
        viewModel.configure(context: context)

        guard case .consolidated(let snap) = viewModel.snapshot else {
            Issue.record("Expected consolidated snapshot"); return
        }

        #expect(snap.totalIncome == 50000, "Real salary should be included as income, got \(snap.totalIncome)")
    }
}
