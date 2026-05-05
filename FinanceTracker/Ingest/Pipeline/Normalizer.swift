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
            isTransfer: raw.isTransfer
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
