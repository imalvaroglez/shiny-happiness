import Foundation
import os
import SwiftData

struct YearMonth: Hashable, Identifiable {
    let year: Int
    let month: Int

    var id: String { "\(year)-\(month)" }

    init(year: Int, month: Int) {
        self.year = year
        self.month = month
    }

    init(date: Date, calendar: Calendar = Calendar(identifier: .gregorian)) {
        let parts = calendar.dateComponents([.year, .month], from: date)
        self.year = parts.year ?? 2000
        self.month = parts.month ?? 1
    }

    var startDate: Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: 1))!
    }

    var displayName: String {
        startDate.formatted(.dateTime.month(.wide).year())
    }

    var fileNameComponent: String {
        startDate.formatted(.dateTime.year().month(.twoDigits))
    }

    var isCurrentMonth: Bool {
        self == YearMonth(date: .now)
    }

    func addingMonths(_ value: Int) -> YearMonth {
        let date = Calendar(identifier: .gregorian).date(byAdding: .month, value: value, to: startDate) ?? startDate
        return YearMonth(date: date)
    }
}

struct HouseholdSettlementSetup {
    var partnerIncomeEstimate: Decimal
    var useUserIncomeManualOverride: Bool
    var userIncomeManualOverride: Decimal?
    var splitMethod: HouseholdSplitMethod
    var customUserPercent: Decimal?
    var customPartnerPercent: Decimal?
    var notes: String?

    static let empty = HouseholdSettlementSetup(
        partnerIncomeEstimate: 0,
        useUserIncomeManualOverride: false,
        userIncomeManualOverride: nil,
        splitMethod: .monthlyDefault,
        customUserPercent: nil,
        customPartnerPercent: nil,
        notes: nil
    )

    init(
        partnerIncomeEstimate: Decimal,
        useUserIncomeManualOverride: Bool = false,
        userIncomeManualOverride: Decimal? = nil,
        splitMethod: HouseholdSplitMethod = .monthlyDefault,
        customUserPercent: Decimal? = nil,
        customPartnerPercent: Decimal? = nil,
        notes: String? = nil
    ) {
        self.partnerIncomeEstimate = max(Decimal.zero, partnerIncomeEstimate)
        self.useUserIncomeManualOverride = useUserIncomeManualOverride
        self.userIncomeManualOverride = userIncomeManualOverride.map { max(Decimal.zero, $0) }
        self.splitMethod = splitMethod
        self.customUserPercent = customUserPercent
        self.customPartnerPercent = customPartnerPercent
        self.notes = notes
    }

    init(_ estimate: HouseholdPartnerIncomeEstimate?) {
        self.init(
            partnerIncomeEstimate: estimate?.amount ?? 0,
            useUserIncomeManualOverride: estimate?.useUserIncomeManualOverride ?? false,
            userIncomeManualOverride: estimate?.userIncomeManualOverride,
            splitMethod: estimate?.splitMethod ?? .monthlyDefault,
            customUserPercent: estimate?.customUserPercent,
            customPartnerPercent: estimate?.customPartnerPercent,
            notes: estimate?.notes
        )
    }
}

struct HouseholdSettlementRow: Identifiable {
    let transaction: Transaction
    let amount: Decimal
    let userShare: Decimal
    let partnerShare: Decimal

    var id: UUID { transaction.id }
}

struct HouseholdSettlementReport {
    let monthStart: Date
    let detectedUserSalaryIncome: Decimal
    let userSalaryIncome: Decimal
    let partnerIncomeEstimate: Decimal
    let userIncomeShare: Decimal
    let partnerIncomeShare: Decimal
    let splitAvailable: Bool
    let splitMethod: HouseholdSplitMethod
    let usingManualUserIncome: Bool
    let warnings: [String]
    let sharedRows: [HouseholdSettlementRow]
    let ferRows: [HouseholdSettlementRow]
    let userRows: [HouseholdSettlementRow]
    let blockedReason: String?

    var totalHouseholdIncome: Decimal { userSalaryIncome + partnerIncomeEstimate }
    var totalSharedExpenses: Decimal { sharedRows.reduce(0) { $0 + $1.amount } }
    var userFairShare: Decimal { sharedRows.reduce(0) { $0 + $1.userShare } }
    var partnerFairShare: Decimal { sharedRows.reduce(0) { $0 + $1.partnerShare } }
    var partnerOnlyTotal: Decimal { ferRows.reduce(0) { $0 + $1.amount } }
    var userOnlyTotal: Decimal { userRows.reduce(0) { $0 + $1.amount } }
    var totalPaidByUser: Decimal { totalSharedExpenses + partnerOnlyTotal + userOnlyTotal }
    var amountToRecoverFromPartner: Decimal { partnerFairShare + partnerOnlyTotal }
    var userFinalCost: Decimal { totalPaidByUser - amountToRecoverFromPartner }
    /// Count of explicitly included transactions across all three sections.
    var includedTransactionCount: Int { sharedRows.count + ferRows.count + userRows.count }
    var hasIncludedTransactions: Bool { includedTransactionCount > 0 }

    var splitLabel: String {
        guard splitAvailable else { return "Unavailable" }
        return "You \(Self.percent(userIncomeShare)) / Fer \(Self.percent(partnerIncomeShare))"
    }

    var plainTextSummary: String {
        let month = monthStart.formatted(.dateTime.month(.wide).year())
        return [
            "Household Settlement — \(month)",
            "",
            "Income assumptions:",
            "Your salary: \(Self.money(userSalaryIncome))",
            "Fer estimate: \(Self.money(partnerIncomeEstimate))",
            "Split: \(splitLabel)",
            "",
            "Shared expenses:",
            "Total shared: \(Self.money(totalSharedExpenses))",
            "Fer shared portion: \(Self.money(partnerFairShare))",
            "Your shared portion: \(Self.money(userFairShare))",
            "",
            "Fer-only expenses paid by you:",
            Self.money(partnerOnlyTotal),
            "",
            "Total paid by you:",
            Self.money(totalPaidByUser),
            "Your final cost:",
            Self.money(userFinalCost),
            "",
            "Total to recover from Fer:",
            Self.money(amountToRecoverFromPartner)
        ].joined(separator: "\n")
    }

    static func money(_ amount: Decimal, code: String = "MXN") -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: amount as NSDecimalNumber) ?? "$0.00"
    }

    static func percent(_ share: Decimal) -> String {
        String(format: "%.2f%%", (share as NSDecimalNumber).doubleValue * 100)
    }
}

enum HouseholdMonth {
    static func monthStart(for date: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date))!
    }
}

@MainActor
enum HouseholdPartnerIncomeService {
    static func monthStart(for date: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> Date {
        HouseholdMonth.monthStart(for: date, calendar: calendar)
    }

    static func estimate(for month: Date, context: ModelContext) -> HouseholdPartnerIncomeEstimate? {
        let monthStart = monthStart(for: month)
        var descriptor = FetchDescriptor<HouseholdPartnerIncomeEstimate>(
            predicate: #Predicate<HouseholdPartnerIncomeEstimate> { $0.monthStart == monthStart },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    @discardableResult
    static func upsert(
        month: Date,
        amount: Decimal,
        notes: String?,
        useUserIncomeManualOverride: Bool = false,
        userIncomeManualOverride: Decimal? = nil,
        splitMethod: HouseholdSplitMethod = .monthlyDefault,
        customUserPercent: Decimal? = nil,
        customPartnerPercent: Decimal? = nil,
        context: ModelContext
    ) throws -> HouseholdPartnerIncomeEstimate {
        let monthStart = monthStart(for: month)
        let trimmedNotes = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanNotes = trimmedNotes?.isEmpty == true ? nil : trimmedNotes
        if let existing = estimate(for: monthStart, context: context) {
            existing.amount = max(Decimal.zero, amount)
            existing.notes = cleanNotes
            existing.useUserIncomeManualOverride = useUserIncomeManualOverride
            existing.userIncomeManualOverride = userIncomeManualOverride.map { max(Decimal.zero, $0) }
            existing.setSplitMethod(splitMethod)
            existing.customUserPercent = customUserPercent
            existing.customPartnerPercent = customPartnerPercent
            existing.touch()
            try context.save()
            return existing
        }

        let estimate = HouseholdPartnerIncomeEstimate(
            monthStart: monthStart,
            amount: max(Decimal.zero, amount),
            useUserIncomeManualOverride: useUserIncomeManualOverride,
            userIncomeManualOverride: userIncomeManualOverride.map { max(Decimal.zero, $0) },
            splitMethodRaw: splitMethod == .monthlyDefault ? nil : splitMethod.rawValue,
            customUserPercent: customUserPercent,
            customPartnerPercent: customPartnerPercent,
            notes: cleanNotes
        )
        context.insert(estimate)
        try context.save()
        return estimate
    }
}

@MainActor
enum HouseholdSettlementReportService {
    static func report(for month: Date, setup overrideSetup: HouseholdSettlementSetup? = nil, context: ModelContext) -> HouseholdSettlementReport {
        let monthStart = HouseholdPartnerIncomeService.monthStart(for: month)
        let transactions = transactions(for: monthStart, context: context)
        let setup = overrideSetup ?? HouseholdSettlementSetup(HouseholdPartnerIncomeService.estimate(for: monthStart, context: context))
        return HouseholdSettlementCalculator.build(monthStart: monthStart, transactions: transactions, setup: setup)
    }

    static func transactions(for month: Date, context: ModelContext) -> [Transaction] {
        let monthStart = HouseholdPartnerIncomeService.monthStart(for: month)
        let range = DateRange.month(monthStart)
        let start = range.start
        let end = range.end
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate<Transaction> { tx in
                tx.deletedAt == nil && tx.postedAt >= start && tx.postedAt <= end
            },
            sortBy: [SortDescriptor(\.postedAt)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    static func report(for month: Date, partnerIncomeEstimate: Decimal? = nil, context: ModelContext) -> HouseholdSettlementReport {
        if let partnerIncomeEstimate {
            return report(
                for: month,
                setup: HouseholdSettlementSetup(partnerIncomeEstimate: partnerIncomeEstimate),
                context: context
            )
        }
        return report(for: month, setup: nil, context: context)
    }

    static func build(monthStart: Date, transactions: [Transaction], partnerIncomeEstimate: Decimal) -> HouseholdSettlementReport {
        HouseholdSettlementCalculator.build(
            monthStart: monthStart,
            transactions: transactions,
            setup: HouseholdSettlementSetup(partnerIncomeEstimate: partnerIncomeEstimate)
        )
    }

    static func build(monthStart: Date, transactions: [Transaction], setup: HouseholdSettlementSetup) -> HouseholdSettlementReport {
        HouseholdSettlementCalculator.build(monthStart: monthStart, transactions: transactions, setup: setup)
    }

    static func isSettlementEligible(_ transaction: Transaction) -> Bool {
        TransactionClassifier().classify(transaction: transaction).countsAsRegularExpense
    }
}

@MainActor
enum HouseholdAllocationRepairService {
    static func repairIfNeeded(context: ModelContext) {
        guard ((try? context.fetchCount(FetchDescriptor<Account>())) ?? 0) > 0 else { return }
        let transactions = (try? context.fetch(FetchDescriptor<Transaction>())) ?? []
        guard repair(transactions: transactions) else { return }
        do {
            try context.save()
        } catch {
            Logger.app.error("Failed to persist Household allocation repair: \(error)")
        }
    }

    @discardableResult
    static func repair(transactions: [Transaction]) -> Bool {
        var changed = false
        for transaction in transactions {
            let before = Snapshot(transaction)

            // Normalize legacy allocation overrides (50/50, custom-percent → exact Custom).
            if HouseholdSettlementReportService.isSettlementEligible(transaction) {
                try? transaction.setHouseholdAllocation(transaction.resolvedHouseholdAllocation)
            }

            // One-time Household scope migration: only rows with no explicit scope.
            // Derive from legacy assignment via the shared resolver, then persist the
            // explicit raw so this never re-runs and never re-includes an excluded tx.
            if transaction.householdScopeRaw == nil {
                transaction.setHouseholdScope(
                    HouseholdScopeResolver.resolveScope(assignmentRaw: transaction.expenseAssignmentRaw)
                )
            }

            if Snapshot(transaction) != before {
                transaction.touch()
                changed = true
            }
        }
        return changed
    }

    private struct Snapshot: Equatable {
        let assignment: String?
        let split: String?
        let userPercent: Decimal?
        let partnerValue: Decimal?
        let scope: String?

        init(_ transaction: Transaction) {
            assignment = transaction.expenseAssignmentRaw
            split = transaction.splitMethodOverrideRaw
            userPercent = transaction.customUserPercent
            partnerValue = transaction.customPartnerPercent
            scope = transaction.householdScopeRaw
        }
    }
}

enum HouseholdSettlementCalculator {
    static func build(monthStart: Date, transactions: [Transaction], setup: HouseholdSettlementSetup) -> HouseholdSettlementReport {
        let classifier = TransactionClassifier()
        let detectedSalary = transactions
            .filter { classifier.classify(transaction: $0).countsAsRegularIncome && isSalaryIncome($0) }
            .reduce(Decimal.zero) { $0 + $1.amount }
        let userSalary = setup.useUserIncomeManualOverride ? max(0, setup.userIncomeManualOverride ?? 0) : detectedSalary
        let monthlyShares = shares(
            method: setup.splitMethod,
            userSalary: userSalary,
            partnerIncome: setup.partnerIncomeEstimate,
            customUser: setup.customUserPercent,
            customPartner: setup.customPartnerPercent
        )

        let expenseRows = transactions.filter {
            classifier.classify(transaction: $0).countsAsRegularExpense
                && $0.householdScope == .included
        }
        let sharedTransactions = expenseRows.filter {
            if case .shared = $0.resolvedHouseholdAllocation { return true }
            return false
        }
        let needsMonthlySplit = !sharedTransactions.isEmpty
        let blocked = needsMonthlySplit && !monthlyShares.available
        let warnings = warnings(
            setup: setup,
            detectedSalary: detectedSalary,
            userSalary: userSalary,
            partnerIncome: setup.partnerIncomeEstimate,
            monthlySharesAvailable: monthlyShares.available
        )
        let blockedReason = blocked ? warnings.first ?? "Income assumptions are incomplete." : nil

        var sharedRows: [HouseholdSettlementRow] = []
        var ferRows: [HouseholdSettlementRow] = []
        var userRows: [HouseholdSettlementRow] = []
        for transaction in expenseRows {
            let amount = abs(transaction.amount)
            switch transaction.resolvedHouseholdAllocation {
            case .user:
                userRows.append(HouseholdSettlementRow(transaction: transaction, amount: amount, userShare: amount, partnerShare: 0))
            case .shared:
                sharedRows.append(sharedRow(transaction, monthlyShares: monthlyShares, monthlyDefaultBlocked: blocked))
            case .partner:
                ferRows.append(HouseholdSettlementRow(transaction: transaction, amount: amount, userShare: 0, partnerShare: amount))
            case .custom(let ferAmount):
                sharedRows.append(HouseholdSettlementRow(
                    transaction: transaction,
                    amount: amount,
                    userShare: amount - ferAmount,
                    partnerShare: ferAmount
                ))
            }
        }

        return HouseholdSettlementReport(
            monthStart: monthStart,
            detectedUserSalaryIncome: detectedSalary,
            userSalaryIncome: userSalary,
            partnerIncomeEstimate: setup.partnerIncomeEstimate,
            userIncomeShare: monthlyShares.user,
            partnerIncomeShare: monthlyShares.partner,
            splitAvailable: monthlyShares.available,
            splitMethod: setup.splitMethod,
            usingManualUserIncome: setup.useUserIncomeManualOverride,
            warnings: warnings,
            sharedRows: sharedRows,
            ferRows: ferRows,
            userRows: userRows,
            blockedReason: blockedReason
        )
    }

    private static func shares(
        method: HouseholdSplitMethod,
        userSalary: Decimal,
        partnerIncome: Decimal,
        customUser: Decimal?,
        customPartner: Decimal?
    ) -> (user: Decimal, partner: Decimal, available: Bool) {
        switch method {
        case .monthlyDefault:
            let total = userSalary + partnerIncome
            guard total > 0, !(userSalary == 0 && partnerIncome > 0) else { return (0, 0, false) }
            return (userSalary / total, partnerIncome / total, true)
        case .fiftyFifty:
            return (Decimal(string: "0.5")!, Decimal(string: "0.5")!, true)
        case .customPercent:
            guard let user = customUser,
                  let partner = customPartner,
                  user >= 0, partner >= 0, user + partner == 100 else {
                return (0, 0, false)
            }
            return (user / 100, partner / 100, true)
        }
    }

    private static func warnings(
        setup: HouseholdSettlementSetup,
        detectedSalary: Decimal,
        userSalary: Decimal,
        partnerIncome: Decimal,
        monthlySharesAvailable: Bool
    ) -> [String] {
        var result: [String] = []
        if detectedSalary == 0 && !setup.useUserIncomeManualOverride {
            result.append("No salary income detected for this month. Add a salary transaction or use a manual override to calculate a proportional split.")
        }
        switch setup.splitMethod {
        case .monthlyDefault:
            if userSalary + partnerIncome == 0 {
                result.append("Income assumptions are incomplete. Add your salary income or Fer's estimate to calculate the proportional split.")
            } else if userSalary == 0 && partnerIncome > 0 {
                result.append("Your salary income is missing. Use a manual override, 50/50, or custom split before assigning Fer 100%.")
            } else if partnerIncome == 0 && userSalary > 0 {
                result.append("Fer income estimate is missing. Proportional split assigns 100% to you.")
            }
        case .customPercent where !monthlySharesAvailable:
            result.append("Custom split must total 100%.")
        default:
            break
        }
        return Array(Set(result)).sorted()
    }

    private static func sharedRow(
        _ transaction: Transaction,
        monthlyShares: (user: Decimal, partner: Decimal, available: Bool),
        monthlyDefaultBlocked: Bool
    ) -> HouseholdSettlementRow {
        let amount = abs(transaction.amount)
        let rowShares = monthlyDefaultBlocked
            ? (user: Decimal.zero, partner: Decimal.zero)
            : (user: monthlyShares.user, partner: monthlyShares.partner)
        return HouseholdSettlementRow(
            transaction: transaction,
            amount: amount,
            userShare: amount * rowShares.user,
            partnerShare: amount * rowShares.partner
        )
    }

    private static func isSalaryIncome(_ transaction: Transaction) -> Bool {
        guard let category = transaction.category,
              category.kind == .income else { return false }
        let normalized = category.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "salary" || normalized == "compensation"
    }
}
