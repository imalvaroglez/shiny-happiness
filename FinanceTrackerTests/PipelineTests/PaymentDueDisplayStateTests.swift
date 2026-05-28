import Testing
import Foundation
@testable import FinanceTracker

@Suite("Payment Due Display State")
struct PaymentDueDisplayStateTests {

    private func dateFromComponents(year: Int, month: Int, day: Int) -> Date {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day
        c.timeZone = TimeZone(identifier: "America/Mexico_City")
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    @Test("No statement → .noStatement")
    func noStatement() {
        let state = PaymentDueDisplayState.from(paymentStatement: nil, daysUntilDue: nil)
        if case .noStatement = state {} else {
            Issue.record("Expected .noStatement, got \(state)")
        }
    }

    @Test("Statement with nil due date → .statementNoDueDate")
    func statementNoDueDate() {
        let stmt = Statement(
            periodStart: .now,
            periodEnd: .now,
            sourceFileHash: "test"
        )
        let state = PaymentDueDisplayState.from(paymentStatement: stmt, daysUntilDue: nil)
        if case .statementNoDueDate = state {} else {
            Issue.record("Expected .statementNoDueDate, got \(state)")
        }
    }

    @Test("Statement with due date but no payment amounts → .dueDateOnly")
    func dueDateOnly() {
        let due = dateFromComponents(year: 2026, month: 6, day: 30)
        let stmt = Statement(
            periodStart: .now,
            periodEnd: .now,
            sourceFileHash: "test",
            paymentDueDate: due
        )
        let state = PaymentDueDisplayState.from(paymentStatement: stmt, daysUntilDue: 5)
        if case .dueDateOnly(let d, let days) = state {
            #expect(Calendar.current.isDate(d, inSameDayAs: due))
            #expect(days == 5)
        } else {
            Issue.record("Expected .dueDateOnly, got \(state)")
        }
    }

    @Test("Statement with all fields → .full")
    func fullState() {
        let due = dateFromComponents(year: 2026, month: 6, day: 30)
        let stmt = Statement(
            periodStart: .now,
            periodEnd: .now,
            sourceFileHash: "test",
            minimumPayment: 3600,
            paymentForNoInterest: 45000,
            paymentDueDate: due
        )
        let state = PaymentDueDisplayState.from(paymentStatement: stmt, daysUntilDue: 10)
        if case .full(let d, let days, let min, let noInt) = state {
            #expect(Calendar.current.isDate(d, inSameDayAs: due))
            #expect(days == 10)
            #expect(min == 3600)
            #expect(noInt == 45000)
        } else {
            Issue.record("Expected .full, got \(state)")
        }
    }

    @Test("Statement with due date and minimum but nil noInterest → .full with nil noInterest")
    func fullWithPartialAmounts() {
        let due = dateFromComponents(year: 2026, month: 6, day: 30)
        let stmt = Statement(
            periodStart: .now,
            periodEnd: .now,
            sourceFileHash: "test",
            minimumPayment: 3600,
            paymentDueDate: due
        )
        let state = PaymentDueDisplayState.from(paymentStatement: stmt, daysUntilDue: nil)
        if case .full(let d, _, let min, let noInt) = state {
            #expect(Calendar.current.isDate(d, inSameDayAs: due))
            #expect(min == 3600)
            #expect(noInt == nil)
        } else {
            Issue.record("Expected .full with partial amounts, got \(state)")
        }
    }
}
