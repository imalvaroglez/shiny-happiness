import Testing
import Foundation
@testable import FinanceTracker

@Suite("Normalizer")
@MainActor
struct NormalizerTests {

    @Test("Normalizes single RawTransaction to Transaction with relationships")
    func normalizesSingle() {
        let account = Account(institution: "Test Bank", type: .checking)
        let statement = Statement(
            account: account,
            periodStart: Date(),
            periodEnd: Date(),
            sourceFileHash: "abc123"
        )

        let raw = RawTransaction(
            postedAt: Date(),
            amount: Decimal(1500.50),
            currency: "MXN",
            descriptionRaw: "UBER TRIP 123",
            merchantNormalized: "Uber",
            isTransfer: false
        )

        let tx = Normalizer.normalize(raw, account: account, statement: statement)

        #expect(tx.account === account)
        #expect(tx.statement === statement)
        #expect(tx.amount == Decimal(1500.50))
        #expect(tx.currency == "MXN")
        #expect(tx.descriptionRaw == "UBER TRIP 123")
        #expect(tx.merchantNormalized == "Uber")
        #expect(tx.isTransfer == false)
        #expect(tx.isDuplicate == false)
        #expect(tx.fxRateToBase == 1)
        #expect(tx.expenseAssignment == .user)
        #expect(tx.expenseAssignmentRaw == nil)
        #expect(tx.householdScope == .excluded, "New imports default to excluded from Household Settlement")
        #expect(tx.householdScopeRaw == "excluded")
    }

    @Test("Normalizes multiple RawTransactions")
    func normalizesMultiple() {
        let account = Account(institution: "Test Bank", type: .checking)
        let statement = Statement(
            account: account,
            periodStart: Date(),
            periodEnd: Date(),
            sourceFileHash: "abc123"
        )

        let raws = [
            RawTransaction(postedAt: Date(), amount: -500, descriptionRaw: "OXXO"),
            RawTransaction(postedAt: Date(), amount: 25000, descriptionRaw: "Nomina", isTransfer: true),
        ]

        let transactions = Normalizer.normalizeAll(raws, account: account, statement: statement)

        #expect(transactions.count == 2)
        #expect(transactions[0].amount == -500)
        #expect(transactions[0].expenseAssignment == .user)
        #expect(HouseholdSettlementReportService.isSettlementEligible(transactions[0]))
        #expect(transactions[1].amount == 25000)
        #expect(transactions[1].isTransfer == true)
        #expect(!HouseholdSettlementReportService.isSettlementEligible(transactions[1]))
        for tx in transactions {
            #expect(tx.account === account)
            #expect(tx.statement === statement)
        }
    }
}
