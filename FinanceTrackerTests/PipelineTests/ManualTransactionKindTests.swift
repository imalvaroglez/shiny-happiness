import Testing
import Foundation
@testable import FinanceTracker

@Suite("Manual Transaction Kind")
struct ManualTransactionKindTests {

    @Test("Checking account returns Income, Expense, Transfer")
    func checkingKinds() {
        let kinds = ManualTransactionKind.availableKinds(for: .checking)
        #expect(kinds == [.income, .expense, .transfer])
    }

    @Test("Investment account returns Income, Expense, Transfer")
    func investmentKinds() {
        let kinds = ManualTransactionKind.availableKinds(for: .investment)
        #expect(kinds == [.income, .expense, .transfer])
    }

    @Test("Credit card returns Charge, Payment")
    func creditCardKinds() {
        let kinds = ManualTransactionKind.availableKinds(for: .creditCard)
        #expect(kinds == [.charge, .payment])
    }

    @Test("Loan returns Charge, Payment")
    func loanKinds() {
        let kinds = ManualTransactionKind.availableKinds(for: .loan)
        #expect(kinds == [.charge, .payment])
    }
}
