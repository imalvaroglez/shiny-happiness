import Testing
import Foundation
@testable import FinanceTracker

@Suite("Deduplicator")
struct DeduplicatorTests {

    private func makeTransaction(
        amount: Decimal,
        date: Date,
        description: String
    ) -> Transaction {
        Transaction(
            postedAt: date,
            amount: amount,
            descriptionRaw: description
        )
    }

    @Test("Returns all transactions as unique when no existing")
    func noDuplicatesWhenEmpty() {
        let incoming = [
            makeTransaction(amount: 100, date: Date(), description: "OXXO"),
            makeTransaction(amount: -50, date: Date(), description: "Uber"),
        ]

        let result = Deduplicator.deduplicate(incoming: incoming, existing: [])

        #expect(result.unique.count == 2)
        #expect(result.duplicates.isEmpty)
    }

    @Test("Detects exact duplicate by amount, date, and description")
    func detectsExactDuplicate() {
        let now = Date()
        let existing = [makeTransaction(amount: 100, date: now, description: "OXXO COMPRAS")]
        let incoming = [makeTransaction(amount: 100, date: now, description: "OXXO COMPRAS")]

        let result = Deduplicator.deduplicate(incoming: incoming, existing: existing)

        #expect(result.unique.isEmpty)
        #expect(result.duplicates.count == 1)
        #expect(result.duplicates[0].isDuplicate == true)
    }

    @Test("Does not mark as duplicate when amount differs")
    func differentAmountNotDuplicate() {
        let now = Date()
        let existing = [makeTransaction(amount: 100, date: now, description: "OXXO")]
        let incoming = [makeTransaction(amount: 200, date: now, description: "OXXO")]

        let result = Deduplicator.deduplicate(incoming: incoming, existing: existing)

        #expect(result.unique.count == 1)
        #expect(result.duplicates.isEmpty)
    }

    @Test("Detects duplicate with similar description (substring match)")
    func detectsSubstringDuplicate() {
        let now = Date()
        let existing = [makeTransaction(amount: -150, date: now, description: "UBER *TRIP 12345 CDMX")]
        let incoming = [makeTransaction(amount: -150, date: now, description: "UBER *TRIP 12345")]

        let result = Deduplicator.deduplicate(incoming: incoming, existing: existing)

        #expect(result.duplicates.count == 1)
        #expect(result.unique.isEmpty)
    }

    @Test("Does not mark as duplicate when date is more than 1 day apart")
    func differentDayNotDuplicate() {
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -2, to: now)!

        let existing = [makeTransaction(amount: 100, date: yesterday, description: "OXXO")]
        let incoming = [makeTransaction(amount: 100, date: now, description: "OXXO")]

        let result = Deduplicator.deduplicate(incoming: incoming, existing: existing)

        #expect(result.unique.count == 1)
    }

    @Test("Handles mixed duplicates and unique transactions")
    func mixedDuplicatesAndUnique() {
        let now = Date()

        let existing = [
            makeTransaction(amount: -100, date: now, description: "Starbucks Cafe"),
            makeTransaction(amount: -200, date: now, description: "Netflix"),
        ]

        let incoming = [
            makeTransaction(amount: -100, date: now, description: "Starbucks Cafe"),
            makeTransaction(amount: -350, date: now, description: "Superama"),
        ]

        let result = Deduplicator.deduplicate(incoming: incoming, existing: existing)

        #expect(result.duplicates.count == 1)
        #expect(result.unique.count == 1)
        #expect(result.unique[0].descriptionRaw == "Superama")
    }
}
