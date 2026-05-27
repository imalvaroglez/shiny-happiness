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

    var currencyCode: String { account.currency }
}

// MARK: - Liability (credit cards)

struct LiabilityAccountSnapshot {
    let account: DashboardAccountIdentity
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
    let sourceStatements: [StatementSourceSummary]
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

    static func from(latestStatement: Statement?, daysUntilDue: Int?) -> PaymentDueDisplayState {
        guard let stmt = latestStatement else {
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
