import Foundation

enum DashboardCashFlowMovement: Equatable {
    case inflow
    case outflow
}

enum DashboardCashFlowClassifier {
    static func matchedCardPaymentTransactionIDs(in transactions: [Transaction]) -> Set<UUID> {
        var groups: [UUID: [Transaction]] = [:]
        for transaction in transactions {
            guard let groupID = transaction.transferGroupID else { continue }
            groups[groupID, default: []].append(transaction)
        }

        return groups.values.reduce(into: Set<UUID>()) { result, group in
            let members = group.filter { $0.deletedAt == nil && !$0.isDuplicate }
            let hasCardReceipt = members.contains {
                $0.account?.type == .creditCard && $0.amount > 0
            }
            let hasBankOutflow = members.contains {
                $0.account?.type.isLiability != true && $0.amount < 0
            }
            if hasCardReceipt && hasBankOutflow {
                result.formUnion(members.map(\.id))
            }
        }
    }

    static func movement(
        for transaction: Transaction,
        classification: TransactionClassification? = nil,
        matchedCardPaymentIDs: Set<UUID> = []
    ) -> DashboardCashFlowMovement? {
        guard transaction.deletedAt == nil,
              !transaction.isDuplicate,
              let account = transaction.account,
              account.type.isLiability == false,
              account.effectiveIncludeInCashFlow else { return nil }

        if isCardPaymentOutflow(transaction, matchedCardPaymentIDs: matchedCardPaymentIDs) {
            return .outflow
        }

        let resolvedClassification = classification ?? TransactionClassifier().classify(transaction: transaction)
        if resolvedClassification.countsAsRegularIncome { return .inflow }
        if resolvedClassification.countsAsRegularExpense { return .outflow }
        return nil
    }

    static func isCardPaymentOutflow(
        _ transaction: Transaction,
        matchedCardPaymentIDs: Set<UUID> = []
    ) -> Bool {
        transaction.deletedAt == nil
            && !transaction.isDuplicate
            && transaction.amount < 0
            && transaction.account?.type.isLiability == false
            && transaction.account?.effectiveIncludeInCashFlow == true
            && (transaction.category?.kind == .creditCardPayment
                || transaction.flowKind == .payment
                || matchedCardPaymentIDs.contains(transaction.id))
    }

    static func isCardPaymentReceipt(
        _ transaction: Transaction,
        matchedCardPaymentIDs: Set<UUID> = []
    ) -> Bool {
        transaction.deletedAt == nil
            && !transaction.isDuplicate
            && transaction.amount > 0
            && transaction.account?.type == .creditCard
            && (transaction.category?.kind == .creditCardPayment
                || transaction.flowKind == .payment
                || matchedCardPaymentIDs.contains(transaction.id))
    }
}
