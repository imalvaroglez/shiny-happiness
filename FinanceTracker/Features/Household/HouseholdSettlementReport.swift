import Foundation
import os
import SwiftData

struct YearMonth: Hashable, Identifiable, Comparable {
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

    static func < (lhs: YearMonth, rhs: YearMonth) -> Bool {
        if lhs.year != rhs.year { return lhs.year < rhs.year }
        return lhs.month < rhs.month
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
    /// True when the transaction was posted in the report's month. An older Fer
    /// transaction pulled in because its due date lands in this month is `false`
    /// — its cash already counted in the purchase month's "Total paid by you".
    let postedThisMonth: Bool

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
    /// Fer rows due (and therefore recoverable) in this month.
    let ferRows: [HouseholdSettlementRow]
    /// Fer rows posted this month whose due date falls in a future month — visible
    /// ("Pasa a `<mes>`") but excluded from recovery. See
    /// `docs/specs/household-settlement-due-dates.md`.
    let deferredFerRows: [HouseholdSettlementRow]
    let userRows: [HouseholdSettlementRow]
    /// Resolved active due dates by transaction id ( Fer rows only). Absent ⇒ default
    /// to the transaction's `postedAt` month.
    let dueDates: [UUID: Date]
    let blockedReason: String?

    var totalHouseholdIncome: Decimal { userSalaryIncome + partnerIncomeEstimate }
    var totalSharedExpenses: Decimal { sharedRows.reduce(0) { $0 + $1.amount } }
    var userFairShare: Decimal { sharedRows.reduce(0) { $0 + $1.userShare } }
    var partnerFairShare: Decimal { sharedRows.reduce(0) { $0 + $1.partnerShare } }
    /// Fer rows due this month (deferred rows excluded — they are not yet recoverable).
    var partnerOnlyTotal: Decimal { ferRows.reduce(0) { $0 + $1.amount } }
    var userOnlyTotal: Decimal { userRows.reduce(0) { $0 + $1.amount } }
    var deferredFerTotal: Decimal { deferredFerRows.reduce(0) { $0 + $1.amount } }
    /// Cash that left the user's accounts this month. Includes deferred Fer rows
    /// (the purchase happened this month) but excludes older Fer rows pulled in only
    /// because their due date lands here — those counted in their purchase month.
    private var postedThisMonthShared: Decimal { sharedRows.filter(\.postedThisMonth).reduce(0) { $0 + $1.amount } }
    private var postedThisMonthUserOnly: Decimal { userRows.filter(\.postedThisMonth).reduce(0) { $0 + $1.amount } }
    private var postedThisMonthPartnerOnly: Decimal { ferRows.filter(\.postedThisMonth).reduce(0) { $0 + $1.amount } }
    var totalPaidByUser: Decimal { postedThisMonthShared + postedThisMonthPartnerOnly + postedThisMonthUserOnly + deferredFerTotal }
    var amountToRecoverFromPartner: Decimal { partnerFairShare + partnerOnlyTotal }
    var userFinalCost: Decimal { totalPaidByUser - amountToRecoverFromPartner }
    /// Deferred Fer rows posted this month — owed later, shown as a separate line.
    var pendingForUpcomingMonths: Decimal { deferredFerTotal }
    /// Count of explicitly included transactions across all sections (deferred rows
    /// count too, so a deferred-only month is not rendered as the empty state).
    var includedTransactionCount: Int { sharedRows.count + ferRows.count + deferredFerRows.count + userRows.count }
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
            "Fer-only due this month:",
            Self.money(partnerOnlyTotal),
            "Fer-only due count: \(ferRows.count)",
            "Pending for upcoming months:",
            Self.money(pendingForUpcomingMonths),
            "Pending count: \(deferredFerRows.count)",
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
    /// Transactions + resolved due dates for one report month. Older transactions
    /// with an active due-date override landing in this month are pulled in so a Fer
    /// charge made earlier but payable now appears (and sums) in the due month.
    struct HouseholdReportInput {
        let transactions: [Transaction]
        let dueDates: [UUID: Date]
    }

    static func report(for month: Date, setup overrideSetup: HouseholdSettlementSetup? = nil, context: ModelContext) -> HouseholdSettlementReport {
        let monthStart = HouseholdPartnerIncomeService.monthStart(for: month)
        let input = reportInput(for: monthStart, context: context)
        let setup = overrideSetup ?? HouseholdSettlementSetup(HouseholdPartnerIncomeService.estimate(for: monthStart, context: context))
        return HouseholdSettlementCalculator.build(monthStart: monthStart, transactions: input.transactions, dueDates: input.dueDates, setup: setup)
    }

    /// Full report input: posted-in-month transactions PLUS older Fer transactions
    /// whose active due date falls in this month, with the resolved `[UUID: Date]`
    /// active-due-date map. Overrides are resolved in Swift — no optional unwrap or
    /// cross-model join inside `#Predicate`.
    static func reportInput(for month: Date, context: ModelContext) -> HouseholdReportInput {
        let monthStart = HouseholdPartnerIncomeService.monthStart(for: month)
        let range = DateRange.month(monthStart)
        let start = range.start
        let end = range.end

        let postedDescriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate<Transaction> { tx in
                tx.deletedAt == nil && tx.postedAt >= start && tx.postedAt <= end
            },
            sortBy: [SortDescriptor(\.postedAt)]
        )
        let posted = (try? context.fetch(postedDescriptor)) ?? []

        // Resolve active due dates for everything posted this month.
        let postedIDs = Set(posted.map(\.id))
        var dueDates = SettlementDueDateService.activeDueDates(for: postedIDs, context: context)

        // Pull older Fer transactions whose active due date lands in this month.
        // NOTE: filtering an optional Date by range inside #Predicate
        // (`row.dueDate! >= start`) does not evaluate correctly under SwiftData,
        // so we fetch all active overrides and filter the range in Swift.
        let overrideDescriptor = FetchDescriptor<SettlementDueDateOverride>(
            predicate: #Predicate<SettlementDueDateOverride> { row in
                row.dueDate != nil
            }
        )
        let candidateOverrides = ((try? context.fetch(overrideDescriptor)) ?? []).filter { row in
            guard let due = row.dueDate else { return false }
            return due >= start && due <= end
        }
        // Keep newest override per transactionID, then only active (non-tombstone) ones.
        var newestByTx: [UUID: SettlementDueDateOverride] = [:]
        for row in candidateOverrides {
            if let existing = newestByTx[row.transactionID] {
                if row.lastModifiedAt > existing.lastModifiedAt { newestByTx[row.transactionID] = row }
            } else {
                newestByTx[row.transactionID] = row
            }
        }
        let activeDueTxIDs = Set(newestByTx.filter { $0.value.dueDate != nil }.map(\.key))
        let olderIDs = activeDueTxIDs.subtracting(postedIDs)
        var olderTransactions: [Transaction] = []
        if !olderIDs.isEmpty {
            let ids = olderIDs
            let olderDescriptor = FetchDescriptor<Transaction>(
                predicate: #Predicate<Transaction> { tx in
                    tx.deletedAt == nil && ids.contains(tx.id)
                },
                sortBy: [SortDescriptor(\.postedAt)]
            )
            olderTransactions = (try? context.fetch(olderDescriptor)) ?? []
            // Merge their active due dates into the map.
            for tx in olderTransactions {
                if let due = newestByTx[tx.id]?.dueDate { dueDates[tx.id] = due }
            }
        }

        let combined = mergeUnique(posted, olderTransactions)
        return HouseholdReportInput(transactions: combined, dueDates: dueDates)
    }

    private static func mergeUnique(_ a: [Transaction], _ b: [Transaction]) -> [Transaction] {
        var seen = Set<UUID>()
        var result: [Transaction] = []
        for tx in a + b where seen.insert(tx.id).inserted {
            result.append(tx)
        }
        return result
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
            dueDates: [:],
            setup: HouseholdSettlementSetup(partnerIncomeEstimate: partnerIncomeEstimate)
        )
    }

    static func build(monthStart: Date, transactions: [Transaction], setup: HouseholdSettlementSetup) -> HouseholdSettlementReport {
        HouseholdSettlementCalculator.build(monthStart: monthStart, transactions: transactions, dueDates: [:], setup: setup)
    }

    static func build(monthStart: Date, transactions: [Transaction], dueDates: [UUID: Date], setup: HouseholdSettlementSetup) -> HouseholdSettlementReport {
        HouseholdSettlementCalculator.build(monthStart: monthStart, transactions: transactions, dueDates: dueDates, setup: setup)
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
    static func build(monthStart: Date, transactions: [Transaction], dueDates: [UUID: Date], setup: HouseholdSettlementSetup) -> HouseholdSettlementReport {
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

        let reportYM = YearMonth(date: monthStart)

        var sharedRows: [HouseholdSettlementRow] = []
        var ferRows: [HouseholdSettlementRow] = []
        var deferredFerRows: [HouseholdSettlementRow] = []
        var userRows: [HouseholdSettlementRow] = []
        for transaction in expenseRows {
            let amount = abs(transaction.amount)
            let postedThisMonth = YearMonth(date: transaction.postedAt) == reportYM
            switch transaction.resolvedHouseholdAllocation {
            case .user:
                userRows.append(HouseholdSettlementRow(transaction: transaction, amount: amount, userShare: amount, partnerShare: 0, postedThisMonth: postedThisMonth))
            case .shared:
                sharedRows.append(sharedRow(transaction, monthlyShares: monthlyShares, monthlyDefaultBlocked: blocked, postedThisMonth: postedThisMonth))
            case .partner:
                let row = HouseholdSettlementRow(transaction: transaction, amount: amount, userShare: 0, partnerShare: amount, postedThisMonth: postedThisMonth)
                let dueYM = Self.effectiveDueMonth(transaction: transaction, dueDates: dueDates)
                if dueYM <= reportYM {
                    ferRows.append(row)
                } else {
                    deferredFerRows.append(row)
                }
            case .custom(let ferAmount):
                sharedRows.append(HouseholdSettlementRow(
                    transaction: transaction,
                    amount: amount,
                    userShare: amount - ferAmount,
                    partnerShare: ferAmount,
                    postedThisMonth: postedThisMonth
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
            deferredFerRows: deferredFerRows,
            userRows: userRows,
            dueDates: dueDates,
            blockedReason: blockedReason
        )
    }

    /// Effective due month for a transaction: an active override whose month is not
    /// earlier than the purchase month; otherwise the purchase (`postedAt`) month.
    /// A stored date before the purchase defensively resolves to the purchase month.
    private static func effectiveDueMonth(transaction: Transaction, dueDates: [UUID: Date]) -> YearMonth {
        let postedYM = YearMonth(date: transaction.postedAt)
        guard let override = dueDates[transaction.id] else { return postedYM }
        let dueYM = YearMonth(date: override)
        return dueYM < postedYM ? postedYM : dueYM
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
        monthlyDefaultBlocked: Bool,
        postedThisMonth: Bool
    ) -> HouseholdSettlementRow {
        let amount = abs(transaction.amount)
        let rowShares = monthlyDefaultBlocked
            ? (user: Decimal.zero, partner: Decimal.zero)
            : (user: monthlyShares.user, partner: monthlyShares.partner)
        return HouseholdSettlementRow(
            transaction: transaction,
            amount: amount,
            userShare: amount * rowShares.user,
            partnerShare: amount * rowShares.partner,
            postedThisMonth: postedThisMonth
        )
    }

    private static func isSalaryIncome(_ transaction: Transaction) -> Bool {
        guard let category = transaction.category,
              category.kind == .income else { return false }
        let normalized = category.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "salary" || normalized == "compensation"
    }
}
