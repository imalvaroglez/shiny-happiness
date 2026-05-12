import Foundation

struct ParsedSection {
    let accountHint: String?
    let accountType: AccountType?
    let accountNumber: String?
    let nickname: String?
    let openingBalance: Decimal?
    let closingBalance: Decimal?
    let transactions: [RawTransaction]
    let creditLimit: Decimal?
    let minimumPayment: Decimal?
    let paymentForNoInterest: Decimal?
    let paymentDueDate: Date?
    let interestCharged: Decimal?
    let feesCharged: Decimal?
    let ivaCharged: Decimal?

    init(
        accountHint: String?,
        accountType: AccountType?,
        accountNumber: String?,
        nickname: String?,
        openingBalance: Decimal?,
        closingBalance: Decimal?,
        transactions: [RawTransaction],
        creditLimit: Decimal? = nil,
        minimumPayment: Decimal? = nil,
        paymentForNoInterest: Decimal? = nil,
        paymentDueDate: Date? = nil,
        interestCharged: Decimal? = nil,
        feesCharged: Decimal? = nil,
        ivaCharged: Decimal? = nil
    ) {
        self.accountHint = accountHint
        self.accountType = accountType
        self.accountNumber = accountNumber
        self.nickname = nickname
        self.openingBalance = openingBalance
        self.closingBalance = closingBalance
        self.transactions = transactions
        self.creditLimit = creditLimit
        self.minimumPayment = minimumPayment
        self.paymentForNoInterest = paymentForNoInterest
        self.paymentDueDate = paymentDueDate
        self.interestCharged = interestCharged
        self.feesCharged = feesCharged
        self.ivaCharged = ivaCharged
    }

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
