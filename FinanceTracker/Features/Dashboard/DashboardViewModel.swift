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
    var monthlyCashFlow: [MonthlyCashFlow] = []
    var spendingByCategory: [CategorySpending] = []
    var netWorthOverTime: [NetWorthPoint] = []
    var recentTransactions: [Transaction] = []
    var totalIncome: Decimal = 0
    var totalExpenses: Decimal = 0
    var totalTransactions: Int = 0

    var dateRange: DateRange = .year(.now)

    private var context: ModelContext?

    func configure(context: ModelContext) {
        self.context = context
        refresh()
    }

    func refresh() {
        guard let context else { return }

        let descriptor = FetchDescriptor<Transaction>(
            predicate: buildPredicate(),
            sortBy: [SortDescriptor(\.postedAt, order: .reverse)]
        )

        guard let transactions = try? context.fetch(descriptor) else { return }
        totalTransactions = transactions.count

        computeMonthlyCashFlow(transactions)
        computeSpendingByCategory(transactions)
        computeNetWorth(transactions)
        computeTotals(transactions)

        var recentDescriptor = FetchDescriptor<Transaction>(
            predicate: buildPredicate(),
            sortBy: [SortDescriptor(\.postedAt, order: .reverse)]
        )
        recentDescriptor.fetchLimit = 20
        recentTransactions = (try? context.fetch(recentDescriptor)) ?? []
    }

    private func buildPredicate() -> Predicate<Transaction> {
        let start = dateRange.start
        let end = dateRange.end
        return #Predicate<Transaction> { tx in
            tx.postedAt >= start && tx.postedAt <= end
        }
    }

    private func computeMonthlyCashFlow(_ transactions: [Transaction]) {
        let calendar = Calendar(identifier: .gregorian)
        var grouped: [Date: (income: Decimal, expenses: Decimal)] = [:]

        for tx in transactions {
            guard !tx.isDuplicate else { continue }
            let kind = tx.category?.kind
            if kind == .transfer { continue }

            let month = calendar.date(from: calendar.dateComponents([.year, .month], from: tx.postedAt))!
            let existing = grouped[month] ?? (0, 0)

            if kind == .income || (kind == nil && tx.amount > 0) {
                grouped[month] = (existing.income + tx.amount, existing.expenses)
            } else if kind == .expense || kind == .investment || (kind == nil && tx.amount < 0) {
                grouped[month] = (existing.income, existing.expenses + tx.amount)
            }
        }

        monthlyCashFlow = grouped.map { month, values in
            MonthlyCashFlow(month: month, income: values.income, expenses: values.expenses)
        }.sorted { $0.month < $1.month }
    }

    private func computeSpendingByCategory(_ transactions: [Transaction]) {
        var spending: [ObjectIdentifier: Decimal] = [:]
        var categoryMap: [ObjectIdentifier: Category] = [:]

        for tx in transactions {
            guard !tx.isDuplicate else { continue }
            if tx.category?.kind == .transfer { continue }
            guard tx.amount < 0 else { continue }
            let key: ObjectIdentifier
            if let cat = tx.category {
                key = ObjectIdentifier(cat)
                categoryMap[key] = cat
            } else {
                let uncategorized = Category(name: "Uncategorized", kind: .expense)
                key = ObjectIdentifier(uncategorized)
                categoryMap[key] = uncategorized
            }
            spending[key, default: 0] += abs(tx.amount)
        }

        spendingByCategory = spending.map { key, amount in
            CategorySpending(category: categoryMap[key]!, amount: amount)
        }.sorted { $0.amount > $1.amount }
    }

    private func computeNetWorth(_ transactions: [Transaction]) {
        let calendar = Calendar(identifier: .gregorian)
        var cumulative: Decimal = 0
        var monthBalances: [Date: Decimal] = [:]

        let sorted = transactions.filter { !$0.isDuplicate }.sorted { $0.postedAt < $1.postedAt }

        for tx in sorted {
            cumulative += tx.amount
            let month = calendar.date(from: calendar.dateComponents([.year, .month], from: tx.postedAt))!
            monthBalances[month] = cumulative
        }

        netWorthOverTime = monthBalances.map { month, balance in
            NetWorthPoint(month: month, balance: balance)
        }.sorted { $0.month < $1.month }
    }

    private func computeTotals(_ transactions: [Transaction]) {
        totalIncome = 0
        totalExpenses = 0
        for tx in transactions {
            guard !tx.isDuplicate else { continue }
            let kind = tx.category?.kind
            if kind == .transfer { continue }
            if kind == .income || (kind == nil && tx.amount > 0) {
                totalIncome += tx.amount
            } else if kind == .expense || kind == .investment || (kind == nil && tx.amount < 0) {
                totalExpenses += tx.amount
            }
        }
    }
}
