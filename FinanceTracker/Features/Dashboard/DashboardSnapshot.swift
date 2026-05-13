import Foundation

/// Discriminated snapshot of the dashboard's view data. Computed by
/// `DashboardViewModel` from the current scope; the view dispatches on this enum
/// to render consolidated/asset/liability presentations without forcing one
/// shape on all of them.
enum DashboardSnapshot {
    case consolidated(ConsolidatedSnapshot)
    case asset(AssetAccountSnapshot)
    case liability(LiabilityAccountSnapshot)
    case empty(EmptySnapshot)
}

struct EmptySnapshot {
    let reason: String
}

// MARK: - Consolidated

 struct AccountSummary: Identifiable, Hashable {
     let id: UUID
     let displayName: String
     let institution: String
    let type: AccountType
    let currency: String
    /// Signed: positive = asset balance, negative = liability balance.
    let latestBalance: Decimal
    /// Only populated for credit-card accounts.
    let creditLimit: Decimal?
    /// `abs(latestBalance) / creditLimit` if available; `nil` otherwise.
    let utilizationPercent: Double?
}

struct ConsolidatedSnapshot {
    let netWorth: Decimal
    let netWorthOverTime: [NetWorthPoint]
    let monthlyCashFlow: [MonthlyCashFlow]
    let spendingByCategory: [CategorySpending]
    let totalIncome: Decimal
    let totalExpenses: Decimal
    let totalInterestEarned: Decimal
    let totalInterestCharged: Decimal
    let recentTransactions: [Transaction]
    let accountSummaries: [AccountSummary]
    let totalTransactions: Int

    /// Most common currency across the user's accounts; used for the consolidated
    /// summary cards. Falls back to "MXN" when no accounts exist yet.
    var currencyCode: String {
        let codes = accountSummaries.map(\.currency)
        guard !codes.isEmpty else { return "MXN" }
        let counts = Dictionary(grouping: codes, by: { $0 }).mapValues(\.count)
        return counts.max(by: { $0.value < $1.value })?.key ?? "MXN"
    }
}

// MARK: - Asset (checking, savings, etc.)

struct AssetAccountSnapshot {
    let account: Account
    let currentBalance: Decimal
    let balanceOverTime: [NetWorthPoint]
    let monthlyCashFlow: [MonthlyCashFlow]
    let spendingByCategory: [CategorySpending]
    let totalIncome: Decimal
    let totalExpenses: Decimal
    let totalInterestEarned: Decimal
    let recentTransactions: [Transaction]
    let totalTransactions: Int

    var currencyCode: String { account.currency }
}

// MARK: - Liability (credit cards)

struct LiabilityAccountSnapshot {
    let account: Account
    /// Stored signed-negative for liabilities (AD-C2). Convenience accessors below
    /// expose the absolute owed amount.
    let currentBalance: Decimal
    let creditLimit: Decimal?
    let utilizationPercent: Double?
    let latestStatement: Statement?
    let chargesVsPayments: [MonthlyChargesPayments]
    let spendingByCategory: [CategorySpending]
    let totalCharges: Decimal
    let totalPayments: Decimal
    let interestCharged: Decimal
    let feesCharged: Decimal
    let activeInstallmentPlans: [InstallmentPlan]
    let recentTransactions: [Transaction]
    let totalTransactions: Int

    var amountOwed: Decimal { abs(currentBalance) }
    /// Days from `Date.now` to `paymentDueDate`. Negative if overdue. nil if no due date.
    var daysUntilDue: Int? {
        guard let due = latestStatement?.paymentDueDate else { return nil }
        return Calendar(identifier: .gregorian).dateComponents([.day], from: .now, to: due).day
    }

    var currencyCode: String { account.currency }
}

struct MonthlyChargesPayments: Identifiable {
    let month: Date
    let charges: Decimal       // positive magnitude
    let payments: Decimal      // positive magnitude
    var id: Date { month }
}
