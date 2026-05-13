import SwiftUI
import SwiftData

struct MonthlyCashFlow: Identifiable {
    let month: Date
    let income: Decimal
    let expenses: Decimal
    var id: Date { month }
    var savings: Decimal { income + expenses }
    var savingsRate: Decimal { income == 0 ? 0 : (income + expenses) / income * 100 }
}

struct CategorySpending: Identifiable {
    let category: Category
    let amount: Decimal
    var id: UUID { category.id }
}

struct NetWorthPoint: Identifiable {
    let month: Date
    let balance: Decimal
    var id: Date { month }
}

@MainActor
@Observable
final class DashboardViewModel {
    var snapshot: DashboardSnapshot = .empty(EmptySnapshot(reason: "Loading…"))
    var dateRange: DateRange = .year(.now)
    var scope: DashboardScope = .consolidated

    private var context: ModelContext?

    func configure(context: ModelContext) {
        self.context = context
        refresh()
    }

    func refresh() {
        guard let context else {
            snapshot = .empty(EmptySnapshot(reason: "No model context"))
            return
        }

        switch scope {
        case .consolidated:
            snapshot = .consolidated(buildConsolidated(context: context))
        case .account(let id):
            snapshot = buildAccountScoped(context: context, accountId: id)
        }
    }

    // MARK: - Common transaction filters

    /// Predicate-friendly: date-window only. Other exclusions (transfers,
    /// duplicates, MSI parent purchases) happen in-memory because `Predicate`
    /// can't currently encode the necessary relationship traversals.
    private func windowedTransactions(context: ModelContext, accountId: UUID? = nil) -> [Transaction] {
        let start = dateRange.start
        let end = dateRange.end
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate<Transaction> { tx in
                tx.postedAt >= start && tx.postedAt <= end
            },
            sortBy: [SortDescriptor(\.postedAt, order: .reverse)]
        )
        let all = (try? context.fetch(descriptor)) ?? []
        guard let accountId else { return all }
        return all.filter { $0.account?.id == accountId }
    }

    /// Returns `true` when the transaction should NOT contribute to income/expense
    /// aggregates: duplicates, transfers, credit-card payments (both sides cancel),
    /// and the synthesized "original purchase" rows of MSI installments — those last
    /// ones are excluded because their cash impact is realized through monthly
    /// installments, which are separate transactions.
    private func excludedFromCashFlow(_ tx: Transaction) -> Bool {
        if tx.isDuplicate { return true }
        if tx.category?.kind == .transfer { return true }
        if tx.category?.kind == .creditCardPayment { return true }
        if let plan = tx.installmentPlan, abs(tx.amount) == abs(plan.originalAmount) {
            return true
        }
        return false
    }

    // MARK: - Consolidated

    private func buildConsolidated(context: ModelContext) -> ConsolidatedSnapshot {
        let transactions = windowedTransactions(context: context)

        let cashFlow = computeMonthlyCashFlow(transactions)
        let spending = computeSpendingByCategory(transactions, kindFilter: nil)
        let (income, expenses) = computeTotals(transactions)
        let interestEarned = computeInterestEarned(transactions)
        let interestCharged = computeInterestCharged(transactions)

        let (netWorth, netWorthSeries, accountSummaries) = computeNetWorth(context: context)

        return ConsolidatedSnapshot(
            netWorth: netWorth,
            netWorthOverTime: netWorthSeries,
            monthlyCashFlow: cashFlow,
            spendingByCategory: spending,
            totalIncome: income,
            totalExpenses: expenses,
            totalInterestEarned: interestEarned,
            totalInterestCharged: interestCharged,
            recentTransactions: transactions,
            accountSummaries: accountSummaries,
            totalTransactions: transactions.count
        )
    }

    // MARK: - Per-account

    private func buildAccountScoped(context: ModelContext, accountId: UUID) -> DashboardSnapshot {
        guard let account = fetchAccount(context: context, id: accountId) else {
            return .empty(EmptySnapshot(reason: "Account not found"))
        }

        let transactions = windowedTransactions(context: context, accountId: accountId)

        let latestStatement = latestStatement(context: context, accountId: accountId)
        let currentBalance = latestStatement?.closingBalance ?? 0

        switch account.type {
        case .creditCard:
            return .liability(buildLiability(
                context: context,
                account: account,
                transactions: transactions,
                latestStatement: latestStatement,
                currentBalance: currentBalance
            ))
        default:
            return .asset(buildAsset(
                context: context,
                account: account,
                transactions: transactions,
                latestStatement: latestStatement,
                currentBalance: currentBalance
            ))
        }
    }

    private func buildAsset(
        context: ModelContext,
        account: Account,
        transactions: [Transaction],
        latestStatement: Statement?,
        currentBalance: Decimal
    ) -> AssetAccountSnapshot {
        let cashFlow = computeMonthlyCashFlow(transactions)
        let spending = computeSpendingByCategory(transactions, kindFilter: nil)
        let (income, expenses) = computeTotals(transactions)
        let interestEarned = computeInterestEarned(transactions)
        let balanceSeries = computeBalanceSeries(context: context, accountId: account.id)

        return AssetAccountSnapshot(
            account: account,
            currentBalance: currentBalance,
            balanceOverTime: balanceSeries,
            monthlyCashFlow: cashFlow,
            spendingByCategory: spending,
            totalIncome: income,
            totalExpenses: expenses,
            totalInterestEarned: interestEarned,
            recentTransactions: transactions,
            totalTransactions: transactions.count
        )
    }

    private func buildLiability(
        context: ModelContext,
        account: Account,
        transactions: [Transaction],
        latestStatement: Statement?,
        currentBalance: Decimal
    ) -> LiabilityAccountSnapshot {
        let chargesVsPayments = computeChargesVsPayments(transactions)
        let spending = computeSpendingByCategory(transactions, kindFilter: nil)

        let totalCharges = transactions
            .filter { !$0.isDuplicate && $0.amount < 0 && $0.installmentPlan == nil && $0.category?.kind != .transfer && $0.category?.kind != .creditCardPayment }
            .reduce(Decimal(0)) { $0 + abs($1.amount) }
        let totalPayments = transactions
            .filter { !$0.isDuplicate && $0.amount > 0 && $0.category?.kind != .transfer }
            .reduce(Decimal(0)) { $0 + $1.amount }
        let interestCharged = latestStatement?.interestCharged ?? 0
        let feesCharged = (latestStatement?.feesCharged ?? 0) + (latestStatement?.ivaCharged ?? 0)

        let utilization: Double?
        if let limit = account.creditLimit, limit > 0 {
            let owed = (abs(currentBalance) as NSDecimalNumber).doubleValue
            let lim = (limit as NSDecimalNumber).doubleValue
            utilization = owed / lim
        } else {
            utilization = nil
        }

        let plans = fetchActiveInstallmentPlans(context: context, accountId: account.id)

        return LiabilityAccountSnapshot(
            account: account,
            currentBalance: currentBalance,
            creditLimit: account.creditLimit,
            utilizationPercent: utilization,
            latestStatement: latestStatement,
            chargesVsPayments: chargesVsPayments,
            spendingByCategory: spending,
            totalCharges: totalCharges,
            totalPayments: totalPayments,
            interestCharged: interestCharged,
            feesCharged: feesCharged,
            activeInstallmentPlans: plans,
            recentTransactions: transactions,
            totalTransactions: transactions.count
        )
    }

    // MARK: - Computations (kept compatible with the old VM)

    private func computeMonthlyCashFlow(_ transactions: [Transaction]) -> [MonthlyCashFlow] {
        let calendar = Calendar(identifier: .gregorian)
        var grouped: [Date: (income: Decimal, expenses: Decimal)] = [:]

        for tx in transactions {
            if excludedFromCashFlow(tx) { continue }
            let month = calendar.date(from: calendar.dateComponents([.year, .month], from: tx.postedAt))!
            let existing = grouped[month] ?? (0, 0)
            if tx.amount > 0 {
                grouped[month] = (existing.income + tx.amount, existing.expenses)
            } else {
                grouped[month] = (existing.income, existing.expenses + tx.amount)
            }
        }
        return grouped.map { month, values in
            MonthlyCashFlow(month: month, income: values.income, expenses: values.expenses)
        }.sorted { $0.month < $1.month }
    }

    private func computeChargesVsPayments(_ transactions: [Transaction]) -> [MonthlyChargesPayments] {
        let calendar = Calendar(identifier: .gregorian)
        var grouped: [Date: (charges: Decimal, payments: Decimal)] = [:]
        for tx in transactions {
            if tx.isDuplicate { continue }
            // For liabilities we DO want credit-card payments (they reduce debt) but NOT
            // generic transfers.
            if tx.category?.kind == .transfer { continue }
            // Skip the synthesized original MSI purchase; its monthly installments
            // already appear individually.
            if let plan = tx.installmentPlan, abs(tx.amount) == abs(plan.originalAmount) {
                continue
            }
            let month = calendar.date(from: calendar.dateComponents([.year, .month], from: tx.postedAt))!
            let existing = grouped[month] ?? (0, 0)
            if tx.amount < 0 {
                grouped[month] = (existing.charges + abs(tx.amount), existing.payments)
            } else {
                grouped[month] = (existing.charges, existing.payments + tx.amount)
            }
        }
        return grouped.map { MonthlyChargesPayments(month: $0.key, charges: $0.value.charges, payments: $0.value.payments) }
            .sorted { $0.month < $1.month }
    }

    private func computeSpendingByCategory(_ transactions: [Transaction], kindFilter: CategoryKind?) -> [CategorySpending] {
        var spending: [ObjectIdentifier: Decimal] = [:]
        var categoryMap: [ObjectIdentifier: Category] = [:]

        let uncategorizedSentinel = Category(name: "Uncategorized", kind: .expense)
        let uncategorizedKey = ObjectIdentifier(uncategorizedSentinel)
        categoryMap[uncategorizedKey] = uncategorizedSentinel

        for tx in transactions {
            if excludedFromCashFlow(tx) { continue }
            guard tx.amount < 0 else { continue }
            let key: ObjectIdentifier
            if let cat = tx.category {
                key = ObjectIdentifier(cat)
                categoryMap[key] = cat
            } else {
                key = uncategorizedKey
            }
            spending[key, default: 0] += abs(tx.amount)
        }

        return spending.map { key, amount in
            CategorySpending(category: categoryMap[key]!, amount: amount)
        }.sorted { $0.amount > $1.amount }
    }

    private func computeTotals(_ transactions: [Transaction]) -> (income: Decimal, expenses: Decimal) {
        var income: Decimal = 0
        var expenses: Decimal = 0
        for tx in transactions {
            if excludedFromCashFlow(tx) { continue }
            if tx.amount > 0 { income += tx.amount } else { expenses += tx.amount }
        }
        return (income, expenses)
    }

    private func computeInterestEarned(_ transactions: [Transaction]) -> Decimal {
        var total: Decimal = 0
        for tx in transactions {
            guard !tx.isDuplicate else { continue }
            if tx.category?.name == "Interest" && tx.amount > 0 {
                total += tx.amount
            }
        }
        return total
    }

    private func computeInterestCharged(_ transactions: [Transaction]) -> Decimal {
        var total: Decimal = 0
        for tx in transactions {
            guard !tx.isDuplicate else { continue }
            if tx.category?.name == "Interest Charges" && tx.amount < 0 {
                total += abs(tx.amount)
            }
        }
        return total
    }

    // MARK: - Net worth + balance series + account summaries

    private func computeNetWorth(context: ModelContext) -> (current: Decimal, series: [NetWorthPoint], summaries: [AccountSummary]) {
        let descriptor = FetchDescriptor<Statement>(sortBy: [SortDescriptor(\.periodEnd, order: .forward)])
        let statements = (try? context.fetch(descriptor)) ?? []

        let accountsDescriptor = FetchDescriptor<Account>(sortBy: [SortDescriptor(\.nickname)])
        let accounts = (try? context.fetch(accountsDescriptor)) ?? []

        var latestByAccount: [UUID: Statement] = [:]
        for stmt in statements {
            guard let accountId = stmt.account?.id else { continue }
            if let existing = latestByAccount[accountId] {
                if stmt.periodEnd > existing.periodEnd {
                    latestByAccount[accountId] = stmt
                }
            } else {
                latestByAccount[accountId] = stmt
            }
        }

        let current = latestByAccount.values.compactMap(\.closingBalance).reduce(Decimal(0), +)

        // Build account summaries: every Account, even those without a statement yet
        // (balance defaults to zero).
        let summaries: [AccountSummary] = accounts.map { account in
            let latest = latestByAccount[account.id]
            let balance = latest?.closingBalance ?? 0
            let util: Double?
            if account.type == .creditCard, let limit = account.creditLimit, limit > 0 {
                let owed = (abs(balance) as NSDecimalNumber).doubleValue
                let lim = (limit as NSDecimalNumber).doubleValue
                util = owed / lim
            } else {
                util = nil
            }
            return AccountSummary(
                id: account.id,
                displayName: account.displayName,
                institution: account.institution,
                type: account.type,
                currency: account.currency,
                latestBalance: balance,
                creditLimit: account.creditLimit,
                utilizationPercent: util
            )
        }

        let series = computeMonthlyNetWorth(statements: statements)
        return (current, series, summaries)
    }

    private func computeMonthlyNetWorth(statements: [Statement]) -> [NetWorthPoint] {
        guard !statements.isEmpty else { return [] }
        let calendar = Calendar(identifier: .gregorian)
        let allDates = statements.compactMap(\.periodEnd)
        guard let earliest = allDates.min(), let latest = allDates.max() else { return [] }
        var currentMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: earliest))!
        let endMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: latest))!

        var lastKnownBalance: [UUID: Decimal] = [:]
        var monthTotals: [Date: Decimal] = [:]
        while currentMonth <= endMonth {
            let nextMonth = calendar.date(byAdding: .month, value: 1, to: currentMonth)!
            for stmt in statements {
                guard let accountId = stmt.account?.id, let balance = stmt.closingBalance else { continue }
                if stmt.periodEnd >= currentMonth && stmt.periodEnd < nextMonth {
                    lastKnownBalance[accountId] = balance
                }
            }
            if !lastKnownBalance.isEmpty {
                monthTotals[currentMonth] = lastKnownBalance.values.reduce(0, +)
            }
            currentMonth = nextMonth
        }
        return monthTotals.map { NetWorthPoint(month: $0.key, balance: $0.value) }
            .sorted { $0.month < $1.month }
    }

    private func computeBalanceSeries(context: ModelContext, accountId: UUID) -> [NetWorthPoint] {
        let descriptor = FetchDescriptor<Statement>(
            predicate: #Predicate<Statement> { $0.account?.id == accountId },
            sortBy: [SortDescriptor(\.periodEnd, order: .forward)]
        )
        let statements = (try? context.fetch(descriptor)) ?? []
        return statements.compactMap { stmt in
            guard let balance = stmt.closingBalance else { return nil }
            return NetWorthPoint(month: stmt.periodEnd, balance: balance)
        }
    }

    // MARK: - Lookups

    private func fetchAccount(context: ModelContext, id: UUID) -> Account? {
        let descriptor = FetchDescriptor<Account>(predicate: #Predicate<Account> { $0.id == id })
        return try? context.fetch(descriptor).first
    }

    private func latestStatement(context: ModelContext, accountId: UUID) -> Statement? {
        var descriptor = FetchDescriptor<Statement>(
            predicate: #Predicate<Statement> { $0.account?.id == accountId },
            sortBy: [SortDescriptor(\.periodEnd, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func fetchActiveInstallmentPlans(context: ModelContext, accountId: UUID) -> [InstallmentPlan] {
        let descriptor = FetchDescriptor<InstallmentPlan>(
            predicate: #Predicate<InstallmentPlan> { $0.account?.id == accountId }
        )
        let all = (try? context.fetch(descriptor)) ?? []
        return all.filter { $0.currentMonth < $0.totalMonths }
    }
}
