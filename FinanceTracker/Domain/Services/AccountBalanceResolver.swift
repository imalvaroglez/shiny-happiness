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

struct AccountBalanceHistory {
    let anchors: [AccountBalanceAnchor]
    let transactions: [Transaction]

    var hasStatementAnchors: Bool {
        anchors.contains {
            if case .statement = $0.source { return true }
            return false
        }
    }
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

    static func balance(account: Account, asOf date: Date, history: AccountBalanceHistory) -> Decimal? {
        let resolution = resolution(account: account, asOf: date, history: history)
        guard resolution.sourceKind != .insufficientHistory else { return nil }
        return resolution.amount
    }

    static func resolution(account: Account, asOf date: Date, context: ModelContext) -> AccountBalanceResolution {
        let accountId = account.id
        let anchors = allAnchors(accountId: accountId, context: context)
        return resolution(account: account, asOf: date, history: history(account: account, anchors: anchors, context: context))
    }

    static func resolution(account: Account, asOf date: Date, history: AccountBalanceHistory) -> AccountBalanceResolution {
        let anchors = history.anchors
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

        if !history.hasStatementAnchors,
           let firstAnchor = anchorsThroughDate.sorted(by: { $0.date < $1.date }).first,
           case .manualSnapshot(let snap) = firstAnchor.source,
           snap.kind == .manualOpening {
            if let anchor, anchor.date > firstAnchor.date {
                let base = anchor.amount
                var deltas: Decimal = 0
                for transaction in history.transactions {
                    if transaction.postedAt > date { break }
                    if transaction.postedAt > anchor.date {
                        deltas += transaction.amount
                    }
                }
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
            var deltas: Decimal = 0
            for transaction in history.transactions {
                if transaction.postedAt > date { break }
                if transaction.postedAt >= account.openedAt {
                    deltas += transaction.amount
                }
            }
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

        let anchorDate = anchor?.date ?? .distantPast
        var hasEffectiveTransactions = false
        var deltas: Decimal = 0
        for transaction in history.transactions {
            if transaction.postedAt > date { break }
            hasEffectiveTransactions = true
            if transaction.postedAt > anchorDate {
                deltas += transaction.amount
            }
        }
        guard anchor != nil || hasEffectiveTransactions else {
            return AccountBalanceResolution(
                asOf: date,
                amount: 0,
                sourceKind: .insufficientHistory,
                sourceDate: nil
            )
        }

        let base = anchor?.amount ?? 0
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
        var descriptor = FetchDescriptor<Statement>(
            predicate: #Predicate<Statement> { $0.account?.id == accountId && $0.closingBalance != nil },
            sortBy: [SortDescriptor(\.periodEnd, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    static func latestPaymentStatement(accountId: UUID, context: ModelContext) -> Statement? {
        var descriptor = FetchDescriptor<Statement>(
            predicate: #Predicate<Statement> {
                $0.account?.id == accountId
                    && ($0.paymentDueDate != nil || $0.paymentForNoInterest != nil || $0.minimumPayment != nil)
            },
            sortBy: [SortDescriptor(\.periodEnd, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    static func balanceSeries(account: Account, context: ModelContext) -> [NetWorthPoint] {
        balanceSeries(account: account, history: history(account: account, context: context))
    }

    static func balanceSeries(account: Account, history: AccountBalanceHistory) -> [NetWorthPoint] {
        let anchors = history.anchors.sorted { $0.date < $1.date }

        let effectiveTransactions: [Transaction]
        if !history.hasStatementAnchors,
           let firstAnchor = anchors.first,
           case .manualSnapshot(let snap) = firstAnchor.source,
           snap.kind == .manualOpening {
            effectiveTransactions = history.transactions.filter { $0.postedAt >= account.openedAt }
        } else {
            effectiveTransactions = history.transactions
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

        var balance: Decimal = 0
        var series: [NetWorthPoint] = []
        for event in events {
            switch event {
            case .anchor(let anchor):
                balance = anchor.amount
                appendPoint(date: anchor.date, balance: balance, to: &series)
            case .transaction(let transaction):
                balance += transaction.amount
                appendPoint(date: transaction.postedAt, balance: balance, to: &series)
            }
        }

        return series
    }

    private static func appendPoint(date: Date, balance: Decimal, to series: inout [NetWorthPoint]) {
        if series.last?.month == date {
            series[series.count - 1] = NetWorthPoint(month: date, balance: balance)
        } else {
            series.append(NetWorthPoint(month: date, balance: balance))
        }
    }

    static func history(account: Account, context: ModelContext) -> AccountBalanceHistory {
        let anchors = allAnchors(accountId: account.id, context: context)
        return history(account: account, anchors: anchors, context: context)
    }

    static func histories(
        accounts: [Account],
        context: ModelContext,
        preloadedHistoryTransactions: [Transaction]? = nil
    ) -> [UUID: AccountBalanceHistory] {
        let accountIDs = Set(accounts.map(\.id))
        guard !accountIDs.isEmpty else { return [:] }

        let statements = (try? context.fetch(FetchDescriptor<Statement>(
            predicate: #Predicate<Statement> { $0.account != nil }
        ))) ?? []
        let snapshots = (try? context.fetch(FetchDescriptor<AccountBalanceSnapshot>(
            predicate: #Predicate<AccountBalanceSnapshot> { $0.account != nil }
        ))) ?? []
        let deletedMirrorTransactions: [Transaction]
        let transactions: [Transaction]
        if let preloadedHistoryTransactions {
            deletedMirrorTransactions = fetchDeletedMirrorTransactions(context: context)
            transactions = statements.isEmpty
                ? preloadedHistoryTransactions.filter { !$0.isDuplicate }
                : preloadedHistoryTransactions.filter { $0.statement == nil && !$0.isDuplicate }
        } else {
            let transactionPredicate = #Predicate<Transaction> { tx in
                tx.account != nil && tx.statement == nil
            }
            let transactionDescriptor = FetchDescriptor<Transaction>(
                predicate: transactionPredicate,
                sortBy: [SortDescriptor(\.postedAt)]
            )
            let allTransactions = (try? context.fetch(transactionDescriptor)) ?? []
            deletedMirrorTransactions = allTransactions.filter { $0.deletedAt != nil }
            transactions = allTransactions.filter { $0.deletedAt == nil && !$0.isDuplicate }
        }

        var statementAnchorsByAccount: [UUID: [AccountBalanceAnchor]] = [:]
        for statement in statements {
            guard let accountID = statement.account?.id,
                  accountIDs.contains(accountID),
                  let balance = statement.closingBalance else { continue }
            statementAnchorsByAccount[accountID, default: []].append(
                AccountBalanceAnchor(date: statement.periodEnd, amount: balance, source: .statement(statement))
            )
        }

        var deletedMirrorIDsByAccount: [UUID: Set<UUID>] = [:]
        for transaction in deletedMirrorTransactions {
            guard let accountID = transaction.account?.id, accountIDs.contains(accountID) else { continue }
            deletedMirrorIDsByAccount[accountID, default: []].insert(transaction.id)
        }

        var snapshotAnchorsByAccount: [UUID: [AccountBalanceAnchor]] = [:]
        for snapshot in snapshots {
            guard let accountID = snapshot.account?.id, accountIDs.contains(accountID) else { continue }
            if deletedMirrorIDsByAccount[accountID, default: []].contains(snapshot.id) { continue }
            snapshotAnchorsByAccount[accountID, default: []].append(
                AccountBalanceAnchor(date: snapshot.date, amount: snapshot.amount, source: .manualSnapshot(snapshot))
            )
        }

        var transactionsByAccount: [UUID: [Transaction]] = [:]
        for transaction in transactions {
            guard let accountID = transaction.account?.id, accountIDs.contains(accountID) else { continue }
            transactionsByAccount[accountID, default: []].append(transaction)
        }

        return Dictionary(uniqueKeysWithValues: accounts.map { account in
            let anchors = (statementAnchorsByAccount[account.id] ?? []) + (snapshotAnchorsByAccount[account.id] ?? [])
            return (account.id, AccountBalanceHistory(anchors: anchors, transactions: transactionsByAccount[account.id] ?? []))
        })
    }

    static func history(account: Account, anchors: [AccountBalanceAnchor], context: ModelContext) -> AccountBalanceHistory {
        let transactions = allTransactions(accountId: account.id, context: context)
            .filter { !$0.isDuplicate && $0.deletedAt == nil }
            .sorted { $0.postedAt < $1.postedAt }
        return AccountBalanceHistory(anchors: anchors, transactions: transactions)
    }

    static func allAnchors(accountId: UUID, context: ModelContext) -> [AccountBalanceAnchor] {
        let statements = fetchStatements(accountId: accountId, context: context)
        let snapshots = fetchSnapshots(accountId: accountId, context: context)
        let deletedMirrorIDs = deletedMirrorTransactionIDs(accountId: accountId, context: context)

        let statementAnchors = statements.compactMap { statement -> AccountBalanceAnchor? in
            guard let balance = statement.closingBalance else { return nil }
            return AccountBalanceAnchor(date: statement.periodEnd, amount: balance, source: .statement(statement))
        }
        let manualAnchors = snapshots.filter { !deletedMirrorIDs.contains($0.id) }.map {
            AccountBalanceAnchor(date: $0.date, amount: $0.amount, source: .manualSnapshot($0))
        }
        return statementAnchors + manualAnchors
    }

    private static func allTransactions(accountId: UUID, context: ModelContext) -> [Transaction] {
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate<Transaction> { tx in
                tx.account?.id == accountId && tx.statement == nil
            }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private static func deletedMirrorTransactionIDs(accountId: UUID, context: ModelContext) -> Set<UUID> {
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate<Transaction> { tx in
                tx.account?.id == accountId && tx.statement == nil && tx.deletedAt != nil
            }
        )
        return Set(((try? context.fetch(descriptor)) ?? []).map(\.id))
    }

    private static func fetchDeletedMirrorTransactions(context: ModelContext) -> [Transaction] {
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate<Transaction> { tx in
                tx.account != nil && tx.statement == nil && tx.deletedAt != nil
            }
        )
        return (try? context.fetch(descriptor)) ?? []
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
