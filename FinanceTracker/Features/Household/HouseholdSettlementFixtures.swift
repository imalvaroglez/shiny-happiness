import Foundation
import SwiftData

enum HouseholdSettlementFixture {
    static let month = YearMonth(year: 2026, month: 6)
    static let expectedRecoverAmount = Decimal(string: "1783.28")!

    static var setup: HouseholdSettlementSetup {
        HouseholdSettlementSetup(partnerIncomeEstimate: 9_000)
    }

    @MainActor
    static func report(setup: HouseholdSettlementSetup = HouseholdSettlementFixture.setup) -> HouseholdSettlementReport {
        HouseholdSettlementReportService.build(
            monthStart: month.startDate,
            transactions: transactions(),
            setup: setup
        )
    }

    @MainActor
    static func seed(in context: ModelContext) throws {
        let account = Account(
            institution: "Fixture Bank",
            type: .checking,
            currency: "MXN",
            nickname: "Fixture Checking",
            manuallyCreatedAt: month.startDate
        )
        context.insert(account)

        let salary = Category(name: "Salary", kind: .income)
        let rent = Category(name: "Rent", kind: .expense)
        let maintenance = Category(name: "Maintenance", kind: .expense)
        let internet = Category(name: "Internet", kind: .expense)
        let partner = Category(name: "Partner", kind: .expense)
        let personal = Category(name: "Personal", kind: .expense)
        [salary, rent, maintenance, internet, partner, personal].forEach(context.insert)

        context.insert(transaction(account: account, day: 5, amount: 59_379.31, category: salary))
        context.insert(transaction(account: account, day: 6, amount: -8_000, category: rent, assignment: .shared))
        context.insert(transaction(account: account, day: 7, amount: -1_000, category: maintenance, assignment: .shared))
        context.insert(transaction(account: account, day: 8, amount: -750, category: internet, assignment: .shared))
        context.insert(transaction(account: account, day: 9, amount: -500, category: partner, assignment: .partner))
        context.insert(transaction(account: account, day: 10, amount: -300, category: personal, assignment: .user))
        try HouseholdPartnerIncomeService.upsert(
            month: month.startDate,
            amount: setup.partnerIncomeEstimate,
            notes: nil,
            context: context
        )
    }

    @MainActor
    static func makePreviewContainer() -> ModelContainer {
        do {
            let container = try AppSchema.makeContainer(isStoredInMemoryOnly: true)
            try seed(in: container.mainContext)
            return container
        } catch {
            fatalError("Failed to make Household fixture container: \(error)")
        }
    }

    @MainActor
    private static func transactions() -> [Transaction] {
        let account = Account(
            institution: "Fixture Bank",
            type: .checking,
            currency: "MXN",
            nickname: "Fixture Checking",
            manuallyCreatedAt: month.startDate
        )
        let salary = Category(name: "Salary", kind: .income)
        let rent = Category(name: "Rent", kind: .expense)
        let maintenance = Category(name: "Maintenance", kind: .expense)
        let internet = Category(name: "Internet", kind: .expense)
        let partner = Category(name: "Partner", kind: .expense)
        let personal = Category(name: "Personal", kind: .expense)
        return [
            transaction(account: account, day: 5, amount: 59_379.31, category: salary),
            transaction(account: account, day: 6, amount: -8_000, category: rent, assignment: .shared),
            transaction(account: account, day: 7, amount: -1_000, category: maintenance, assignment: .shared),
            transaction(account: account, day: 8, amount: -750, category: internet, assignment: .shared),
            transaction(account: account, day: 9, amount: -500, category: partner, assignment: .partner),
            transaction(account: account, day: 10, amount: -300, category: personal, assignment: .user),
        ]
    }

    @MainActor
    private static func transaction(
        account: Account,
        day: Int,
        amount: Decimal,
        category: Category,
        assignment: ExpenseAssignment = .user
    ) -> Transaction {
        let postedAt = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 6, day: day))!
        let tx = Transaction(
            account: account,
            postedAt: postedAt,
            amount: amount,
            descriptionRaw: category.name,
            merchantNormalized: category.name,
            category: category
        )
        tx.setExpenseAssignment(assignment)
        return tx
    }
}
