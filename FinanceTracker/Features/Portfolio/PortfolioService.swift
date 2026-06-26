import Foundation
import SwiftData

@MainActor
enum PortfolioService {
    enum ValidationError: Error, LocalizedError {
        case duplicateTicker
        case invalidShares
        case invalidCost
        case emptyTicker
        case tooManyPositions

        var errorDescription: String? {
            switch self {
            case .duplicateTicker: "A position for that ticker already exists. Use Buy More."
            case .invalidShares: "Shares must be greater than zero."
            case .invalidCost: "Average cost cannot be negative."
            case .emptyTicker: "Ticker cannot be empty."
            case .tooManyPositions: "An account can hold at most 50 positions."
            }
        }
    }

    private static let maxPositions = 50

    static func allPositions(accountID: UUID, context: ModelContext) -> [StockPosition] {
        let descriptor = FetchDescriptor<StockPosition>(
            predicate: #Predicate<StockPosition> { $0.account?.id == accountID }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    static func activePositions(accountID: UUID, context: ModelContext) -> [StockPosition] {
        allPositions(accountID: accountID, context: context).filter { $0.shares > 0 }
    }

    static func inPortfolioMode(account: Account, context: ModelContext) -> Bool {
        !activePositions(accountID: account.id, context: context).isEmpty
    }

    static func canAddPositions(account: Account, context: ModelContext) -> Bool {
        guard account.type == .investment else { return false }
        if inPortfolioMode(account: account, context: context) { return true }
        let accountID = account.id

        let statementCount = (try? context.fetchCount(FetchDescriptor<Statement>(
            predicate: #Predicate<Statement> { $0.account?.id == accountID }
        ))) ?? 0
        guard statementCount == 0 else { return false }

        let transactionCount = (try? context.fetchCount(FetchDescriptor<Transaction>(
            predicate: #Predicate<Transaction> { $0.account?.id == accountID }
        ))) ?? 0
        guard transactionCount == 0 else { return false }

        let snapshots = (try? context.fetch(FetchDescriptor<AccountBalanceSnapshot>(
            predicate: #Predicate<AccountBalanceSnapshot> { $0.account?.id == accountID }
        ))) ?? []
        return snapshots.allSatisfy { $0.kind == .portfolioValuation }
    }

    @discardableResult
    static func addPosition(
        account: Account,
        emisoraSerie: String,
        name: String?,
        shares: Decimal,
        averageCost: Decimal,
        context: ModelContext
    ) throws -> StockPosition {
        let ticker = normalizeTicker(emisoraSerie)
        guard !ticker.isEmpty else { throw ValidationError.emptyTicker }
        guard shares > 0 else { throw ValidationError.invalidShares }
        guard averageCost >= 0 else { throw ValidationError.invalidCost }

        let existing = allPositions(accountID: account.id, context: context)
        guard !existing.contains(where: { $0.emisoraSerie == ticker }) else { throw ValidationError.duplicateTicker }
        guard existing.filter({ $0.shares > 0 }).count < maxPositions else { throw ValidationError.tooManyPositions }

        let position = StockPosition(
            account: account,
            emisoraSerie: ticker,
            name: name,
            shares: shares,
            averageCost: averageCost
        )
        context.insert(position)
        try context.save()
        return position
    }

    static func buyMore(position: StockPosition, addedShares: Decimal, buyPrice: Decimal, context: ModelContext) throws {
        guard addedShares > 0 else { throw ValidationError.invalidShares }
        guard buyPrice >= 0 else { throw ValidationError.invalidCost }

        let newShares = position.shares + addedShares
        let totalCost = (position.shares * position.averageCost) + (addedShares * buyPrice)
        position.shares = newShares
        position.averageCost = totalCost / newShares
        position.lastModifiedAt = .now
        try context.save()
    }

    static func edit(
        position: StockPosition,
        shares: Decimal?,
        averageCost: Decimal?,
        name: String?,
        context: ModelContext
    ) throws {
        if let shares {
            guard shares >= 0 else { throw ValidationError.invalidShares }
            position.shares = shares
        }
        if let averageCost {
            guard averageCost >= 0 else { throw ValidationError.invalidCost }
            position.averageCost = averageCost
        }
        if let name {
            position.name = name
        }
        position.lastModifiedAt = .now
        try context.save()
    }

    static func delete(position: StockPosition, account: Account, context: ModelContext) throws {
        let wasLastActive = activePositions(accountID: account.id, context: context)
            .filter { $0.id != position.id }
            .isEmpty

        context.delete(position)
        if wasLastActive {
            context.insert(AccountBalanceSnapshot(
                account: account,
                date: Date.now,
                amount: 0,
                kind: .portfolioValuation,
                note: "Portfolio valuation |fp=\(HoldingsFingerprint.of([]))"
            ))
        }
        try context.save()
    }

    private static func normalizeTicker(_ ticker: String) -> String {
        ticker.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}
