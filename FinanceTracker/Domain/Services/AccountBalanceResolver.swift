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

struct AccountBalanceResolution {
    enum SourceKind: String, Hashable {
        case exactBalanceSnapshot
        case latestPriorBalanceSnapshot
        case reconstructedBalance
        case insufficientHistory
    }

    let asOf: Date
    let amount: Decimal
    let sourceKind: SourceKind
    let sourceDate: Date?
    let sourceSnapshotID: UUID?
    let sourceSnapshotKind: AccountBalanceSnapshotKind?
    let sourceSnapshotNote: String?

    init(
        asOf: Date,
        amount: Decimal,
        sourceKind: SourceKind,
        sourceDate: Date?,
        sourceSnapshotID: UUID? = nil,
        sourceSnapshotKind: AccountBalanceSnapshotKind? = nil,
        sourceSnapshotNote: String? = nil
    ) {
        self.asOf = asOf
        self.amount = amount
        self.sourceKind = sourceKind
        self.sourceDate = sourceDate
        self.sourceSnapshotID = sourceSnapshotID
        self.sourceSnapshotKind = sourceSnapshotKind
        self.sourceSnapshotNote = sourceSnapshotNote
    }
}

@MainActor
enum AccountBalanceResolver {
    static func currentBalance(account: Account, context: ModelContext) -> Decimal {
        balance(account: account, asOf: .now, context: context) ?? 0
    }

    static func balance(account: Account, asOf date: Date, context: ModelContext) -> Decimal? {
        let resolution = resolution(account: account, asOf: date, context: context)
        guard resolution.sourceKind != .insufficientHistory else { return nil }
        return resolution.amount
    }

    static func resolution(account: Account, asOf date: Date, context: ModelContext) -> AccountBalanceResolution {
        let accountId = account.id
        let anchors = allAnchors(accountId: accountId, context: context)
        let anchorsThroughDate = anchors.filter { $0.date <= date }
        let anchor = anchorsThroughDate.max { $0.date < $1.date }
        let calendar = Calendar(identifier: .gregorian)

        if let anchor,
           case .manualSnapshot(let snap) = anchor.source,
           snap.kind == .portfolioValuation {
            return AccountBalanceResolution(
                asOf: date,
                amount: anchor.amount,
                sourceKind: .exactBalanceSnapshot,
                sourceDate: anchor.date,
                sourceSnapshotID: snap.id,
                sourceSnapshotKind: snap.kind,
                sourceSnapshotNote: snap.note
            )
        }

        let hasStatementAnchors = anchors.contains {
            if case .statement = $0.source { return true }
            return false
        }

        if !hasStatementAnchors,
           let firstAnchor = anchorsThroughDate.sorted(by: { $0.date < $1.date }).first,
           case .manualSnapshot(let snap) = firstAnchor.source,
           snap.kind == .manualOpening {
            if let anchor, anchor.date > firstAnchor.date {
                let base = anchor.amount
                let deltas = transactionsAfter(anchor.date, through: date, accountId: accountId, context: context)
                    .reduce(Decimal(0)) { $0 + $1.amount }
                let (sourceSnapshotID, sourceSnapshotKind, sourceSnapshotNote) = provenance(for: anchor)
                return AccountBalanceResolution(
                    asOf: date,
                    amount: base + deltas,
                    sourceKind: deltas == 0 ? balanceSourceKind(for: anchor.date, asOf: date, calendar: calendar) : .reconstructedBalance,
                    sourceDate: anchor.date,
                    sourceSnapshotID: sourceSnapshotID,
                    sourceSnapshotKind: sourceSnapshotKind,
                    sourceSnapshotNote: sourceSnapshotNote
                )
            }

            let base = anchor?.amount ?? firstAnchor.amount
            let deltas = transactionsFrom(account.openedAt, through: date, accountId: accountId, context: context)
                .reduce(Decimal(0)) { $0 + $1.amount }
            let (sourceSnapshotID, sourceSnapshotKind, sourceSnapshotNote) = provenance(for: firstAnchor)
            return AccountBalanceResolution(
                asOf: date,
                amount: base + deltas,
                sourceKind: deltas == 0 ? balanceSourceKind(for: firstAnchor.date, asOf: date, calendar: calendar) : .reconstructedBalance,
                sourceDate: firstAnchor.date,
                sourceSnapshotID: sourceSnapshotID,
                sourceSnapshotKind: sourceSnapshotKind,
                sourceSnapshotNote: sourceSnapshotNote
            )
        }

        let effectiveTransactions = transactionsThrough(date, accountId: accountId, context: context)
        guard anchor != nil || !effectiveTransactions.isEmpty else {
            return AccountBalanceResolution(
                asOf: date,
                amount: 0,
                sourceKind: .insufficientHistory,
                sourceDate: nil
            )
        }

        let anchorDate = anchor?.date ?? .distantPast
        let base = anchor?.amount ?? 0
        let deltas = effectiveTransactions
            .filter { $0.postedAt > anchorDate }
            .reduce(Decimal(0)) { $0 + $1.amount }
        let sourceKind: AccountBalanceResolution.SourceKind
        if let anchor {
            sourceKind = deltas == 0 ? balanceSourceKind(for: anchor.date, asOf: date, calendar: calendar) : .reconstructedBalance
        } else {
            sourceKind = .reconstructedBalance
        }
        let (sourceSnapshotID, sourceSnapshotKind, sourceSnapshotNote) = provenance(for: anchor)
        return AccountBalanceResolution(
            asOf: date,
            amount: base + deltas,
            sourceKind: sourceKind,
            sourceDate: anchor?.date,
            sourceSnapshotID: sourceSnapshotID,
            sourceSnapshotKind: sourceSnapshotKind,
            sourceSnapshotNote: sourceSnapshotNote
        )
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

    private static func transactionsAfter(_ date: Date, through end: Date, accountId: UUID, context: ModelContext) -> [Transaction] {
        allTransactions(accountId: accountId, context: context)
            .filter { $0.postedAt > date && $0.postedAt <= end && $0.deletedAt == nil && !$0.isDuplicate }
    }

    private static func transactionsFrom(_ date: Date, accountId: UUID, context: ModelContext) -> [Transaction] {
        allTransactions(accountId: accountId, context: context)
            .filter { $0.postedAt >= date && $0.deletedAt == nil && !$0.isDuplicate }
    }

    private static func transactionsFrom(_ date: Date, through end: Date, accountId: UUID, context: ModelContext) -> [Transaction] {
        allTransactions(accountId: accountId, context: context)
            .filter { $0.postedAt >= date && $0.postedAt <= end && $0.deletedAt == nil && !$0.isDuplicate }
    }

    private static func transactionsThrough(_ date: Date, accountId: UUID, context: ModelContext) -> [Transaction] {
        allTransactions(accountId: accountId, context: context)
            .filter { $0.postedAt <= date && $0.deletedAt == nil && !$0.isDuplicate }
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

    private static func balanceSourceKind(for sourceDate: Date, asOf date: Date, calendar: Calendar) -> AccountBalanceResolution.SourceKind {
        calendar.isDate(sourceDate, inSameDayAs: date) ? .exactBalanceSnapshot : .latestPriorBalanceSnapshot
    }

    private static func provenance(for anchor: AccountBalanceAnchor?) -> (UUID?, AccountBalanceSnapshotKind?, String?) {
        guard let anchor, case .manualSnapshot(let snap) = anchor.source else { return (nil, nil, nil) }
        return (snap.id, snap.kind, snap.note)
    }
}
