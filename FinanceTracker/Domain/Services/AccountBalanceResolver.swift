import Foundation
import SwiftData

struct AccountBalanceAnchor {
    enum Source {
        case statement(Statement)
        case manualSnapshot(AccountBalanceSnapshot)
    }

    let date: Date
    let amount: Decimal
    let source: Source
}

@MainActor
enum AccountBalanceResolver {
    static func currentBalance(account: Account, context: ModelContext) -> Decimal {
        let accountId = account.id
        let anchor = latestAnchor(accountId: accountId, context: context)
        let anchorDate = anchor?.date ?? .distantPast
        let base = anchor?.amount ?? 0
        let deltas = transactionsAfter(anchorDate, accountId: accountId, context: context)
            .reduce(Decimal(0)) { $0 + $1.amount }
        return base + deltas
    }

    static func latestStatement(accountId: UUID, context: ModelContext) -> Statement? {
        var descriptor = FetchDescriptor<Statement>(
            predicate: #Predicate<Statement> { $0.account?.id == accountId },
            sortBy: [SortDescriptor(\.periodEnd, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    static func balanceSeries(account: Account, context: ModelContext) -> [NetWorthPoint] {
        let accountId = account.id
        let anchors = allAnchors(accountId: accountId, context: context).sorted { $0.date < $1.date }
        let transactions = allTransactions(accountId: accountId, context: context)
            .filter { !$0.isDuplicate && $0.deletedAt == nil }
            .sorted { $0.postedAt < $1.postedAt }

        enum Event {
            case anchor(AccountBalanceAnchor)
            case transaction(Transaction)

            var date: Date {
                switch self {
                case .anchor(let anchor): anchor.date
                case .transaction(let transaction): transaction.postedAt
                }
            }
        }

        let events = (anchors.map(Event.anchor) + transactions.map(Event.transaction))
            .sorted { lhs, rhs in
                if lhs.date == rhs.date {
                    if case .anchor = lhs { return false }
                    return true
                }
                return lhs.date < rhs.date
            }

        var points: [Date: Decimal] = [:]
        var balance: Decimal = 0
        for event in events {
            switch event {
            case .anchor(let anchor):
                balance = anchor.amount
                points[anchor.date] = balance
            case .transaction(let transaction):
                balance += transaction.amount
                points[transaction.postedAt] = balance
            }
        }

        return points.map { NetWorthPoint(month: $0.key, balance: $0.value) }
            .sorted { $0.month < $1.month }
    }

    static func latestAnchor(accountId: UUID, context: ModelContext) -> AccountBalanceAnchor? {
        allAnchors(accountId: accountId, context: context)
            .max { $0.date < $1.date }
    }

    static func allAnchors(accountId: UUID, context: ModelContext) -> [AccountBalanceAnchor] {
        let statements = fetchStatements(accountId: accountId, context: context)
        let snapshots = fetchSnapshots(accountId: accountId, context: context)

        let statementAnchors = statements.compactMap { statement -> AccountBalanceAnchor? in
            guard let balance = statement.closingBalance else { return nil }
            return AccountBalanceAnchor(date: statement.periodEnd, amount: balance, source: .statement(statement))
        }
        let manualAnchors = snapshots.map {
            AccountBalanceAnchor(date: $0.date, amount: $0.amount, source: .manualSnapshot($0))
        }
        return statementAnchors + manualAnchors
    }

    private static func nextAnchor(after date: Date, in anchors: [AccountBalanceAnchor]) -> AccountBalanceAnchor? {
        anchors.first { $0.date > date }
    }

    private static func transactionsAfter(_ date: Date, accountId: UUID, context: ModelContext) -> [Transaction] {
        allTransactions(accountId: accountId, context: context)
            .filter { $0.postedAt > date && $0.deletedAt == nil && !$0.isDuplicate }
    }

    private static func allTransactions(accountId: UUID, context: ModelContext) -> [Transaction] {
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate<Transaction> { $0.account?.id == accountId }
        )
        return ((try? context.fetch(descriptor)) ?? [])
            .filter { $0.statement == nil }
    }

    private static func fetchStatements(accountId: UUID, context: ModelContext) -> [Statement] {
        let descriptor = FetchDescriptor<Statement>(
            predicate: #Predicate<Statement> { $0.account?.id == accountId }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private static func fetchSnapshots(accountId: UUID, context: ModelContext) -> [AccountBalanceSnapshot] {
        let descriptor = FetchDescriptor<AccountBalanceSnapshot>(
            predicate: #Predicate<AccountBalanceSnapshot> { $0.account?.id == accountId }
        )
        return (try? context.fetch(descriptor)) ?? []
    }
}
