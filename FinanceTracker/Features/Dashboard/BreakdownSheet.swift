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
            transactionsBreakdown(transactions: txs.filter { $0.amount > 0 && $0.category?.kind != .transfer && $0.category?.kind != .creditCardPayment }, total: total, signed: false)
        case .expenses(let txs, let total):
            transactionsBreakdown(transactions: txs.filter { $0.amount < 0 && $0.category?.kind != .transfer && $0.category?.kind != .creditCardPayment }, total: total, signed: true)
        case .interest(let txs, let total):
            transactionsBreakdown(transactions: txs.filter { $0.category?.name == "Interest" && $0.amount > 0 }, total: total, signed: false)
        case .cashFlowPeriod(let start, let bucket, let txs):
            transactionsBreakdown(
                transactions: txs.filter {
                    bucket.matches($0.postedAt, start)
                        && $0.category?.kind != .transfer
                        && $0.category?.kind != .creditCardPayment
                },
                total: nil, signed: nil
            )
        case .categorySpending(let cat, let total, let txs):
            transactionsBreakdown(transactions: txs.filter { $0.category?.id == cat.id && $0.amount < 0 }, total: total, signed: true)
        }
    }

    // MARK: - Variants

    private func accountsBreakdown(summaries: [AccountSummary], period: DashboardPeriodContext) -> some View {
        let total = summaries.reduce(Decimal.zero) { partial, summary in
            summary.balanceSourceKind == .insufficientHistory ? partial : partial + summary.latestBalance
        }
        let hasInsufficientHistory = summaries.contains { $0.balanceSourceKind == .insufficientHistory }
        return List {
            Section {
                Text(NetWorthBreakdownCopy.subtitle(for: period))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(summaries) { s in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.displayName)
                        Text(s.institution).font(.caption).foregroundStyle(.secondary)
                        Text(NetWorthBreakdownCopy.sourceText(s))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if s.balanceSourceKind == .insufficientHistory {
                        Text("Insufficient history")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(MoneyFormat.string(s.latestBalance, code: s.currency))
                            .font(.body.bold().monospacedDigit())
                            .foregroundStyle(s.latestBalance >= 0 ? .green : .red)
                    }
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
