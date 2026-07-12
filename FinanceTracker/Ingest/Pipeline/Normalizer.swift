import Foundation

struct Normalizer {
    static func normalize(_ raw: RawTransaction, account: Account, statement: Statement) -> Transaction {
        Transaction(
            account: account,
            statement: statement,
            postedAt: raw.postedAt,
            amount: raw.amount,
            currency: raw.currency,
            descriptionRaw: raw.descriptionRaw,
            merchantNormalized: raw.merchantNormalized,
            fxRateToBase: raw.fxRateToBase,
            isTransfer: raw.isTransfer,
            cardLast4: raw.cardLast4,
            movementKindRaw: Transaction.movementKind(
                from: raw.isTransfer ? .transfer : (raw.amount >= 0 ? .income : .expense),
                amount: raw.amount,
                isTransfer: raw.isTransfer
            ).rawValue,
            treatmentKindRaw: TransactionTreatmentKind.regular.rawValue,
            householdScopeRaw: HouseholdScope.excluded.rawValue
        )
    }

    static func normalizeAll(
        _ raws: [RawTransaction],
        account: Account,
        statement: Statement
    ) -> [Transaction] {
        raws.map { normalize($0, account: account, statement: statement) }
    }
}
