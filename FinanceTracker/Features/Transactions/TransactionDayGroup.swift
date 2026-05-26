import Foundation

struct TransactionDayGroup: Identifiable {
    let date: Date
    let transactions: [Transaction]

    var id: Date { date }

    var count: Int { transactions.count }

    var netTotal: Decimal {
        transactions.reduce(Decimal(0)) { $0 + $1.amount }
    }

    static func group(_ transactions: [Transaction]) -> [TransactionDayGroup] {
        let calendar = Calendar(identifier: .gregorian)
        let groups = Dictionary(grouping: transactions) {
            calendar.startOfDay(for: $0.postedAt)
        }
        return groups
            .map { TransactionDayGroup(date: $0.key, transactions: $0.value) }
            .sorted { $0.date > $1.date }
    }
}
