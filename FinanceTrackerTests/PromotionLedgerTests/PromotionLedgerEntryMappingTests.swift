
import Foundation
import Testing
import SwiftData
@testable import FinanceTracker

@Suite("Mapeo SwiftData → PromotionLedgerEntry")
struct PromotionLedgerEntryMappingTests {
    private static func makeTransaction(amount: Decimal, currency: String,
                                        deleted: Bool) -> Transaction {
        let account = Account(institution: "Test Bank", type: .creditCard,
                              currency: currency, nickname: "Card")
        let tx = Transaction(account: account,
                             postedAt: Date(timeIntervalSince1970: 1_700_000_000),
                             amount: amount, currency: currency,
                             descriptionRaw: "Compra de prueba")
        if deleted { tx.deletedAt = Date(timeIntervalSince1970: 1_700_000_100) }
        return tx
    }

    @Test("El mapeo preserva identidad, monto, moneda, fecha, borrado y descripción")
    func mappingPreservesFields() {
        let live = Self.makeTransaction(amount: -1_250_50, currency: "MXN", deleted: false)
        let deleted = Self.makeTransaction(amount: -99, currency: "USD", deleted: true)
        let entries = PromotionLedgerViewModel.entries(from: [live, deleted])
        #expect(entries.count == 2)
        #expect(entries[0].id == live.id)
        #expect(entries[0].amount == -1_250_50)
        #expect(entries[0].currency == "MXN")
        #expect(entries[0].postedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(entries[0].deletedAt == nil)
        #expect(entries[0].description == "Compra de prueba")
        #expect(entries[1].deletedAt != nil)
    }
}


extension PromotionLedgerEntryMappingTests {
    @Test @MainActor func fetchFailureDoesNotProduceZeroProgress() throws {
        let container = try ModelContainer(for: Account.self, Transaction.self,
                                         configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let model = PromotionLedgerViewModel()
        let ledgerURL = FileManager.default.temporaryDirectory.appendingPathComponent("empty-\(UUID()).json")
        model.reload(context: container.mainContext, ledgerURL: ledgerURL,
                     fetchEntries: { throw CocoaError(.fileReadUnknown) })
        #expect(model.loadError != nil)
        #expect(model.entries.isEmpty)
    }
}
