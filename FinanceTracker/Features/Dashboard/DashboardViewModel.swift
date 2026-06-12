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
    var dateRange: DateRange = DashboardPeriodKind.all.resolvedRange()
    var periodKind: DashboardPeriodKind = .all
    var scope: DashboardScope = .consolidated

    private var context: ModelContext?

    func setPeriod(_ kind: DashboardPeriodKind, customRange: DateRange? = nil, now: Date = .now) {
        periodKind = kind
        dateRange = kind.resolvedRange(now: now, customRange: customRange)
    }

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
        if let accountId {
            let descriptor = FetchDescriptor<Transaction>(
                predicate: #Predicate<Transaction> { tx in
                    tx.postedAt >= start
                        && tx.postedAt <= end
                        && tx.deletedAt == nil
                        && tx.account?.id == accountId
                },
                sortBy: [SortDescriptor(\.postedAt, order: .reverse)]
            )
            return (try? context.fetch(descriptor)) ?? []
        }

        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate<Transaction> { tx in
                tx.postedAt >= start && tx.postedAt <= end && tx.deletedAt == nil
            },
            sortBy: [SortDescriptor(\.postedAt, order: .reverse)]
        )
        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        guard !accounts.isEmpty else { return [] }
        let fetched = (try? context.fetch(descriptor)) ?? []
        let validIDs = Set(accounts.map(\.id))
        return fetched.filter { validIDs.contains($0.account?.id ?? UUID()) }
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
        if tx.account?.type.isLiability == true && tx.amount > 0 { return true }
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
        let period = dashboardPeriodContext(context: context)
        let transactions = windowedTransactions(context: context)

        let cashFlow = computeMonthlyCashFlow(transactions, period: period)
        let spending = computeSpendingByCategory(transactions, kindFilter: nil)
        let (income, expenses) = computeTotals(transactions)
        let interestEarned = computeInterestEarned(transactions)
        let interestCharged = computeInterestCharged(transactions)

        let (netWorth, netWorthSeries, accountSummaries) = computeNetWorth(context: context, period: period)

        return ConsolidatedSnapshot(
            period: period,
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
        let period = dashboardPeriodContext(context: context)

        let latestStatement = AccountBalanceResolver.latestStatement(accountId: accountId, context: context)
        let latestBalanceStatement = AccountBalanceResolver.latestBalanceStatement(accountId: accountId, context: context)
        let latestPaymentStatement = AccountBalanceResolver.latestPaymentStatement(accountId: accountId, context: context)
        let currentBalance = AccountBalanceResolver.balance(account: account, asOf: period.effectiveNetWorthDate, context: context) ?? 0

        switch account.type {
        case .creditCard, .loan:
            return .liability(buildLiability(
                context: context,
                period: period,
                account: account,
                transactions: transactions,
                latestBalanceStatement: latestBalanceStatement,
                latestPaymentStatement: latestPaymentStatement,
                currentBalance: currentBalance
            ))
        default:
            return .asset(buildAsset(
                context: context,
                period: period,
                account: account,
                transactions: transactions,
                latestStatement: latestStatement,
                currentBalance: currentBalance
            ))
        }
    }

    private func buildAsset(
        context: ModelContext,
        period: DashboardPeriodContext,
        account: Account,
        transactions: [Transaction],
        latestStatement: Statement?,
        currentBalance: Decimal
    ) -> AssetAccountSnapshot {
        let cashFlow = computeMonthlyCashFlow(transactions, period: period)
        let spending = computeSpendingByCategory(transactions, kindFilter: nil)
        let (income, expenses) = computeTotals(transactions)
        let interestEarned = computeInterestEarned(transactions)
        let balanceSeries = computeBalanceSeries(context: context, accountId: account.id, period: period)

        return AssetAccountSnapshot(
            period: period,
            account: DashboardAccountIdentity(account),
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
        period: DashboardPeriodContext,
        account: Account,
        transactions: [Transaction],
        latestBalanceStatement: Statement?,
        latestPaymentStatement: Statement?,
        currentBalance: Decimal
    ) -> LiabilityAccountSnapshot {
        let chargesVsPayments = computeChargesVsPayments(transactions, period: period)
        let spending = computeSpendingByCategory(transactions, kindFilter: nil)

        let totalCharges = transactions
            .filter { !$0.isDuplicate && $0.amount < 0 && !isSynthesizedMSIPurchase($0) }
            .reduce(Decimal(0)) { $0 + abs($1.amount) }
        let totalPayments = transactions
            .filter { !$0.isDuplicate && $0.amount > 0 }
            .reduce(Decimal(0)) { $0 + $1.amount }
        let interestCharged = latestBalanceStatement?.interestCharged ?? 0
        let feesCharged = (latestBalanceStatement?.feesCharged ?? 0) + (latestBalanceStatement?.ivaCharged ?? 0)

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
            period: period,
            account: DashboardAccountIdentity(account),
            currentBalance: currentBalance,
            creditLimit: account.creditLimit,
            utilizationPercent: utilization,
            paymentStatement: latestPaymentStatement,
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

    private func computeMonthlyCashFlow(_ transactions: [Transaction], period: DashboardPeriodContext) -> [MonthlyCashFlow] {
        let calendar = Calendar(identifier: .gregorian)
        let intervals = period.intervals(calendar: calendar)
        var grouped = Dictionary(uniqueKeysWithValues: intervals.map { ($0.bucketStart, (income: Decimal(0), expenses: Decimal(0))) })
        var hasIncludedTransaction = false

        for tx in transactions {
            if excludedFromCashFlow(tx) { continue }
            let bucketStart = period.bucket.start(for: tx.postedAt, calendar: calendar)
            guard grouped[bucketStart] != nil else { continue }
            hasIncludedTransaction = true
            let existing = grouped[bucketStart] ?? (0, 0)
            if tx.amount > 0 {
                grouped[bucketStart] = (existing.income + tx.amount, existing.expenses)
            } else {
                grouped[bucketStart] = (existing.income, existing.expenses + tx.amount)
            }
        }

        guard hasIncludedTransaction else { return [] }
        return intervals.map { interval in
            let values = grouped[interval.bucketStart] ?? (0, 0)
            return MonthlyCashFlow(month: interval.bucketStart, income: values.income, expenses: values.expenses)
        }
    }

    private func computeChargesVsPayments(_ transactions: [Transaction], period: DashboardPeriodContext) -> [MonthlyChargesPayments] {
        let calendar = Calendar(identifier: .gregorian)
        let intervals = period.intervals(calendar: calendar)
        var grouped = Dictionary(uniqueKeysWithValues: intervals.map { ($0.bucketStart, (charges: Decimal(0), payments: Decimal(0))) })
        var hasIncludedTransaction = false

        for tx in transactions {
            if tx.isDuplicate { continue }
            if isSynthesizedMSIPurchase(tx) { continue }
            let bucketStart = period.bucket.start(for: tx.postedAt, calendar: calendar)
            guard grouped[bucketStart] != nil else { continue }
            hasIncludedTransaction = true
            let existing = grouped[bucketStart] ?? (0, 0)
            if tx.amount < 0 {
                grouped[bucketStart] = (existing.charges + abs(tx.amount), existing.payments)
            } else {
                grouped[bucketStart] = (existing.charges, existing.payments + tx.amount)
            }
        }

        guard hasIncludedTransaction else { return [] }
        return intervals.map { interval in
            let values = grouped[interval.bucketStart] ?? (0, 0)
            return MonthlyChargesPayments(month: interval.bucketStart, charges: values.charges, payments: values.payments)
        }
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

    private func computeNetWorth(context: ModelContext, period: DashboardPeriodContext) -> (current: Decimal, series: [NetWorthPoint], summaries: [AccountSummary]) {
        let accountsDescriptor = FetchDescriptor<Account>(sortBy: [SortDescriptor(\.nickname)])
        let accounts = (try? context.fetch(accountsDescriptor)) ?? []

        let resolutionsByAccount = Dictionary(uniqueKeysWithValues: accounts.map { account in
            (account.id, AccountBalanceResolver.resolution(account: account, asOf: period.effectiveNetWorthDate, context: context))
        })
        let current = resolutionsByAccount.values.reduce(Decimal(0)) { partial, resolution in
            resolution.sourceKind == .insufficientHistory ? partial : partial + resolution.amount
        }

        // Build account summaries: every Account, even those without a statement yet
        // (balance defaults to zero).
        let summaries: [AccountSummary] = accounts.map { account in
            let resolution = resolutionsByAccount[account.id] ?? AccountBalanceResolution(
                asOf: period.effectiveNetWorthDate,
                amount: 0,
                sourceKind: .insufficientHistory,
                sourceDate: nil
            )
            let balance = resolution.amount
            let util: Double?
            if resolution.sourceKind != .insufficientHistory,
               account.type == .creditCard,
               let limit = account.creditLimit,
               limit > 0 {
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
                balanceAsOf: resolution.asOf,
                balanceSourceKind: resolution.sourceKind,
                balanceSourceDate: resolution.sourceDate,
                creditLimit: account.creditLimit,
                utilizationPercent: util
            )
        }

        let series = computeMonthlyNetWorth(context: context, accounts: accounts, period: period)
        return (current, series, summaries)
    }

    private func computeMonthlyNetWorth(context: ModelContext, accounts: [Account], period: DashboardPeriodContext) -> [NetWorthPoint] {
        let calendar = Calendar(identifier: .gregorian)
        let intervals = period.intervals(calendar: calendar)
        guard !intervals.isEmpty else { return [] }

        return intervals.compactMap { interval in
            var hasKnownBalance = false
            let total = accounts.reduce(Decimal(0)) { partial, account in
                guard let balance = AccountBalanceResolver.balance(account: account, asOf: interval.end, context: context) else {
                    return partial
                }
                hasKnownBalance = true
                return partial + balance
            }
            return hasKnownBalance ? NetWorthPoint(month: interval.end, balance: total) : nil
        }
    }

    private func computeBalanceSeries(context: ModelContext, accountId: UUID, period: DashboardPeriodContext) -> [NetWorthPoint] {
        guard let account = fetchAccount(context: context, id: accountId) else { return [] }
        let calendar = Calendar(identifier: .gregorian)
        return period.intervals(calendar: calendar).compactMap { interval in
            guard let balance = AccountBalanceResolver.balance(account: account, asOf: interval.end, context: context) else {
                return nil
            }
            return NetWorthPoint(month: interval.end, balance: balance)
        }
    }

    // MARK: - Period metadata

    private func dashboardPeriodContext(context: ModelContext) -> DashboardPeriodContext {
        DashboardPeriodResolver.context(
            kind: periodKind,
            requestedRange: dateRange,
            dataRange: fetchFinancialDateSpan(context: context)
        )
    }

    private func fetchFinancialDateSpan(context: ModelContext) -> DateRange? {
        let now = Date.now
        var dates: [Date] = []

        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        guard !accounts.isEmpty else { return nil }
        let validIDs = Set(accounts.map(\.id))

        let transactionDescriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate<Transaction> { $0.postedAt <= now && $0.deletedAt == nil }
        )
        let transactions = (try? context.fetch(transactionDescriptor)) ?? []
        dates.append(contentsOf: transactions.filter { validIDs.contains($0.account?.id ?? UUID()) }.map(\.postedAt))

        let statementDescriptor = FetchDescriptor<Statement>(
            predicate: #Predicate<Statement> { $0.periodEnd <= now }
        )
        let statements = (try? context.fetch(statementDescriptor)) ?? []
        dates.append(contentsOf: statements.filter { validIDs.contains($0.account?.id ?? UUID()) }.map(\.periodEnd))

        let snapshotDescriptor = FetchDescriptor<AccountBalanceSnapshot>(
            predicate: #Predicate<AccountBalanceSnapshot> { $0.date <= now }
        )
        let snapshots = (try? context.fetch(snapshotDescriptor)) ?? []
        dates.append(contentsOf: snapshots.filter { validIDs.contains($0.account?.id ?? UUID()) }.map(\.date))

        guard let start = dates.min(), let end = dates.max() else { return nil }
        return DateRange(start: start, end: end)
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
        return statements
            .filter { !PaymentMetadataService.isMetadataStatement($0) }
            .map { stmt in
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
