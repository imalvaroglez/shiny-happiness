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
                tx.postedAt >= start && tx.postedAt <= end && tx.deletedAt == nil
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
        if tx.isTransfer { return true }
        if tx.category?.kind == .transfer { return true }
        if tx.category?.kind == .creditCardPayment { return true }
        if isOwnAccountMovement(tx) { return true }
        return isSynthesizedMSIPurchase(tx)
    }

    private func isSynthesizedMSIPurchase(_ tx: Transaction) -> Bool {
        if let plan = tx.installmentPlan, abs(tx.amount) == abs(plan.originalAmount) {
            return true
        }
        return false
    }

    private static let ownAccountPatterns: [String] = [
        "(?i)PAGO\\s+RECIBIDO\\s+DE\\s+STP\\s+POR\\s+ORDEN\\s+DE\\s+TITULAR",
        "(?i)recibida\\s+(de\\s+la\\s+)?cuenta\\s+4444\\s+BANAMEX",
        "(?i)PAGO\\s+INTERBANCARIO\\s+PAGO\\s+RECIBIDO\\s+DE.*STP.*TITULAR",
    ]

    private func isOwnAccountMovement(_ tx: Transaction) -> Bool {
        Self.ownAccountPatterns.contains {
            tx.descriptionRaw.range(of: $0, options: .regularExpression) != nil
        }
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

        let latestStatement = AccountBalanceResolver.latestStatement(accountId: accountId, context: context)
        let currentBalance = AccountBalanceResolver.currentBalance(account: account, context: context)

        switch account.type {
        case .creditCard, .loan:
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
            .filter { !$0.isDuplicate && $0.amount < 0 && !isSynthesizedMSIPurchase($0) }
            .reduce(Decimal(0)) { $0 + abs($1.amount) }
        let totalPayments = transactions
            .filter { !$0.isDuplicate && $0.amount > 0 }
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
        let sourceStatements = fetchSourceStatements(context: context, accountId: account.id)

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
            sourceStatements: sourceStatements,
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
            if isSynthesizedMSIPurchase(tx) { continue }
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
            if let cat = tx.category, cat.deletedAt == nil {
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
        let accountsDescriptor = FetchDescriptor<Account>(sortBy: [SortDescriptor(\.nickname)])
        let accounts = (try? context.fetch(accountsDescriptor)) ?? []

        let balancesByAccount = Dictionary(uniqueKeysWithValues: accounts.map { account in
            (account.id, AccountBalanceResolver.currentBalance(account: account, context: context))
        })
        let current = balancesByAccount.values.reduce(Decimal(0), +)

        // Build account summaries: every Account, even those without a statement yet
        // (balance defaults to zero).
        let summaries: [AccountSummary] = accounts.map { account in
            let balance = balancesByAccount[account.id] ?? 0
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

        let series = computeMonthlyNetWorth(context: context, accounts: accounts)
        return (current, series, summaries)
    }

    private func computeMonthlyNetWorth(context: ModelContext, accounts: [Account]) -> [NetWorthPoint] {
        let accountSeries = accounts.map { AccountBalanceResolver.balanceSeries(account: $0, context: context) }
        let calendar = Calendar(identifier: .gregorian)

        var monthSet = Set<Date>()
        for series in accountSeries {
            for point in series {
                let month = calendar.date(from: calendar.dateComponents([.year, .month], from: point.month))!
                monthSet.insert(month)
            }
        }
        let months = monthSet.sorted()
        guard !months.isEmpty else { return [] }

        var latestByAccount: [UUID: Decimal] = [:]
        var result: [NetWorthPoint] = []
        for month in months {
            for (index, series) in accountSeries.enumerated() {
                guard index < accounts.count else { continue }
                if let point = series.last(where: { calendar.date(from: calendar.dateComponents([.year, .month], from: $0.month))! <= month }) {
                    latestByAccount[accounts[index].id] = point.balance
                }
            }
            let total = latestByAccount.values.reduce(Decimal(0), +)
            result.append(NetWorthPoint(month: month, balance: total))
        }
        return result
    }

    private func computeBalanceSeries(context: ModelContext, accountId: UUID) -> [NetWorthPoint] {
        guard let account = fetchAccount(context: context, id: accountId) else { return [] }
        return AccountBalanceResolver.balanceSeries(account: account, context: context)
    }

    // MARK: - Lookups

    private func fetchAccount(context: ModelContext, id: UUID) -> Account? {
        let descriptor = FetchDescriptor<Account>(predicate: #Predicate<Account> { $0.id == id })
        return try? context.fetch(descriptor).first
    }

    private func fetchActiveInstallmentPlans(context: ModelContext, accountId: UUID) -> [InstallmentPlan] {
        let descriptor = FetchDescriptor<InstallmentPlan>(
            predicate: #Predicate<InstallmentPlan> { $0.account?.id == accountId }
        )
        let all = (try? context.fetch(descriptor)) ?? []
        return all.filter { $0.currentMonth < $0.totalMonths }
    }

    private func fetchSourceStatements(context: ModelContext, accountId: UUID) -> [StatementSourceSummary] {
        let descriptor = FetchDescriptor<Statement>(
            predicate: #Predicate<Statement> { $0.account?.id == accountId },
            sortBy: [SortDescriptor(\.periodEnd, order: .reverse)]
        )
        let statements = (try? context.fetch(descriptor)) ?? []
        return statements.map { stmt in
            StatementSourceSummary(
                id: stmt.id,
                sourceFileName: stmt.sourceFileName,
                sourceFileHash: stmt.sourceFileHash,
                periodStart: stmt.periodStart,
                periodEnd: stmt.periodEnd,
                importedAt: stmt.importedAt,
                hasDueDate: stmt.paymentDueDate != nil,
                hasMinimumPayment: stmt.minimumPayment != nil,
                hasNoInterestPayment: stmt.paymentForNoInterest != nil
            )
        }
    }
}
