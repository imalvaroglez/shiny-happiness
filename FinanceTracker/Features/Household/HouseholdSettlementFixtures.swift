import Foundation
import SwiftData

enum HouseholdSettlementFixture {
    static let month = YearMonth(year: 2026, month: 6)
    static let expectedRecoverAmount = Decimal(string: "3249.95")!

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
        let furniture = Category(name: "Furniture", kind: .expense)
        let mixed = Category(name: "Mixed Purchase", kind: .expense)
        [salary, rent, maintenance, internet, partner, personal, furniture, mixed].forEach(context.insert)

        context.insert(transaction(account: account, day: 5, amount: 59_379.31, category: salary))
        context.insert(transaction(account: account, day: 6, amount: -8_000, category: rent, assignment: .shared, scope: .included))
        context.insert(transaction(account: account, day: 7, amount: -1_000, category: maintenance, assignment: .shared, scope: .included))
        context.insert(transaction(account: account, day: 8, amount: -750, category: internet, assignment: .shared, scope: .included))
        context.insert(transaction(account: account, day: 9, amount: -500, category: partner, assignment: .partner, scope: .included))
        context.insert(transaction(account: account, day: 10, amount: -300, category: personal, assignment: .user, scope: .excluded))
        context.insert(transaction(account: account, day: 12, amount: -900, category: furniture, assignment: .user, scope: .included))
        context.insert(transaction(
            account: account,
            day: 11,
            amount: -2_200,
            category: mixed,
            assignment: .custom,
            customFerAmount: Decimal(string: "1466.67")!,
            scope: .included
        ))
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
        let furniture = Category(name: "Furniture", kind: .expense)
        let mixed = Category(name: "Mixed Purchase", kind: .expense)
        return [
            transaction(account: account, day: 5, amount: 59_379.31, category: salary),
            transaction(account: account, day: 6, amount: -8_000, category: rent, assignment: .shared, scope: .included),
            transaction(account: account, day: 7, amount: -1_000, category: maintenance, assignment: .shared, scope: .included),
            transaction(account: account, day: 8, amount: -750, category: internet, assignment: .shared, scope: .included),
            transaction(account: account, day: 9, amount: -500, category: partner, assignment: .partner, scope: .included),
            transaction(account: account, day: 10, amount: -300, category: personal, assignment: .user, scope: .excluded),
            transaction(account: account, day: 12, amount: -900, category: furniture, assignment: .user, scope: .included),
            transaction(
                account: account,
                day: 11,
                amount: -2_200,
                category: mixed,
                assignment: .custom,
                customFerAmount: Decimal(string: "1466.67")!,
                scope: .included
            ),
        ]
    }

    @MainActor
    private static func transaction(
        account: Account,
        day: Int,
        amount: Decimal,
        category: Category,
        assignment: ExpenseAssignment = .user,
        customFerAmount: Decimal? = nil,
        scope: HouseholdScope = .excluded
    ) -> Transaction {
        let postedAt = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 6, day: day))!
        let tx = Transaction(
            account: account,
            postedAt: postedAt,
            amount: amount,
            descriptionRaw: category.name,
            merchantNormalized: category.name,
            category: category,
            householdScopeRaw: scope.rawValue
        )
        if scope == .included {
            if let customFerAmount {
                try! tx.setCustomFerAmount(customFerAmount)
            } else {
                tx.setExpenseAssignment(assignment)
            }
        }
        return tx
    }
}
