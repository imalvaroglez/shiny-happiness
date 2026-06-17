import SwiftUI
import SwiftData

/// Drill-down requests from the dashboard. Every case carries the source
/// material needed to render its breakdown sheet — no extra fetches required.
enum BreakdownRequest: Identifiable {
    case netWorth(period: DashboardPeriodContext, accounts: [AccountSummary])
    case income(transactions: [Transaction], total: Decimal)
    case expenses(transactions: [Transaction], total: Decimal)
    case interest(transactions: [Transaction], total: Decimal)
    case cashFlowPeriod(start: Date, bucket: DashboardBucket, transactions: [Transaction])
    case categorySpending(category: Category, amount: Decimal, transactions: [Transaction])

    var id: String {
        switch self {
        case .netWorth(let period, _): return "net-worth-\(period.effectiveNetWorthDate)"
        case .income: return "income"
        case .expenses: return "expenses"
        case .interest: return "interest"
        case .cashFlowPeriod(let start, _, _): return "cash-flow-\(start)"
        case .categorySpending(let cat, _, _): return "category-\(cat.id)"
        }
    }

    var title: String {
        switch self {
        case .netWorth(let period, _):
            return "Net Worth as of \(NetWorthBreakdownCopy.titleDate(period.effectiveNetWorthDate))"
        case .income: return "Income"
        case .expenses: return "Expenses"
        case .interest: return "Interest Earned"
        case .cashFlowPeriod(let start, let bucket, _):
            return dashboardBucketLabel(for: start, bucket: bucket)
        case .categorySpending(let cat, _, _): return cat.name
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
    @Environment(\.dismiss) private var dismiss

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
        .frame(minWidth: 540, idealWidth: 640, minHeight: 420, idealHeight: 540)
    }

    @ViewBuilder
    private var content: some View {
        switch request {
        case .netWorth(let period, let summaries):
            accountsBreakdown(summaries: summaries, period: period)
        case .income(let txs, let total):
            transactionsBreakdown(transactions: txs.filter { Self.includesInIncomeBreakdown($0) }, total: total, signed: false)
        case .expenses(let txs, let total):
            transactionsBreakdown(transactions: txs.filter { Self.includesInExpensesBreakdown($0) }, total: total, signed: true)
        case .interest(let txs, let total):
            transactionsBreakdown(transactions: txs.filter { Self.includesInInterestBreakdown($0) }, total: total, signed: false)
        case .cashFlowPeriod(let start, let bucket, let txs):
            transactionsBreakdown(
                transactions: txs.filter { Self.includesInCashFlowPeriodBreakdown($0, bucket: bucket, start: start) },
                total: nil, signed: nil
            )
        case .categorySpending(let cat, let total, let txs):
            transactionsBreakdown(transactions: txs.filter { Self.includesInCategorySpendingBreakdown($0, category: cat) }, total: total, signed: true)
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
                                    Text(s.institution).font(.caption).foregroundStyle(.secondary)
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
                                Text(s.institution).font(.caption).foregroundStyle(.secondary)
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

    private func transactionsBreakdown(transactions: [Transaction], total: Decimal?, signed: Bool?) -> some View {
        let sorted = transactions.sorted { $0.postedAt > $1.postedAt }
        let computedTotal = total ?? sorted.reduce(Decimal.zero) { $0 + $1.amount }
        return List {
            if sorted.isEmpty {
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
                                    Text(cat.name).font(.caption2).foregroundStyle(.tertiary)
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
        classifier.classify(transaction: tx).countsAsRegularIncome
    }

    static func includesInExpensesBreakdown(_ tx: Transaction) -> Bool {
        classifier.classify(transaction: tx).countsAsRegularExpense
    }

    static func includesInInterestBreakdown(_ tx: Transaction) -> Bool {
        !tx.isDuplicate
            && !classifier.classify(transaction: tx).countsAsInvestmentReturn
            && tx.category?.name == "Interest"
            && tx.amount > 0
    }

    static func includesInCashFlowPeriodBreakdown(_ tx: Transaction, bucket: DashboardBucket, start: Date) -> Bool {
        bucket.matches(tx.postedAt, start)
            && classifier.classify(transaction: tx).countsAsOperatingCashFlow
    }

    static func includesInCategorySpendingBreakdown(_ tx: Transaction, category: Category) -> Bool {
        tx.category?.id == category.id
            && classifier.classify(transaction: tx).countsAsRegularExpense
    }
}
