import SwiftUI
import SwiftData

/// Drill-down requests from the dashboard. Every case carries the source
/// material needed to render its breakdown sheet — no extra fetches required.
enum BreakdownRequest: Identifiable {
    case netWorth([AccountSummary])
    case netWorthMonth(month: Date, accounts: [AccountSummary])
    case income(transactions: [Transaction], total: Decimal)
    case expenses(transactions: [Transaction], total: Decimal)
    case interest(transactions: [Transaction], total: Decimal)
    case cashFlowMonth(month: Date, transactions: [Transaction])
    case categorySpending(category: Category, amount: Decimal, transactions: [Transaction])

    var id: String {
        switch self {
        case .netWorth: return "net-worth"
        case .netWorthMonth(let month, _): return "net-worth-\(month)"
        case .income: return "income"
        case .expenses: return "expenses"
        case .interest: return "interest"
        case .cashFlowMonth(let month, _): return "cash-flow-\(month)"
        case .categorySpending(let cat, _, _): return "category-\(cat.id)"
        }
    }

    var title: String {
        switch self {
        case .netWorth: return "Net Worth"
        case .netWorthMonth(let month, _):
            return "Net Worth — \(month.formatted(.dateTime.month(.wide).year()))"
        case .income: return "Income"
        case .expenses: return "Expenses"
        case .interest: return "Interest Earned"
        case .cashFlowMonth(let month, _):
            return month.formatted(.dateTime.month(.wide).year())
        case .categorySpending(let cat, _, _): return cat.name
        }
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
        case .netWorth(let summaries):
            accountsBreakdown(summaries: summaries, asOf: nil)
        case .netWorthMonth(let month, let summaries):
            accountsBreakdown(summaries: summaries, asOf: month)
        case .income(let txs, let total):
            transactionsBreakdown(transactions: txs.filter { $0.amount > 0 && $0.category?.kind != .transfer && $0.category?.kind != .creditCardPayment }, total: total, signed: false)
        case .expenses(let txs, let total):
            transactionsBreakdown(transactions: txs.filter { $0.amount < 0 && $0.category?.kind != .transfer && $0.category?.kind != .creditCardPayment }, total: total, signed: true)
        case .interest(let txs, let total):
            transactionsBreakdown(transactions: txs.filter { $0.category?.name == "Interest" && $0.amount > 0 }, total: total, signed: false)
        case .cashFlowMonth(let month, let txs):
            transactionsBreakdown(
                transactions: txs.filter {
                    Calendar.current.isDate($0.postedAt, equalTo: month, toGranularity: .month)
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

    private func accountsBreakdown(summaries: [AccountSummary], asOf: Date?) -> some View {
        let total = summaries.reduce(Decimal.zero) { $0 + $1.latestBalance }
        return List {
            ForEach(summaries) { s in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.nickname)
                        Text(s.institution).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(MoneyFormat.string(s.latestBalance))
                        .font(.body.bold().monospacedDigit())
                        .foregroundStyle(s.latestBalance >= 0 ? .green : .red)
                }
            }
            Section {
                HStack {
                    Text("Total").bold()
                    Spacer()
                    Text(MoneyFormat.string(total))
                        .font(.body.bold().monospacedDigit())
                        .foregroundStyle(total >= 0 ? .green : .red)
                }
            }
            if asOf != nil {
                Section {
                    Text("Balances shown reflect the latest statement on each account; older snapshots aren't yet preserved.")
                        .font(.footnote).foregroundStyle(.secondary)
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
                                if let nick = tx.account?.nickname {
                                    Text(nick).font(.caption2).foregroundStyle(.tertiary)
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
