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

struct DashboardAccountIdentity: Identifiable, Hashable {
    let id: UUID
    let displayName: String
    let institution: String
    let type: AccountType
    let currency: String
    let tintHex: String?
    let creditLimit: Decimal?
}

extension DashboardAccountIdentity {
    init(_ account: Account) {
        self.id = account.id
        self.displayName = account.displayName
        self.institution = account.institution
        self.type = account.type
        self.currency = account.currency
        self.tintHex = account.tintHex
        self.creditLimit = account.creditLimit
    }
}

struct AccountSummary: Identifiable, Hashable {
    let id: UUID
    let displayName: String
    let institution: String
    let type: AccountType
    let currency: String
    /// Signed: positive = asset balance, negative = liability balance.
    let latestBalance: Decimal
    let balanceAsOf: Date
    let balanceSourceKind: AccountBalanceResolution.SourceKind
    let balanceSourceDate: Date?
    /// Only populated for credit-card accounts.
    let creditLimit: Decimal?
    /// `abs(latestBalance) / creditLimit` if available; `nil` otherwise.
    let utilizationPercent: Double?
    /// Liquidity classification at snapshot time. Defaults to `.liquid` so the
    /// synthesized memberwise initializer stays compatible with the existing
    /// 11-argument call sites (DashboardView preview, DashboardViewModel, tests).
    var liquidity: AccountLiquidity = .liquid
    /// Retirement subtype, if the account is a retirement account; nil otherwise.
    var retirementKind: RetirementKind? = nil
    /// True when the account's type is an inherent liability (credit card / loan).
    var isLiability: Bool { type.isLiability }
}

struct ConsolidatedSnapshot {
    let period: DashboardPeriodContext
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
    /// Σ latestBalance over retirement-type accounts (gross; no liability offset).
    let retirementAssets: Decimal
    /// Σ of liquid non-retirement asset balances + liability balances (already negative).
    let liquidNetWorth: Decimal

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
    let period: DashboardPeriodContext
    let account: DashboardAccountIdentity
    let currentBalance: Decimal
    let balanceOverTime: [NetWorthPoint]
    let monthlyCashFlow: [MonthlyCashFlow]
    let spendingByCategory: [CategorySpending]
    let totalIncome: Decimal
    let totalExpenses: Decimal
    let totalInterestEarned: Decimal
    let recentTransactions: [Transaction]
    let totalTransactions: Int
    var portfolio: PortfolioViewData? = nil

    var currencyCode: String { account.currency }

    /// Observed balance movement across the selected period: final visible
    /// resolved balance minus the first. Includes contributions, withdrawals,
    /// and returns — it mirrors the Balance Over Time chart, not investment
    /// return. Zero when there is no resolved history.
    var balanceChange: Decimal {
        guard let first = balanceOverTime.first, let last = balanceOverTime.last else { return 0 }
        return last.balance - first.balance
    }

    /// Signed percentage equivalent of `balanceChange` against the first
    /// visible balance. `nil` when there are fewer than two points or the
    /// starting balance is zero (would divide by zero).
    var balanceChangePercentage: Double? {
        guard balanceOverTime.count >= 2,
              let first = balanceOverTime.first,
              let last = balanceOverTime.last,
              first.balance != 0 else { return nil }
        return (((last.balance - first.balance) / abs(first.balance)) as NSDecimalNumber).doubleValue * 100
    }
}

// MARK: - Liability (credit cards)

struct LiabilityAccountSnapshot {
    let period: DashboardPeriodContext
    let account: DashboardAccountIdentity
    let currentBalance: Decimal
    let creditLimit: Decimal?
    let utilizationPercent: Double?
    let paymentStatement: Statement?
    let chargesVsPayments: [MonthlyChargesPayments]
    let spendingByCategory: [CategorySpending]
    let totalCharges: Decimal
    let totalPayments: Decimal
    let interestCharged: Decimal
    let feesCharged: Decimal
    let activeInstallmentPlans: [InstallmentPlan]
    let sourceStatements: [StatementSourceSummary]
    let recentTransactions: [Transaction]
    let totalTransactions: Int

    var amountOwed: Decimal { abs(currentBalance) }
    var daysUntilDue: Int? {
        guard let due = paymentStatement?.paymentDueDate else { return nil }
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

struct StatementSourceSummary: Identifiable {
    let id: UUID
    let sourceFileName: String?
    let sourceFileHash: String
    let periodStart: Date
    let periodEnd: Date
    let importedAt: Date
    let hasDueDate: Bool
    let hasMinimumPayment: Bool
    let hasNoInterestPayment: Bool

    var metadataStatus: String {
        if hasDueDate && hasMinimumPayment && hasNoInterestPayment { return "Complete" }
        var missing: [String] = []
        if !hasDueDate { missing.append("due date") }
        if !hasMinimumPayment { missing.append("payment amount") }
        return "Missing \(missing.joined(separator: " and "))"
    }

    var displayName: String {
        sourceFileName ?? String(sourceFileHash.prefix(8))
    }

    var archiveStatus: String {
        if sourceFileName != nil { return "In archive" }
        return "Source file not found in archive"
    }
}

enum PaymentDueDisplayState {
    case noStatement
    case statementNoDueDate
    case dueDateOnly(due: Date, daysUntilDue: Int?)
    case full(due: Date, daysUntilDue: Int?, minimum: Decimal?, noInterest: Decimal?)

    static func from(paymentStatement: Statement?, daysUntilDue: Int?) -> PaymentDueDisplayState {
        guard let stmt = paymentStatement else {
            return .noStatement
        }
        guard let due = stmt.paymentDueDate else {
            return .statementNoDueDate
        }
        if stmt.minimumPayment != nil || stmt.paymentForNoInterest != nil {
            return .full(due: due, daysUntilDue: daysUntilDue, minimum: stmt.minimumPayment, noInterest: stmt.paymentForNoInterest)
        }
        return .dueDateOnly(due: due, daysUntilDue: daysUntilDue)
    }
}
