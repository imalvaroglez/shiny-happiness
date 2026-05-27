import Testing
import Foundation
@testable import FinanceTracker

@Suite("Incoming Transfer Rules")
struct IncomingTransferRulesTests {

    private func makeTransaction(description: String, amount: Decimal = 25000) -> Transaction {
        Transaction(
            postedAt: Date(),
            amount: amount,
            descriptionRaw: description
        )
    }

    private func makeRule(pattern: String, categoryName: String, categoryKind: CategoryKind = .transfer, priority: Int = 10) -> CategoryRule {
        let category = Category(name: categoryName, kind: categoryKind)
        return CategoryRule(
            patternRegex: pattern,
            merchantMatch: "",
            category: category,
            priority: priority
        )
    }

    private func makeSeedRules() -> [CategoryRule] {
        let transferParent = Category(name: "Transfers", kind: .transfer)
        let ccParent = Category(name: "Credit Card Payments", kind: .creditCardPayment)
        return [
            makeRule(pattern: "(?i)PAGO\\s+RECIBIDO\\s+DE\\s+STP\\s+POR\\s+ORDEN\\s+DE\\s+TITULAR", categoryName: "To Own Accounts", categoryKind: .transfer, priority: 110),
            makeRule(pattern: "(?i)recibida\\s+(de\\s+la\\s+)?cuenta\\s+4444\\s+BANAMEX", categoryName: "To Own Accounts", categoryKind: .transfer, priority: 110),
            makeRule(pattern: "(?i)PAGO\\s+INTERBANCARIO\\s+PAGO\\s+RECIBIDO\\s+DE.*STP.*TITULAR", categoryName: "Card Payment Received", categoryKind: .creditCardPayment, priority: 110),
        ]
    }

    private func makeLearnedIncomeRules() -> [CategoryRule] {
        [
            makeRule(pattern: "(?i)RECIBIDA", categoryName: "Salary", categoryKind: .income, priority: 90),
            makeRule(pattern: "(?i)TRANSFERENCIA", categoryName: "Refund", categoryKind: .income, priority: 100),
            makeRule(pattern: "(?i)PAGO", categoryName: "Other Income", categoryKind: .income, priority: 5),
        ]
    }

    @Test("STP incoming own transfer beats learned income rules")
    func stpIncomingOwnTransfer() {
        let tx = makeTransaction(description: "PAGO RECIBIDO DE STP POR ORDEN DE TITULAR PRUEBA Transferencia 20260515")
        let rules = makeSeedRules() + makeLearnedIncomeRules()

        let result = Categorizer.categorize(transactions: [tx], rules: rules)

        #expect(result.categorized == 1)
        #expect(tx.category?.kind == .transfer, "Should be transfer, got \(tx.category.map { String(describing: $0.kind) } ?? "nil")")
    }

    @Test("Incoming from own Banamex 4444 categorized as transfer")
    func incomingFromOwnBanamex() {
        let tx = makeTransaction(description: "Transferencia recibida de la cuenta 4444 BANAMEX, TITULAR PRUEBA, 20260515")
        let rules = makeSeedRules() + makeLearnedIncomeRules()

        let result = Categorizer.categorize(transactions: [tx], rules: rules)

        #expect(result.categorized == 1)
        #expect(tx.category?.kind == .transfer, "Should be transfer, got \(tx.category.map { String(describing: $0.kind) } ?? "nil")")
    }

    @Test("STP credit-card payment received categorized correctly")
    func creditCardPaymentReceived() {
        let tx = makeTransaction(description: "PAGO INTERBANCARIO PAGO RECIBIDO DE: STP/SIST TRANSF Y PAGOS TITULAR PRUEBA 20260515")
        let rules = makeSeedRules() + makeLearnedIncomeRules()

        let result = Categorizer.categorize(transactions: [tx], rules: rules)

        #expect(result.categorized == 1)
        #expect(tx.category?.name == "Card Payment Received", "Should be Card Payment Received, got \(tx.category?.name ?? "nil")")
    }

    @Test("ABONO NOMINA remains salary")
    func payrollStillSalary() {
        let salaryRule = makeRule(pattern: "(?i)NOMINA|SUELDO|PAGO\\s*NOMINA", categoryName: "Salary", categoryKind: .income, priority: 10)
        let tx = makeTransaction(description: "ABONO NOMINA 20260515")
        let rules = makeSeedRules() + [salaryRule]

        let result = Categorizer.categorize(transactions: [tx], rules: rules)

        #expect(result.categorized == 1)
        #expect(tx.category?.name == "Salary", "Payroll should remain salary, got \(tx.category?.name ?? "nil")")
    }

    @Test("External incoming STP not forced into transfer")
    func externalIncomingUntouched() {
        let tx = makeTransaction(description: "PAGO RECIBIDO DE STP POR ORDEN DE MARIA GARCIA Transferencia 20260515")
        let incomeRule = makeRule(pattern: "(?i)PAGO", categoryName: "Other Income", categoryKind: .income, priority: 5)
        let rules = makeSeedRules() + [incomeRule]

        let result = Categorizer.categorize(transactions: [tx], rules: rules)

        #expect(tx.category?.kind != .transfer, "External payment should not be forced to transfer, got \(tx.category.map { String(describing: $0.kind) } ?? "nil")")
    }

    @Test("Priority 110 beats priority 90 learned income rule")
    func priority110BeatsPriority90() {
        let tx = makeTransaction(description: "PAGO RECIBIDO DE STP POR ORDEN DE TITULAR PRUEBA")
        let learnedRule = makeRule(pattern: "(?i)PAGO\\s+RECIBIDO\\s+DE\\s+STP", categoryName: "Refund", categoryKind: .income, priority: 90)
        let rules = makeSeedRules() + [learnedRule]

        _ = Categorizer.categorize(transactions: [tx], rules: rules)

        #expect(tx.category?.kind == .transfer, "Priority 110 seed rule should beat priority 90 learned rule, got \(tx.category.map { String(describing: $0.kind) } ?? "nil")")
    }
}
