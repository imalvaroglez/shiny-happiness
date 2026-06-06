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
        let anchors = allAnchors(accountId: accountId, context: context)
        let anchor = anchors.max { $0.date < $1.date }

        let hasStatementAnchors = anchors.contains {
            if case .statement = $0.source { return true }
            return false
        }

        if !hasStatementAnchors, let anchor = anchor,
           case .manualSnapshot(let snap) = anchor.source,
           snap.kind == .manualOpening {
            let base = anchor.amount
            let deltas = transactionsFrom(account.openedAt, accountId: accountId, context: context)
                .reduce(Decimal(0)) { $0 + $1.amount }
            return base + deltas
        }

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

    static func latestBalanceStatement(accountId: UUID, context: ModelContext) -> Statement? {
        let statements = fetchStatements(accountId: accountId, context: context)
        return statements
            .filter { $0.closingBalance != nil }
            .max { $0.periodEnd < $1.periodEnd }
    }

    static func latestPaymentStatement(accountId: UUID, context: ModelContext) -> Statement? {
        let statements = fetchStatements(accountId: accountId, context: context)
        return statements
            .filter { $0.paymentDueDate != nil || $0.paymentForNoInterest != nil || $0.minimumPayment != nil }
            .max { $0.periodEnd < $1.periodEnd }
    }

    static func balanceSeries(account: Account, context: ModelContext) -> [NetWorthPoint] {
        let accountId = account.id
        let anchors = allAnchors(accountId: accountId, context: context).sorted { $0.date < $1.date }

        let hasStatementAnchors = anchors.contains {
            if case .statement = $0.source { return true }
            return false
        }

        let effectiveTransactions: [Transaction]
        if !hasStatementAnchors,
           let firstAnchor = anchors.first,
           case .manualSnapshot(let snap) = firstAnchor.source,
           snap.kind == .manualOpening {
            effectiveTransactions = allTransactions(accountId: accountId, context: context)
                .filter { $0.postedAt >= account.openedAt && !$0.isDuplicate && $0.deletedAt == nil }
                .sorted { $0.postedAt < $1.postedAt }
        } else {
            effectiveTransactions = allTransactions(accountId: accountId, context: context)
                .filter { !$0.isDuplicate && $0.deletedAt == nil }
                .sorted { $0.postedAt < $1.postedAt }
        }

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

        let events = (anchors.map(Event.anchor) + effectiveTransactions.map(Event.transaction))
            .sorted { lhs, rhs in
                if lhs.date == rhs.date {
                    if case .anchor = lhs, case .transaction = rhs { return true }
                    if case .transaction = lhs, case .anchor = rhs { return false }
                    return false
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

    private static func transactionsAfter(_ date: Date, accountId: UUID, context: ModelContext) -> [Transaction] {
        allTransactions(accountId: accountId, context: context)
            .filter { $0.postedAt > date && $0.deletedAt == nil && !$0.isDuplicate }
    }

    private static func transactionsFrom(_ date: Date, accountId: UUID, context: ModelContext) -> [Transaction] {
        allTransactions(accountId: accountId, context: context)
            .filter { $0.postedAt >= date && $0.deletedAt == nil && !$0.isDuplicate }
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
