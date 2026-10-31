import SwiftUI
import SwiftData

/// Drill-down requests from the dashboard. Every case carries the source
/// material needed to render its breakdown sheet — no extra fetches required.
enum BreakdownRequest: Identifiable {
    case netWorth(period: DashboardPeriodContext, accounts: [AccountSummary])
    case income(transactions: [Transaction], total: Decimal, interestAllocations: [InterestDailyAllocation], interestSources: [Transaction])
    case expenses(transactions: [Transaction], total: Decimal)
    case interest(total: Decimal, allocations: [InterestDailyAllocation], sources: [Transaction])
    case cashFlowPeriod(
        start: Date,
        bucket: DashboardBucket,
        transactions: [Transaction],
        interestAllocations: [InterestDailyAllocation],
        interestSources: [Transaction],
        matchedCardPaymentIDs: Set<UUID>,
        hasUnmatchedCardPayment: Bool
    )
    case categorySpending(category: Category, amount: Decimal, transactions: [Transaction])
    case categoryList(entries: [CategorySpending], currencyCode: String, transactions: [Transaction])

    var id: String {
        switch self {
        case .netWorth(let period, _): return "net-worth-\(period.effectiveNetWorthDate)"
        case .income: return "income"
        case .expenses: return "expenses"
        case .interest: return "interest"
        case .cashFlowPeriod(let start, _, _, _, _, _, _): return "cash-flow-\(start)"
        case .categorySpending(let cat, _, _): return "category-\(cat.id)"
        case .categoryList: return "category-list"
        }
    }

    var title: String {
        switch self {
        case .netWorth(let period, _):
            return "Net Worth as of \(NetWorthBreakdownCopy.titleDate(period.effectiveNetWorthDate))"
        case .income: return "Income"
        case .expenses: return "Expenses"
        case .interest: return "Interest Earned"
        case .cashFlowPeriod(let start, let bucket, _, _, _, _, _):
            return dashboardBucketLabel(for: start, bucket: bucket)
        case .categorySpending(let cat, _, _): return cat.localizedName
        case .categoryList: return String(localized: "Category Breakdown")
        }
    }
}

enum NetWorthBreakdownCopy {
    static func subtitle(for period: DashboardPeriodContext) -> String {
        "Point-in-time account balances. This is not a sum of transactions during \(periodRange(period.dateRange))."
    }

    static func sourceText(_ summary: AccountSummary) -> String {
        let asOf = compactDate(summary.balanceAsOf)
        switch summary.balanceSourceKind {
        case .exactBalanceSnapshot:
            return "Snapshot on \(asOf)"
        case .latestPriorBalanceSnapshot:
            return "Using latest balance snapshot before \(asOf) · Snapshot date: \(sourceDateText(summary.balanceSourceDate))"
        case .reconstructedBalance:
            if let sourceDate = summary.balanceSourceDate {
                return "Balance reconstructed up to \(asOf) · Starting snapshot: \(compactDate(sourceDate))"
            }
            return "Balance estimated from available transactions up to \(asOf) · No starting balance snapshot"
        case .insufficientHistory:
            return "Insufficient balance history before \(asOf)"
        }
    }

    static func titleDate(_ date: Date) -> String {
        format(date, pattern: "d MMMM yyyy")
    }

    static func compactDate(_ date: Date) -> String {
        format(date, pattern: "d MMM yyyy")
    }

    static func periodRange(_ range: DateRange) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.startOfDay(for: range.start)
        let end = calendar.startOfDay(for: range.end)

        let startYear = calendar.component(.year, from: start)
        let endYear = calendar.component(.year, from: end)
        let startMonth = calendar.component(.month, from: start)
        let endMonth = calendar.component(.month, from: end)
        let startDay = calendar.component(.day, from: start)
        let endDay = calendar.component(.day, from: end)

        if calendar.isDate(start, inSameDayAs: end) {
            return format(start, pattern: "MMM d")
        }
        if startYear != endYear {
            return "\(format(start, pattern: "MMM d, yyyy"))-\(format(end, pattern: "MMM d, yyyy"))"
        }
        if startMonth != endMonth {
            return "\(format(start, pattern: "MMM d"))-\(format(end, pattern: "MMM d"))"
        }
        return "\(format(start, pattern: "MMM")) \(startDay)-\(endDay)"
    }

    private static func sourceDateText(_ date: Date?) -> String {
        guard let date else { return "unknown date" }
        return compactDate(date)
    }

    private static func format(_ date: Date, pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/Mexico_City")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

/// Pure, testable grouping of an `AccountSummary` into the four Net Worth
/// breakdown buckets. Order is significant and matches the dashboard's
/// partition invariants: liabilities take priority over everything, then
/// retirement type (so a restricted/locked retirement account lands here, not
/// in Other Assets), then liquidity, then the residual "other" bucket.
/// Returns `nil` for accounts with insufficient balance history — those are
/// excluded from subtotals and shown separately.
enum AccountSummarySection: Int, CaseIterable {
    case liabilities = 0
    case retirement = 1
    case liquidAssets = 2
    case otherAssets = 3

    var title: String {
        switch self {
        case .liabilities: "Liabilities"
        case .retirement: "Retirement Assets"
        case .liquidAssets: "Liquid Assets"
        case .otherAssets: "Other Assets"
        }
    }

    static func bucket(for summary: AccountSummary) -> AccountSummarySection? {
        guard summary.balanceSourceKind != .insufficientHistory else { return nil }
        if summary.isLiability { return .liabilities }
        if summary.type == .retirement { return .retirement }
        if summary.liquidity == .liquid { return .liquidAssets }
        return .otherAssets
    }
}

/// Renders the rows behind an aggregate. The user can see exactly which records
/// produced each headline number.
struct BreakdownSheet: View {
    let request: BreakdownRequest
    var onTransactionTap: ((Transaction) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var selectedCategory: BreakdownRequest?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(request.title)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .sheet(item: $selectedCategory) { request in
            BreakdownSheet(request: request)
        }
        .frame(minWidth: 540, idealWidth: 640, minHeight: 420, idealHeight: 540)
    }

    @ViewBuilder
    private var content: some View {
        switch request {
        case .netWorth(let period, let summaries):
            accountsBreakdown(summaries: summaries, period: period)
        case .income(let txs, let total, let allocations, let sources):
            transactionsBreakdown(
                transactions: txs.filter { Self.includesInIncomeBreakdown($0) },
                interestAllocations: Self.incomeAllocations(allocations, sources: sources),
                interestSources: sources,
                total: total,
                signed: false,
                usesIncomeAllocation: true
            )
        case .expenses(let txs, let total):
            transactionsBreakdown(transactions: txs.filter { Self.includesInExpensesBreakdown($0) }, total: total, signed: true)
        case .interest(let total, let allocations, let sources):
            transactionsBreakdown(
                transactions: [], interestAllocations: allocations,
                interestSources: sources, total: total, signed: false
            )
        case .cashFlowPeriod(let start, let bucket, let txs, let allocations, let sources, let matchedIDs, let hasUnmatchedPayment):
            let cashTransactions = txs.filter { tx in
                !Self.isPositiveInterest(tx)
                    && DashboardCashFlowClassifier.movement(for: tx, matchedCardPaymentIDs: matchedIDs) != nil
                    && bucket.start(for: tx.postedAt) == start
            }
            let cashInterest = Self.incomeAllocations(
                allocations.filter { bucket.start(for: $0.day) == start },
                sources: sources
            )
            VStack(alignment: .leading, spacing: 0) {
                if hasUnmatchedPayment {
                    Text("Some card payments have no matching bank withdrawal recorded in this period; cash flow may be incomplete.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .padding()
                }
                transactionsBreakdown(
                    transactions: cashTransactions,
                    interestAllocations: cashInterest,
                    interestSources: sources,
                    total: nil,
                    signed: nil,
                    usesIncomeAllocation: true
                )
            }
        case .categorySpending(let cat, let total, let txs):
            transactionsBreakdown(transactions: txs.filter { Self.includesInCategorySpendingBreakdown($0, category: cat) }, total: total, signed: true)
        case .categoryList(let entries, let currencyCode, let transactions):
            categoryList(entries: entries, currencyCode: currencyCode, transactions: transactions)
        }
    }

    private func categoryList(entries: [CategorySpending], currencyCode: String, transactions: [Transaction]) -> some View {
        let sorted = entries.sorted { $0.amount > $1.amount }
        let total = sorted.reduce(Decimal.zero) { $0 + $1.amount }
        let colors = CategoryChartPalette.colors(for: sorted.map(\.id))
        return List {
            Section {
                HStack {
                    Text("Total spending")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(MoneyFormat.string(code: currencyCode, total))
                        .monospacedDigit()
                }
            }
            Section {
                ForEach(sorted) { entry in
                    CategoryBreakdownRow(
                        entry: entry,
                        total: total,
                        currencyCode: currencyCode,
                        color: colors[entry.id] ?? .secondary,
                        isActive: false,
                        hasActive: false,
                        compact: false
                    ) {
                        selectedCategory = .categorySpending(
                            category: entry.category,
                            amount: entry.amount,
                            transactions: transactions
                        )
                    }
                }
            }
        }
    }

    // MARK: - Variants

    private func accountsBreakdown(summaries: [AccountSummary], period: DashboardPeriodContext) -> some View {
        let hasInsufficientHistory = summaries.contains { $0.balanceSourceKind == .insufficientHistory }
        let knownSummaries = summaries.filter { $0.balanceSourceKind != .insufficientHistory }
        let insufficientSummaries = summaries.filter { $0.balanceSourceKind == .insufficientHistory }
        let bucketed = Dictionary(grouping: knownSummaries) { AccountSummarySection.bucket(for: $0) ?? .otherAssets }
        let total = knownSummaries.reduce(Decimal.zero) { $0 + $1.latestBalance }
        return List {
            Section {
                Text(NetWorthBreakdownCopy.subtitle(for: period))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Retirement assets are included in Total Net Worth but excluded from Liquid Net Worth.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            ForEach(AccountSummarySection.allCases.sorted { $0.rawValue < $1.rawValue }, id: \.self) { section in
                if let rows = bucketed[section], !rows.isEmpty {
                    Section {
                        ForEach(rows) { s in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.displayName)
                                    if let institution = AccountDisplay.institutionLabel(displayName: s.displayName, institution: s.institution) {
                                        Text(institution).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text(NetWorthBreakdownCopy.sourceText(s))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                                Text(MoneyFormat.string(s.latestBalance, code: s.currency))
                                    .font(.body.bold().monospacedDigit())
                                    .foregroundStyle(s.latestBalance >= 0 ? .green : .red)
                            }
                        }
                    } header: {
                        let subtotal = rows.reduce(Decimal.zero) { $0 + $1.latestBalance }
                        HStack {
                            Text(section.title).font(.caption.weight(.semibold))
                            Spacer()
                            Text(MoneyFormat.string(subtotal))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(subtotal >= 0 ? .green : .red)
                        }
                    }
                }
            }
            if hasInsufficientHistory {
                Section {
                    ForEach(insufficientSummaries) { s in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.displayName)
                                if let institution = AccountDisplay.institutionLabel(displayName: s.displayName, institution: s.institution) {
                                    Text(institution).font(.caption).foregroundStyle(.secondary)
                                }
                                Text(NetWorthBreakdownCopy.sourceText(s))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Text("Insufficient history")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Insufficient history").font(.caption.weight(.semibold))
                }
            }
            Section {
                HStack {
                    Text(hasInsufficientHistory ? "Total known balance" : "Total").bold()
                    Spacer()
                    Text(MoneyFormat.string(total))
                        .font(.body.bold().monospacedDigit())
                        .foregroundStyle(total >= 0 ? .green : .red)
                }
                if hasInsufficientHistory {
                    Text("Accounts with insufficient balance history are excluded from this total.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func transactionsBreakdown(
        transactions: [Transaction],
        interestAllocations: [InterestDailyAllocation] = [],
        interestSources: [Transaction] = [],
        total: Decimal?,
        signed: Bool?,
        usesIncomeAllocation: Bool = false
    ) -> some View {
        let sorted = transactions.sorted { $0.postedAt > $1.postedAt }
        let sortedAllocations = interestAllocations.sorted {
            if $0.day != $1.day { return $0.day > $1.day }
            return $0.id < $1.id
        }
        let computedTotal = total ?? (sorted.reduce(Decimal.zero) { $0 + $1.amount }
            + sortedAllocations.reduce(Decimal.zero) { $0 + (usesIncomeAllocation ? $1.incomeAmount : $1.amount) })
        let sourceByID = Dictionary(uniqueKeysWithValues: interestSources.map { ($0.id, $0) })
        return List {
            if sorted.isEmpty && sortedAllocations.isEmpty {
                Text("No matching transactions in the current period.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(sorted) { tx in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tx.descriptionRaw).lineLimit(2)
                            HStack(spacing: 6) {
                                Text(tx.postedAt, format: .dateTime.day().month(.abbreviated).year())
                                    .font(.caption2).foregroundStyle(.secondary)
                                if let cat = tx.category {
                                    Text(cat.localizedName).font(.caption2).foregroundStyle(.tertiary)
                                }
                                if let card = tx.cardLast4 {
                                    Text("••••\(card)").font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                        }
                        Spacer()
                        Text(MoneyFormat.string(tx.amount, code: tx.currency))
                            .font(.body.bold().monospacedDigit())
                            .foregroundStyle(tx.amount >= 0 ? .green : .red)
                    }
                }
                if !sortedAllocations.isEmpty {
                    Section("Interest allocation · estimated where shown") {
                        ForEach(sortedAllocations) { allocation in
                            let allocatedAmount = usesIncomeAllocation ? allocation.incomeAmount : allocation.amount
                            let originalAmount = usesIncomeAllocation ? allocation.originalIncomeAmount : allocation.originalAmount
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(allocation.day, format: .dateTime.day().month(.abbreviated).year())
                                        .font(.callout.weight(.semibold))
                                    Spacer()
                                    Text(MoneyFormat.string(allocatedAmount, code: allocation.currency))
                                        .font(.body.bold().monospacedDigit())
                                        .foregroundStyle(.green)
                                }
                                switch allocation.kind {
                                case .estimated:
                                    Text("Estimated evenly from \(allocation.intervalStart.formatted(date: .abbreviated, time: .omitted)) through \(allocation.intervalEnd.formatted(date: .abbreviated, time: .omitted)). Captured \(allocation.sourceDate.formatted(date: .abbreviated, time: .omitted)); original total \(MoneyFormat.string(originalAmount, code: allocation.currency)).")
                                        .font(.caption2).foregroundStyle(.secondary)
                                case .actual:
                                    Text("Imported interest, shown on its recorded date. \(MoneyFormat.string(originalAmount, code: allocation.currency))")
                                        .font(.caption2).foregroundStyle(.secondary)
                                case .undistributed:
                                    Text("Could not distribute because the account opening date is later than this capture. Original total \(MoneyFormat.string(originalAmount, code: allocation.currency)).")
                                        .font(.caption2).foregroundStyle(.orange)
                                }
                                ForEach(allocation.sourceTransactionIDs, id: \.self) { sourceID in
                                    if let source = sourceByID[sourceID] {
                                        Button {
                                            onTransactionTap?(source)
                                            dismiss()
                                        } label: {
                                            Label("Open source · \(source.descriptionRaw)", systemImage: "arrow.up.right.square")
                                                .font(.caption)
                                                .lineLimit(2)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
            }
            Section {
                HStack {
                    Text("Total").bold()
                    Spacer()
                    let display: Decimal = (signed == true) ? abs(computedTotal) : computedTotal
                    Text(MoneyFormat.string(display))
                        .font(.body.bold().monospacedDigit())
                        .foregroundStyle(computedTotal >= 0 ? .green : .red)
                }
            }
        }
    }
}

extension BreakdownSheet {
    /// Drill-down predicates. These mirror the `TransactionClassifier` gates the
    /// headline totals use (DashboardViewModel), so the rows behind a number
    /// always match the number — even when a treatment changes what counts.
    /// Exposed as static functions and covered by direct unit tests on both the
    /// include and exclude paths. The tests exercise predicate behavior, not
    /// the rendered SwiftUI sheet or its call-site wiring.
    private static let classifier = TransactionClassifier()

    static func includesInIncomeBreakdown(_ tx: Transaction) -> Bool {
        classifier.classify(transaction: tx).countsAsRegularIncome && !isPositiveInterest(tx)
    }

    static func includesInExpensesBreakdown(_ tx: Transaction) -> Bool {
        classifier.classify(transaction: tx).countsAsRegularExpense
    }

    static func includesInInterestBreakdown(_ tx: Transaction) -> Bool {
        !tx.isDuplicate
            && !classifier.classify(transaction: tx).countsAsInvestmentReturn
            && CategorySemanticIdentity.matches(tx.category, name: "Interest")
            && tx.amount > 0
    }

    static func includesInCashFlowPeriodBreakdown(_ tx: Transaction, bucket: DashboardBucket, start: Date) -> Bool {
        !isPositiveInterest(tx)
            && bucket.start(for: tx.postedAt) == start
            && DashboardCashFlowClassifier.movement(for: tx) != nil
    }

    private static func incomeAllocations(_ allocations: [InterestDailyAllocation], sources: [Transaction]) -> [InterestDailyAllocation] {
        let sourceByID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        return allocations.filter { allocation in
            allocation.incomeAmount != 0
                && allocation.sourceTransactionIDs.contains { sourceByID[$0] != nil }
        }
    }

    private static func isPositiveInterest(_ tx: Transaction) -> Bool {
        tx.amount > 0 && CategorySemanticIdentity.matches(tx.category, name: "Interest")
    }

    static func includesInCategorySpendingBreakdown(_ tx: Transaction, category: Category) -> Bool {
        let matchesCategory: Bool
        if category.name == CategoryPalette.uncategorizedName, category.deletedAt == nil {
            // The dashboard's uncategorized sentinel: its UUID is fresh, so match
            // the rows the donut actually bucketed into it (nil or soft-deleted).
            matchesCategory = tx.category == nil || tx.category?.deletedAt != nil
        } else {
            matchesCategory = tx.category?.id == category.id
        }
        return matchesCategory
            && classifier.classify(transaction: tx).countsAsRegularExpense
    }
}
