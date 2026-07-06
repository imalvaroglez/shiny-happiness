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
        if tx.flowKindRaw == nil,
           tx.movementKindRaw == nil,
           tx.treatmentKindRaw == nil,
           !tx.isTransfer,
           !tx.isDuplicate,
           tx.deletedAt == nil,
           tx.installmentPlan == nil,
           category == nil,
           account?.type.isLiability != true,
           account?.effectiveIncludeInCashFlow ?? true,
           !mightBeOwnAccountMovement(tx.descriptionRaw) {
            let regularIncome = tx.amount > 0 && (account?.effectiveIncludeInRegularIncome ?? true)
            let regularExpense = tx.amount < 0
            return TransactionClassification(
                isTransfer: false,
                affectsBalance: true,
                countsAsRegularIncome: regularIncome,
                countsAsRegularExpense: regularExpense,
                countsAsOperatingCashFlow: regularIncome || regularExpense,
                countsAsRetirementContribution: false,
                countsAsInvestmentReturn: false,
                countsAsValuationAdjustment: false,
                countsAsTaxTrackablePPR: false
            )
        }

        let flow = flowKind(for: tx, account: account, category: category)
        let movement = movementKind(for: tx, flow: flow)
        let treatment = treatmentKind(for: tx)
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

    private func flowKind(for tx: Transaction, account: Account?, category: Category?) -> TransactionFlowKind {
        if let raw = tx.flowKindRaw, let kind = TransactionFlowKind(rawValue: raw) {
            return kind
        }
        if tx.isTransfer { return .transfer }
        if account?.type.isLiability == true {
            if tx.amount > 0 {
                return category?.kind == .creditCardPayment ? .payment : .cardCredit
            }
            return .charge
        }
        return tx.amount >= 0 ? .income : .expense
    }

    private func movementKind(for tx: Transaction, flow: TransactionFlowKind) -> TransactionMovementKind {
        if let raw = tx.movementKindRaw, let kind = TransactionMovementKind(rawValue: raw) {
            return kind
        }
        return Transaction.movementKind(from: flow, amount: tx.amount, isTransfer: tx.isTransfer)
    }

    private func treatmentKind(for tx: Transaction) -> TransactionTreatmentKind {
        if let raw = tx.treatmentKindRaw, let kind = TransactionTreatmentKind(rawValue: raw) {
            return kind
        }
        return .regular
    }

    private func isOwnAccountMovement(_ tx: Transaction) -> Bool {
        let description = tx.descriptionRaw
        guard mightBeOwnAccountMovement(description) else {
            return false
        }

        return Self.ownAccountPatterns.contains {
            description.range(of: $0, options: .regularExpression) != nil
        }
    }

    private func mightBeOwnAccountMovement(_ description: String) -> Bool {
        description.range(of: "STP", options: .caseInsensitive) != nil
            || description.range(of: "BANAMEX", options: .caseInsensitive) != nil
            || description.range(of: "CUENTA", options: .caseInsensitive) != nil
    }
}
