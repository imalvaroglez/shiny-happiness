import Foundation

enum InterestAccrualSource: Equatable, Sendable {
    case manual
    case imported
}

struct InterestAccrualInput: Sendable {
    let transactionID: UUID
    let accountID: UUID
    let currency: String
    let postedAt: Date
    let amount: Decimal
    let accountOpenedAt: Date
    let source: InterestAccrualSource
    let regularIncomeEligible: Bool

    init(
        transactionID: UUID,
        accountID: UUID,
        currency: String,
        postedAt: Date,
        amount: Decimal,
        accountOpenedAt: Date,
        source: InterestAccrualSource,
        regularIncomeEligible: Bool = true
    ) {
        self.transactionID = transactionID
        self.accountID = accountID
        self.currency = currency
        self.postedAt = postedAt
        self.amount = amount
        self.accountOpenedAt = accountOpenedAt
        self.source = source
        self.regularIncomeEligible = regularIncomeEligible
    }
}

enum InterestAllocationKind: Hashable, Sendable {
    case estimated
    case actual
    case undistributed
}

struct InterestDailyAllocation: Identifiable, Hashable, Sendable {
    let sourceTransactionIDs: [UUID]
    let accountID: UUID
    let currency: String
    let day: Date
    let amount: Decimal
    let incomeAmount: Decimal
    let sourceDate: Date
    let intervalStart: Date
    let intervalEnd: Date
    let originalAmount: Decimal
    let originalIncomeAmount: Decimal
    let kind: InterestAllocationKind

    var sourceTransactionID: UUID { sourceTransactionIDs[0] }
    var id: String { "\(sourceTransactionIDs.map(\.uuidString).joined(separator: "-"))-\(day.timeIntervalSince1970)" }
}

enum InterestAccrualAllocator {
    private struct CaptureDay: Hashable {
        let accountID: UUID
        let currency: String
        let day: Date
    }

    static func allocate(
        _ inputs: [InterestAccrualInput],
        through asOf: Date,
        calendar: Calendar = .current
    ) -> [InterestDailyAllocation] {
        let eligible = inputs.filter { $0.amount > 0 && $0.postedAt <= asOf }
        var results: [InterestDailyAllocation] = []

        for input in eligible where input.source == .imported {
            let day = calendar.startOfDay(for: input.postedAt)
            results.append(InterestDailyAllocation(
                sourceTransactionIDs: [input.transactionID],
                accountID: input.accountID,
                currency: input.currency,
                day: day,
                amount: input.amount,
                incomeAmount: input.regularIncomeEligible ? input.amount : 0,
                sourceDate: input.postedAt,
                intervalStart: day,
                intervalEnd: day,
                originalAmount: input.amount,
                originalIncomeAmount: input.regularIncomeEligible ? input.amount : 0,
                kind: .actual
            ))
        }

        let manualInputs = eligible.filter { $0.source == .manual }
        let grouped = Dictionary(grouping: manualInputs) { input in
            CaptureDay(
                accountID: input.accountID,
                currency: input.currency,
                day: calendar.startOfDay(for: input.postedAt)
            )
        }
        let orderedDays = grouped.keys.sorted {
            if $0.accountID != $1.accountID { return $0.accountID.uuidString < $1.accountID.uuidString }
            if $0.currency != $1.currency { return $0.currency < $1.currency }
            return $0.day < $1.day
        }

        var previousCaptureByAccount: [String: Date] = [:]
        for capture in orderedDays {
            guard let dayInputs = grouped[capture] else { continue }
            let key = "\(capture.accountID.uuidString)|\(capture.currency)"
            let previousCapture = previousCaptureByAccount[key]
            let openedAt = dayInputs.map { calendar.startOfDay(for: $0.accountOpenedAt) }.min() ?? capture.day
            let intervalStart: Date
            if let previousCapture {
                intervalStart = calendar.date(byAdding: .day, value: 1, to: previousCapture) ?? capture.day
            } else {
                intervalStart = openedAt
            }

            if intervalStart > capture.day {
                let originalAmount = dayInputs.reduce(Decimal.zero) { $0 + $1.amount }
                let originalIncomeAmount = dayInputs.filter(\.regularIncomeEligible).reduce(Decimal.zero) { $0 + $1.amount }
                results.append(InterestDailyAllocation(
                    sourceTransactionIDs: dayInputs.map(\.transactionID).sorted { $0.uuidString < $1.uuidString },
                    accountID: capture.accountID,
                    currency: capture.currency,
                    day: capture.day,
                    amount: originalAmount,
                    incomeAmount: originalIncomeAmount,
                    sourceDate: dayInputs.map(\.postedAt).max() ?? capture.day,
                    intervalStart: capture.day,
                    intervalEnd: capture.day,
                    originalAmount: originalAmount,
                    originalIncomeAmount: originalIncomeAmount,
                    kind: .undistributed
                ))
            } else {
                let dayCount = (calendar.dateComponents([.day], from: intervalStart, to: capture.day).day ?? 0) + 1
                guard dayCount > 0 else { continue }
                let originalAmount = dayInputs.reduce(Decimal.zero) { $0 + $1.amount }
                let originalIncomeAmount = dayInputs.filter(\.regularIncomeEligible).reduce(Decimal.zero) { $0 + $1.amount }
                let amounts = dailyAmounts(originalAmount, count: dayCount)
                let incomeAmounts = dailyAmounts(originalIncomeAmount, count: dayCount)
                let sourceIDs = dayInputs.map(\.transactionID).sorted { $0.uuidString < $1.uuidString }
                for offset in 0..<dayCount {
                    guard let day = calendar.date(byAdding: .day, value: offset, to: intervalStart) else { continue }
                    results.append(InterestDailyAllocation(
                        sourceTransactionIDs: sourceIDs,
                        accountID: capture.accountID,
                        currency: capture.currency,
                        day: day,
                        amount: amounts[offset],
                        incomeAmount: incomeAmounts[offset],
                        sourceDate: dayInputs.map(\.postedAt).max() ?? capture.day,
                        intervalStart: intervalStart,
                        intervalEnd: capture.day,
                        originalAmount: originalAmount,
                        originalIncomeAmount: originalIncomeAmount,
                        kind: .estimated
                    ))
                }
            }
            previousCaptureByAccount[key] = capture.day
        }

        return results.sorted {
            if $0.day != $1.day { return $0.day < $1.day }
            if $0.accountID != $1.accountID { return $0.accountID.uuidString < $1.accountID.uuidString }
            return $0.id < $1.id
        }
    }

    private static func dailyAmounts(_ amount: Decimal, count: Int) -> [Decimal] {
        guard count > 0 else { return [] }
        var quotient = amount / Decimal(count)
        var base = Decimal()
        NSDecimalRound(&base, &quotient, 2, .down)
        let remainder = amount - base * Decimal(count)
        let extraCents = max(0, NSDecimalNumber(decimal: remainder * 100).intValue)
        return (0..<count).map { offset in
            base + (offset < extraCents ? Decimal(string: "0.01")! : 0)
        }
    }
}
