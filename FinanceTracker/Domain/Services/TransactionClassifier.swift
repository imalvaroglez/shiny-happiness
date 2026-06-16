import Foundation

struct TransactionClassification: Equatable {
    var isTransfer: Bool
    var affectsBalance: Bool
    var countsAsRegularIncome: Bool
    var countsAsRegularExpense: Bool
    var countsAsOperatingCashFlow: Bool
    var countsAsRetirementContribution: Bool
    var countsAsInvestmentReturn: Bool
    var countsAsValuationAdjustment: Bool
    var countsAsTaxTrackablePPR: Bool
}

struct TransactionClassifier {
    private static let ownAccountPatterns: [String] = [
        "(?i)PAGO\\s+RECIBIDO\\s+DE\\s+STP\\s+POR\\s+ORDEN\\s+DE\\s+TITULAR",
        "(?i)recibida\\s+(de\\s+la\\s+)?cuenta\\s+4444\\s+BANAMEX",
        "(?i)PAGO\\s+INTERBANCARIO\\s+PAGO\\s+RECIBIDO\\s+DE.*STP.*TITULAR",
    ]

    func classify(
        transaction tx: Transaction,
        sourceAccount: Account? = nil,
        destinationAccount: Account? = nil,
        category: Category? = nil
    ) -> TransactionClassification {
        let account = sourceAccount ?? tx.account
        let category = category ?? tx.category
        let movement = tx.movementKind
        let treatment = tx.treatmentKind
        let isTransfer = movement == .transfer || tx.isTransfer || category?.kind == .transfer || category?.kind == .creditCardPayment
        let retirementContribution = treatment == .retirementContributionUserFunded
            || treatment == .retirementContributionEmployerFunded
            || treatment == .statutoryRetirementContribution
        let investmentReturn = treatment == .investmentReturn
        let valuationAdjustment = treatment == .valuationAdjustment
        let fee = treatment == .fee

        let oldDashboardExcluded = tx.isDuplicate
            || isTransfer
            || (account?.type.isLiability == true && tx.amount > 0)
            || isOwnAccountMovement(tx)
            || isSynthesizedMSIPurchase(tx)

        let semanticExcluded = retirementContribution || investmentReturn || valuationAdjustment || fee
        let accountAllowsCashFlow = account?.effectiveIncludeInCashFlow ?? true
        let cashFlowEligible = !oldDashboardExcluded && !semanticExcluded && accountAllowsCashFlow

        let regularIncome = cashFlowEligible
            && tx.amount > 0
            && movement == .income
            && treatment == .regular
            && (account?.effectiveIncludeInRegularIncome ?? true)
        let regularExpense = cashFlowEligible
            && tx.amount < 0
            && movement == .expense
            && treatment == .regular

        return TransactionClassification(
            isTransfer: isTransfer,
            affectsBalance: tx.deletedAt == nil && !tx.isDuplicate,
            countsAsRegularIncome: regularIncome,
            countsAsRegularExpense: regularExpense,
            countsAsOperatingCashFlow: regularIncome || regularExpense,
            countsAsRetirementContribution: retirementContribution,
            countsAsInvestmentReturn: investmentReturn,
            countsAsValuationAdjustment: valuationAdjustment,
            countsAsTaxTrackablePPR: retirementContribution && (destinationAccount ?? account)?.isTaxTrackablePPR == true
        )
    }

    private func isSynthesizedMSIPurchase(_ tx: Transaction) -> Bool {
        if let plan = tx.installmentPlan, abs(tx.amount) == abs(plan.originalAmount) {
            return true
        }
        return false
    }

    private func isOwnAccountMovement(_ tx: Transaction) -> Bool {
        Self.ownAccountPatterns.contains {
            tx.descriptionRaw.range(of: $0, options: .regularExpression) != nil
        }
    }
}
