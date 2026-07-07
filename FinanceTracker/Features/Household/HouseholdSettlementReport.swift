import Foundation
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
    let unassignedRows: [HouseholdSettlementRow]
    let sharedRows: [HouseholdSettlementRow]
    let partnerRows: [HouseholdSettlementRow]
    let excludedPersonalRows: [HouseholdSettlementRow]
    let blockedReason: String?

    var totalHouseholdIncome: Decimal { userSalaryIncome + partnerIncomeEstimate }
    var totalSharedExpenses: Decimal { sharedRows.reduce(0) { $0 + $1.amount } }
    var userFairShare: Decimal { sharedRows.reduce(0) { $0 + $1.userShare } }
    var partnerFairShare: Decimal { sharedRows.reduce(0) { $0 + $1.partnerShare } }
    var partnerOnlyTotal: Decimal { partnerRows.reduce(0) { $0 + $1.amount } }
    var totalPaidByUser: Decimal { totalSharedExpenses + partnerOnlyTotal }
    var amountToRecoverFromPartner: Decimal { partnerFairShare + partnerOnlyTotal }
    var userFinalCost: Decimal { userFairShare }

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

        let expenseRows = transactions.filter { classifier.classify(transaction: $0).countsAsRegularExpense }
        let sharedTransactions = expenseRows.filter { $0.expenseAssignment == .shared }
        let needsMonthlySplit = sharedTransactions.contains { $0.splitMethodOverride == .monthlyDefault }
        let blocked = needsMonthlySplit && !monthlyShares.available
        let warnings = warnings(
            setup: setup,
            detectedSalary: detectedSalary,
            userSalary: userSalary,
            partnerIncome: setup.partnerIncomeEstimate,
            monthlySharesAvailable: monthlyShares.available
        )
        let blockedReason = blocked ? warnings.first ?? "Income assumptions are incomplete." : nil

        let sharedRows = sharedTransactions.map {
            sharedRow($0, monthlyShares: monthlyShares, monthlyDefaultBlocked: blocked)
        }
        let partnerRows = expenseRows
            .filter { $0.expenseAssignment == .partner }
            .map { HouseholdSettlementRow(transaction: $0, amount: abs($0.amount), userShare: 0, partnerShare: abs($0.amount)) }
        let personalRows = expenseRows
            .filter { $0.expenseAssignment == .user }
            .map { HouseholdSettlementRow(transaction: $0, amount: abs($0.amount), userShare: abs($0.amount), partnerShare: 0) }
        let unassignedRows = expenseRows
            .filter { $0.expenseAssignment == .unassigned }
            .map { HouseholdSettlementRow(transaction: $0, amount: abs($0.amount), userShare: 0, partnerShare: 0) }

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
            unassignedRows: unassignedRows,
            sharedRows: sharedRows,
            partnerRows: partnerRows,
            excludedPersonalRows: personalRows,
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
        let rowShares: (user: Decimal, partner: Decimal)
        switch transaction.splitMethodOverride {
        case .monthlyDefault:
            rowShares = monthlyDefaultBlocked ? (0, 0) : (monthlyShares.user, monthlyShares.partner)
        case .fiftyFifty:
            rowShares = (Decimal(string: "0.5")!, Decimal(string: "0.5")!)
        case .customPercent:
            if let user = transaction.customUserPercent,
               let partner = transaction.customPartnerPercent,
               user >= 0, partner >= 0, user + partner == 100 {
                rowShares = (user / 100, partner / 100)
            } else {
                rowShares = monthlyShares.available ? (monthlyShares.user, monthlyShares.partner) : (0, 0)
            }
        }
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
