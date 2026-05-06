import Foundation

struct ParsedSection {
    let accountHint: String?
    let accountType: AccountType?
    let accountNumber: String?
    let nickname: String?
    let openingBalance: Decimal?
    let closingBalance: Decimal?
    let transactions: [RawTransaction]

    static func single(_ transactions: [RawTransaction]) -> ParsedSection {
        ParsedSection(
            accountHint: nil,
            accountType: nil,
            accountNumber: nil,
            nickname: nil,
            openingBalance: nil,
            closingBalance: nil,
            transactions: transactions
        )
    }
}
