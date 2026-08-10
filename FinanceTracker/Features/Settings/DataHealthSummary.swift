import Foundation

/// Value-only inputs used to present the health of the user's data.
/// These projections deliberately do not reference SwiftData models so the
/// summary can be tested without a persistent store or a view context.
struct DataHealthAccountInput: Equatable {
    let closedAt: Date?
    let currency: String
}

struct DataHealthTransactionInput: Equatable {
    let postedAt: Date
    let deletedAt: Date?
    let isDuplicate: Bool
    let currency: String
}

struct DataHealthPendingInput: Equatable {
    let isResolved: Bool
}

struct DataHealthSummary: Equatable {
    let activeAccountCount: Int
    let historyStart: Date?
    let historyEnd: Date?
    let lastActivity: Date?
    let unresolvedPendingCount: Int
    let activeCategoryCount: Int
    let importedStatementCount: Int
    let currenciesInUse: [String]

    init(
        accounts: [DataHealthAccountInput],
        transactions: [DataHealthTransactionInput],
        pendingImports: [DataHealthPendingInput],
        activeCategoryCount: Int,
        importedStatementCount: Int
    ) {
        activeAccountCount = accounts.count(where: { $0.closedAt == nil })

        let activeTransactions = transactions.filter { $0.deletedAt == nil && !$0.isDuplicate }
        historyStart = activeTransactions.map(\.postedAt).min()
        historyEnd = activeTransactions.map(\.postedAt).max()
        lastActivity = historyEnd

        unresolvedPendingCount = pendingImports.count(where: { !$0.isResolved })
        self.activeCategoryCount = max(0, activeCategoryCount)
        self.importedStatementCount = max(0, importedStatementCount)

        let accountCurrencies = accounts.filter { $0.closedAt == nil }.map(\.currency)
        let transactionCurrencies = activeTransactions.map(\.currency)
        currenciesInUse = Set((accountCurrencies + transactionCurrencies).compactMap { currency in
            let normalized = currency.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? nil : normalized.uppercased()
        }).sorted()
    }

    var hasTransactionHistory: Bool {
        historyStart != nil
    }
}
