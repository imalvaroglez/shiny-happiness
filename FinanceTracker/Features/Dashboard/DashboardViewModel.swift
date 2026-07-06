import SwiftUI
import SwiftData

struct MonthlyCashFlow: Identifiable {
    let month: Date
    let income: Decimal
    let expenses: Decimal
    var id: Date { month }
    var savings: Decimal { income + expenses }
}

struct CategorySpending: Identifiable {
    let category: Category
    let amount: Decimal
    var id: UUID { category.id }
}

private struct DashboardTransactionMetrics {
    let monthlyCashFlow: [MonthlyCashFlow]
    let spendingByCategory: [CategorySpending]
    let income: Decimal
    let expenses: Decimal
    let interestEarned: Decimal
    let interestCharged: Decimal
}

struct NetWorthPoint: Identifiable {
    let month: Date
    let balance: Decimal
    var id: Date { month }
}

private struct DashboardBalanceSampler {
    let account: Account
    let history: AccountBalanceHistory
    let points: [NetWorthPoint]
    let needsResolver: Bool

    var anchorDates: [Date] {
        history.anchors.map(\.date)
    }

    @MainActor
    func balance(asOf date: Date) -> Decimal? {
        if needsResolver {
            return AccountBalanceResolver.balance(account: account, asOf: date, history: history)
        }

        var low = 0
        var high = points.count
        while low < high {
            let mid = (low + high) / 2
            if points[mid].month <= date {
                low = mid + 1
            } else {
                high = mid
            }
        }

        guard low > 0 else { return nil }
        return points[low - 1].balance
    }

    @MainActor
    func resolution(asOf date: Date) -> AccountBalanceResolution {
        AccountBalanceResolver.resolution(account: account, asOf: date, history: history)
    }
}

@MainActor
@Observable
final class DashboardViewModel {
    var snapshot: DashboardSnapshot = .empty(EmptySnapshot(reason: "Loading…"))
    var dateRange: DateRange = DashboardPeriodKind.all.resolvedRange()
    var periodKind: DashboardPeriodKind = .all
    var scope: DashboardScope = .consolidated

    private var context: ModelContext?
    private let transactionClassifier = TransactionClassifier()
    private var balanceSamplerCache: [UUID: DashboardBalanceSampler] = [:]
    private var consolidatedTransactionCache: (range: DateRange, transactions: [Transaction])?
    private var reuseBalanceSamplerCacheOnNextRefresh = false
    private var periodNow: Date = .now

    func setPeriod(_ kind: DashboardPeriodKind, customRange: DateRange? = nil, now: Date = .now) {
        periodKind = kind
        periodNow = now
        dateRange = kind.resolvedRange(now: now, customRange: customRange)
        reuseBalanceSamplerCacheOnNextRefresh = true
    }

    func configure(context: ModelContext) {
        self.context = context
        balanceSamplerCache.removeAll()
        consolidatedTransactionCache = nil
        refresh()
    }

    func refresh() {
        guard let context else {
            snapshot = .empty(EmptySnapshot(reason: "No model context"))
            return
        }

        if !reuseBalanceSamplerCacheOnNextRefresh {
            balanceSamplerCache.removeAll()
            consolidatedTransactionCache = nil
        }
        reuseBalanceSamplerCacheOnNextRefresh = false

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

        if let cache = consolidatedTransactionCache,
           cache.range.start <= start,
           cache.range.end >= end {
            var transactions: [Transaction] = []
            for tx in cache.transactions {
                if tx.postedAt > end { continue }
                if tx.postedAt < start { break }
                transactions.append(tx)
            }
            return transactions
        }

        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate<Transaction> { tx in
                tx.postedAt >= start && tx.postedAt <= end && tx.deletedAt == nil && tx.account != nil
            },
            sortBy: [SortDescriptor(\.postedAt, order: .reverse)]
        )
        let transactions = (try? context.fetch(descriptor)) ?? []
        consolidatedTransactionCache = (DateRange(start: start, end: end), transactions)
        return transactions
    }

    private func isSynthesizedMSIPurchase(_ tx: Transaction) -> Bool {
        if let plan = tx.installmentPlan, abs(tx.amount) == abs(plan.originalAmount) {
            return true
        }
        return false
    }

    // MARK: - Consolidated

    private func buildConsolidated(context: ModelContext) -> ConsolidatedSnapshot {
        let accounts = fetchAccounts(context: context)
        let latestDataRange = fetchFinancialDateSpan(context: context, now: periodNow)
        let dataRange = periodKind == .all ? latestDataRange : nil
        let period = dashboardPeriodContext(context: context, dataRange: dataRange)
        let transactions = windowedTransactions(context: context)

        let metrics = computeTransactionMetrics(transactions, period: period)

        let netWorthAccounts = accounts.filter(\.effectiveIncludeInNetWorth)
        let (netWorth, netWorthSeries, accountSummaries, retirementAssets, liquidNetWorth, samplers) = computeNetWorth(
            context: context,
            period: period,
            accounts: netWorthAccounts,
            preloadedHistoryTransactions: period.kind == .all ? Array(transactions.reversed()) : nil
        )
        let latestAsOf = latestDataRange?.end ?? period.effectiveNetWorthDate
        let latestAccountSummaries = latestAsOf <= period.effectiveNetWorthDate
            ? accountSummaries
            : computeAccountSummaries(accounts: netWorthAccounts, samplers: samplers, asOf: latestAsOf)
        let latestNetWorth = latestAccountSummaries
            .filter { $0.balanceSourceKind != .insufficientHistory }
            .reduce(Decimal(0)) { $0 + $1.latestBalance }

        return ConsolidatedSnapshot(
            period: period,
            netWorth: netWorth,
            latestNetWorth: latestNetWorth,
            snapshotAsOfDate: latestAsOf,
            netWorthOverTime: netWorthSeries,
            monthlyCashFlow: metrics.monthlyCashFlow,
            spendingByCategory: metrics.spendingByCategory,
            totalIncome: metrics.income,
            totalExpenses: metrics.expenses,
            totalInterestEarned: metrics.interestEarned,
            totalInterestCharged: metrics.interestCharged,
            recentTransactions: transactions,
            accountSummaries: accountSummaries,
            latestAccountSummaries: latestAccountSummaries,
            totalTransactions: transactions.count,
            retirementAssets: retirementAssets,
            liquidNetWorth: liquidNetWorth
        )
    }

    // MARK: - Per-account

    private func buildAccountScoped(context: ModelContext, accountId: UUID) -> DashboardSnapshot {
        guard let account = fetchAccount(context: context, id: accountId) else {
            return .empty(EmptySnapshot(reason: "Account not found"))
        }

        let transactions = windowedTransactions(context: context, accountId: accountId)
        let period = dashboardPeriodContext(context: context)
        let balanceSampler = balanceSamplers(context: context, accounts: [account]).first

        let latestStatement = AccountBalanceResolver.latestStatement(accountId: accountId, context: context)
        let latestBalanceStatement = AccountBalanceResolver.latestBalanceStatement(accountId: accountId, context: context)
        let latestPaymentStatement = AccountBalanceResolver.latestPaymentStatement(accountId: accountId, context: context)
        let currentBalance = balanceSampler?.balance(asOf: period.effectiveNetWorthDate) ?? 0

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
                currentBalance: currentBalance,
                balanceSampler: balanceSampler
            ))
        }
    }

    private func buildAsset(
        context: ModelContext,
        period: DashboardPeriodContext,
        account: Account,
        transactions: [Transaction],
        latestStatement: Statement?,
        currentBalance: Decimal,
        balanceSampler: DashboardBalanceSampler?
    ) -> AssetAccountSnapshot {
        let metrics = computeTransactionMetrics(transactions, period: period)
        let balanceSeries = computeBalanceSeries(context: context, accountId: account.id, period: period, sampler: balanceSampler)
        let portfolio = account.type == .investment
            ? Self.buildPortfolioViewData(context: context, account: account, period: period)
            : nil

        return AssetAccountSnapshot(
            period: period,
            account: DashboardAccountIdentity(account),
            currentBalance: currentBalance,
            balanceOverTime: balanceSeries,
            monthlyCashFlow: metrics.monthlyCashFlow,
            spendingByCategory: metrics.spendingByCategory,
            totalIncome: metrics.income,
            totalExpenses: metrics.expenses,
            totalInterestEarned: metrics.interestEarned,
            recentTransactions: transactions,
            totalTransactions: transactions.count,
            portfolio: portfolio
        )
    }

    private static func buildPortfolioViewData(
        context: ModelContext,
        account: Account,
        period: DashboardPeriodContext
    ) -> PortfolioViewData {
        let active = PortfolioService.activePositions(accountID: account.id, context: context)
        let resolution = AccountBalanceResolver.resolution(
            account: account,
            asOf: period.effectiveNetWorthDate,
            context: context
        )
        let sourceIsValuation = resolution.sourceSnapshotKind == .portfolioValuation

        let currentFingerprint = HoldingsFingerprint.of(active.map { ($0.emisoraSerie, $0.shares, $0.averageCost) })
        let storedFingerprint = sourceIsValuation
            ? resolution.sourceSnapshotNote.flatMap { Self.portfolioFingerprint(from: $0) }
            : nil
        let matches = storedFingerprint == currentFingerprint

        let totalInvested = active.reduce(Decimal(0)) { $0 + ($1.shares * $1.averageCost) }
        let totalGrowth: Double?
        if sourceIsValuation, matches, totalInvested > 0 {
            totalGrowth = (((resolution.amount - totalInvested) / totalInvested) as NSDecimalNumber).doubleValue * 100
        } else {
            totalGrowth = nil
        }

        return PortfolioViewData(
            inPortfolioMode: !active.isEmpty,
            valuationAmount: sourceIsValuation ? resolution.amount : nil,
            valuationDate: sourceIsValuation ? resolution.sourceDate : nil,
            sourceIsPortfolioValuation: sourceIsValuation,
            holdingsFingerprintMatches: matches,
            totalInvested: totalInvested,
            totalGrowthPercent: totalGrowth,
            isPartialOrStale: false,
            rows: active.map {
                PortfolioViewData.PositionRow(
                    id: $0.id,
                    ticker: $0.emisoraSerie,
                    name: $0.name,
                    shares: $0.shares,
                    averageCost: $0.averageCost,
                    lastPrice: $0.lastPrice,
                    lastPriceAt: $0.lastPriceAt
                )
            }
        )
    }

    private static func portfolioFingerprint(from note: String) -> String? {
        guard let range = note.range(of: "fp=") else { return nil }
        return String(note[range.upperBound...])
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

    private func computeTransactionMetrics(_ transactions: [Transaction], period: DashboardPeriodContext) -> DashboardTransactionMetrics {
        let calendar = Calendar(identifier: .gregorian)
        let intervals = period.intervals(calendar: calendar)
        var grouped = Dictionary(uniqueKeysWithValues: intervals.map { ($0.bucketStart, (income: Decimal(0), expenses: Decimal(0))) })
        var hasIncludedTransaction = false
        var spending: [ObjectIdentifier: Decimal] = [:]
        var categoryMap: [ObjectIdentifier: Category] = [:]
        let uncategorizedSentinel = Category(name: "Uncategorized", kind: .expense)
        let uncategorizedKey = ObjectIdentifier(uncategorizedSentinel)
        categoryMap[uncategorizedKey] = uncategorizedSentinel
        var income: Decimal = 0
        var expenses: Decimal = 0
        var interestEarned: Decimal = 0
        var interestCharged: Decimal = 0

        for tx in transactions {
            let classification = transactionClassifier.classify(transaction: tx)

            if classification.countsAsRegularIncome { income += tx.amount }
            if classification.countsAsRegularExpense { expenses += tx.amount }

            if classification.countsAsRegularIncome || classification.countsAsRegularExpense {
                let bucketStart = period.bucket.start(for: tx.postedAt, calendar: calendar)
                if grouped[bucketStart] != nil {
                    hasIncludedTransaction = true
                    let existing = grouped[bucketStart] ?? (0, 0)
                    if classification.countsAsRegularIncome {
                        grouped[bucketStart] = (existing.income + tx.amount, existing.expenses)
                    } else if classification.countsAsRegularExpense {
                        grouped[bucketStart] = (existing.income, existing.expenses + tx.amount)
                    }
                }
            }

            if classification.countsAsRegularExpense {
                let key: ObjectIdentifier
                if let cat = tx.category, cat.deletedAt == nil {
                    key = ObjectIdentifier(cat)
                    categoryMap[key] = cat
                } else {
                    key = uncategorizedKey
                }
                spending[key, default: 0] += abs(tx.amount)
            }

            if !tx.isDuplicate {
                if tx.category?.name == "Interest", tx.amount > 0, !classification.countsAsInvestmentReturn {
                    interestEarned += tx.amount
                }
                if tx.category?.name == "Interest Charges", tx.amount < 0 {
                    interestCharged += abs(tx.amount)
                }
            }
        }

        let cashFlow: [MonthlyCashFlow] = hasIncludedTransaction
            ? intervals.map { interval in
                let values = grouped[interval.bucketStart] ?? (0, 0)
                return MonthlyCashFlow(month: interval.bucketStart, income: values.income, expenses: values.expenses)
            }
            : []
        let categorySpending = spending.map { key, amount in
            CategorySpending(category: categoryMap[key]!, amount: amount)
        }.sorted { $0.amount > $1.amount }

        return DashboardTransactionMetrics(
            monthlyCashFlow: cashFlow,
            spendingByCategory: categorySpending,
            income: income,
            expenses: expenses,
            interestEarned: interestEarned,
            interestCharged: interestCharged
        )
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
            guard transactionClassifier.classify(transaction: tx).countsAsRegularExpense else { continue }
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

    // MARK: - Net worth + balance series + account summaries

    private func computeNetWorth(
        context: ModelContext,
        period: DashboardPeriodContext,
        accounts: [Account],
        preloadedHistoryTransactions: [Transaction]? = nil
    ) -> (
        current: Decimal,
        series: [NetWorthPoint],
        summaries: [AccountSummary],
        retirementAssets: Decimal,
        liquidNetWorth: Decimal,
        samplers: [DashboardBalanceSampler]
    ) {
        let samplers = balanceSamplers(
            context: context,
            accounts: accounts,
            preloadedHistoryTransactions: preloadedHistoryTransactions
        )
        let samplersByAccountID = Dictionary(uniqueKeysWithValues: samplers.map { ($0.account.id, $0) })

        let resolutionsByAccount = Dictionary(uniqueKeysWithValues: accounts.map { account in
            let resolution = samplersByAccountID[account.id]?.resolution(asOf: period.effectiveNetWorthDate)
                ?? AccountBalanceResolver.resolution(account: account, asOf: period.effectiveNetWorthDate, context: context)
            return (account.id, resolution)
        })
        let current = resolutionsByAccount.values.reduce(Decimal(0)) { partial, resolution in
            resolution.sourceKind == .insufficientHistory ? partial : partial + resolution.amount
        }

        let summaries = accountSummaries(for: accounts, resolutionsByAccount: resolutionsByAccount, asOf: period.effectiveNetWorthDate)

        // Liquid Net Worth and Retirement Assets use the same insufficient-history
        // guard as `current` above: accounts we can't resolve are excluded.
        let knownSummaries = summaries.filter { $0.balanceSourceKind != .insufficientHistory }
        let retirementAssets = knownSummaries
            .filter { $0.type == .retirement }
            .reduce(Decimal(0)) { $0 + $1.latestBalance }
        let liquidNetWorth = knownSummaries
            .filter { $0.isLiability || (!$0.isLiability && $0.type != .retirement && $0.liquidity == .liquid) }
            .reduce(Decimal(0)) { $0 + $1.latestBalance }

        let knownAccountIDs = Set(knownSummaries.map(\.id))
        let series = computeMonthlyNetWorth(samplers: samplers.filter { knownAccountIDs.contains($0.account.id) }, period: period)
        return (current, series, summaries, retirementAssets, liquidNetWorth, samplers)
    }

    private func computeAccountSummaries(context: ModelContext, asOf: Date) -> [AccountSummary] {
        let accounts = fetchAccounts(context: context).filter(\.effectiveIncludeInNetWorth)
        let samplers = balanceSamplers(context: context, accounts: accounts)
        return computeAccountSummaries(accounts: accounts, samplers: samplers, asOf: asOf)
    }

    private func computeAccountSummaries(
        accounts: [Account],
        samplers: [DashboardBalanceSampler],
        asOf: Date
    ) -> [AccountSummary] {
        let samplersByAccountID = Dictionary(uniqueKeysWithValues: samplers.map { ($0.account.id, $0) })
        let resolutionsByAccount = Dictionary(uniqueKeysWithValues: accounts.map { account in
            let resolution = samplersByAccountID[account.id]?.resolution(asOf: asOf)
                ?? AccountBalanceResolution(asOf: asOf, amount: 0, sourceKind: .insufficientHistory, sourceDate: nil)
            return (account.id, resolution)
        })
        return accountSummaries(for: accounts, resolutionsByAccount: resolutionsByAccount, asOf: asOf)
    }

    private func accountSummaries(
        for accounts: [Account],
        resolutionsByAccount: [UUID: AccountBalanceResolution],
        asOf: Date
    ) -> [AccountSummary] {
        return accounts.map { account in
            let resolution = resolutionsByAccount[account.id] ?? AccountBalanceResolution(
                asOf: asOf,
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
                utilizationPercent: util,
                liquidity: account.liquidity,
                retirementKind: account.retirementKind
            )
        }
    }

    private func computeMonthlyNetWorth(samplers: [DashboardBalanceSampler], period: DashboardPeriodContext) -> [NetWorthPoint] {
        guard !samplers.isEmpty else { return [] }
        let sampleDates = balanceSampleDates(samplers: samplers, period: period)

        return sampleDates.compactMap { date in
            var hasKnownBalance = false
            let total = samplers.reduce(Decimal(0)) { partial, sampler in
                guard let balance = sampler.balance(asOf: date) else {
                    return partial
                }
                hasKnownBalance = true
                return partial + balance
            }
            return hasKnownBalance ? NetWorthPoint(month: date, balance: total) : nil
        }
    }

    private func computeBalanceSeries(context: ModelContext, accountId: UUID, period: DashboardPeriodContext, sampler providedSampler: DashboardBalanceSampler? = nil) -> [NetWorthPoint] {
        let sampler: DashboardBalanceSampler?
        if let providedSampler {
            sampler = providedSampler
        } else if let account = fetchAccount(context: context, id: accountId) {
            sampler = balanceSamplers(context: context, accounts: [account]).first
        } else {
            sampler = nil
        }
        guard let sampler else { return [] }
        let sampleDates = balanceSampleDates(samplers: [sampler], period: period)

        return sampleDates.compactMap { date in
            guard let balance = sampler.balance(asOf: date) else {
                return nil
            }
            return NetWorthPoint(month: date, balance: balance)
        }
    }

    private func balanceSamplers(
        context: ModelContext,
        accounts: [Account],
        preloadedHistoryTransactions: [Transaction]? = nil
    ) -> [DashboardBalanceSampler] {
        let uncachedAccounts = accounts.filter { balanceSamplerCache[$0.id] == nil }
        let histories = AccountBalanceResolver.histories(
            accounts: uncachedAccounts,
            context: context,
            preloadedHistoryTransactions: preloadedHistoryTransactions
        )

        let samplers = accounts.map { account in
            if let cached = balanceSamplerCache[account.id] {
                return cached
            }
            let history = histories[account.id] ?? AccountBalanceHistory(anchors: [], transactions: [])
            let sampler = DashboardBalanceSampler(
                account: account,
                history: history,
                points: AccountBalanceResolver.balanceSeries(account: account, history: history),
                needsResolver: history.anchors.contains {
                    if case .manualSnapshot(let snapshot) = $0.source {
                        return snapshot.kind == .portfolioValuation
                    }
                    return false
                }
            )
            balanceSamplerCache[account.id] = sampler
            return sampler
        }
        return samplers
    }

    private func balanceSampleDates(samplers: [DashboardBalanceSampler], period: DashboardPeriodContext) -> [Date] {
        let calendar = Calendar(identifier: .gregorian)
        let periodDates = [period.dateRange.start, period.dateRange.end] + period.intervals(calendar: calendar).map(\.end)
        let anchorDates = samplers.flatMap(\.anchorDates)

        return Array(Set(periodDates + anchorDates))
            .filter { period.dateRange.contains($0) }
            .sorted()
    }

    // MARK: - Period metadata

    private func dashboardPeriodContext(context: ModelContext) -> DashboardPeriodContext {
        dashboardPeriodContext(context: context, dataRange: nil)
    }

    private func dashboardPeriodContext(context: ModelContext, dataRange providedDataRange: DateRange?) -> DashboardPeriodContext {
        let now = dateRange.end
        let dataRange = periodKind == .all ? (providedDataRange ?? fetchFinancialDateSpan(context: context, now: now)) : nil
        return DashboardPeriodResolver.context(
            kind: periodKind,
            requestedRange: dateRange,
            dataRange: dataRange,
            now: now
        )
    }

    private func fetchFinancialDateSpan(context: ModelContext, now: Date = .now) -> DateRange? {
        let dates = [
            financialTransactionDate(context: context, now: now, latest: false),
            financialTransactionDate(context: context, now: now, latest: true),
            financialStatementDate(context: context, now: now, latest: false),
            financialStatementDate(context: context, now: now, latest: true),
            financialSnapshotDate(context: context, now: now, latest: false),
            financialSnapshotDate(context: context, now: now, latest: true)
        ].compactMap(\.self)

        guard let start = dates.min(), let end = dates.max() else { return nil }
        return DateRange(start: start, end: end)
    }

    private func financialTransactionDate(context: ModelContext, now: Date, latest: Bool) -> Date? {
        let predicate = #Predicate<Transaction> { tx in
            tx.postedAt <= now && tx.deletedAt == nil && tx.account != nil
        }
        var descriptor = latest
            ? FetchDescriptor<Transaction>(predicate: predicate, sortBy: [SortDescriptor(\.postedAt, order: .reverse)])
            : FetchDescriptor<Transaction>(predicate: predicate, sortBy: [SortDescriptor(\.postedAt)])
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first?.postedAt
    }

    private func financialStatementDate(context: ModelContext, now: Date, latest: Bool) -> Date? {
        let predicate = #Predicate<Statement> { statement in
            statement.periodEnd <= now && statement.account != nil
        }
        var descriptor = latest
            ? FetchDescriptor<Statement>(predicate: predicate, sortBy: [SortDescriptor(\.periodEnd, order: .reverse)])
            : FetchDescriptor<Statement>(predicate: predicate, sortBy: [SortDescriptor(\.periodEnd)])
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first?.periodEnd
    }

    private func financialSnapshotDate(context: ModelContext, now: Date, latest: Bool) -> Date? {
        let predicate = #Predicate<AccountBalanceSnapshot> { snapshot in
            snapshot.date <= now && snapshot.account != nil
        }
        var descriptor = latest
            ? FetchDescriptor<AccountBalanceSnapshot>(predicate: predicate, sortBy: [SortDescriptor(\.date, order: .reverse)])
            : FetchDescriptor<AccountBalanceSnapshot>(predicate: predicate, sortBy: [SortDescriptor(\.date)])
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first?.date
    }

    // MARK: - Lookups

    private func fetchAccounts(context: ModelContext) -> [Account] {
        let descriptor = FetchDescriptor<Account>(sortBy: [SortDescriptor(\.nickname)])
        return (try? context.fetch(descriptor)) ?? []
    }

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
