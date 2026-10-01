import Foundation
import Testing
@testable import FinanceTracker

@Suite("AttributionSaver (protocolo de dos almacenes)")
struct AttributionSaverTests {
    private let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("AttributionSaverTests-\(UUID().uuidString).json")

    private func date(_ value: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = MexicoBankingCalendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.date(from: value)!
    }

    private func record(id: UUID, currency: String, updatedAt: Date) -> PromotionRecord {
        PromotionRecord(id: id, name: "Promo \(currency)", accountID: UUID(), currency: currency,
                        windowStart: nil, windowEnd: nil, targetAmount: nil, rewardNote: nil,
                        notes: nil, archivedAt: nil, createdAt: updatedAt, updatedAt: updatedAt,
                        deletedAt: nil)
    }

    @Test("apply adjudica tras la tx y filtra defensivamente por moneda (PA-05)")
    func applyFiltersByCurrency() throws {
        let mxn = UUID(), usd = UUID()
        var ledger = PromotionLedger()
        ledger.promotions = [record(id: mxn, currency: "MXN", updatedAt: date("2026-09-09T00:00:00")),
                             record(id: usd, currency: "USD", updatedAt: date("2026-09-09T00:00:00"))]
        try PromotionLedgerStore.replace(with: ledger, at: url)
        let transactionID = UUID()

        let outcome = AttributionSaver.apply(transactionID: transactionID, currency: "MXN",
                                             selectedPromotionIDs: [mxn, usd],
                                             ledger: ledger, storeURL: url)
        #expect(outcome.appliedPromotionIDs == [mxn])
        #expect(outcome.failedPromotionIDs.isEmpty)

        let stored = try PromotionLedgerStore.read(fileURL: url)
        #expect(stored.attributions.count == 1)
        #expect(stored.attributions[0].promotionID == mxn)
    }

    @Test("Fallo del ledger tras guardar la tx: falla visible y la tx queda intacta")
    func ledgerFailureIsVisibleAndAtomic() throws {
        let mxn = UUID()
        var ledger = PromotionLedger()
        ledger.promotions = [record(id: mxn, currency: "MXN", updatedAt: date("2026-09-09T00:00:00"))]

        // Ruta rota: un DIRECTORIO en el lugar del archivo hace fallar la escritura.
        let brokenURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttributionSaverTests-broken-\(UUID().uuidString).json")
        try FileManager.default.createDirectory(at: brokenURL, withIntermediateDirectories: true)
        let transactionID = UUID()

        let outcome = AttributionSaver.apply(transactionID: transactionID, currency: "MXN",
                                             selectedPromotionIDs: [mxn],
                                             ledger: ledger, storeURL: brokenURL)
        #expect(outcome.failedPromotionIDs == [mxn])

        // Reintentar contra la misma ruta rota sigue fallando (sin crear nada).
        let stillFailed = AttributionSaver.retry(transactionID: transactionID,
                                                 failedPromotionIDs: [mxn], storeURL: brokenURL)
        #expect(stillFailed == [mxn])

        // Reparar la ruta y reintentar: el upsert crea EXACTAMENTE una fila —
        // la tx nunca se duplica porque el reintento solo toca el ledger.
        try FileManager.default.removeItem(at: brokenURL)
        try PromotionLedgerStore.replace(with: ledger, at: brokenURL)
        let remaining = AttributionSaver.retry(transactionID: transactionID,
                                               failedPromotionIDs: [mxn], storeURL: brokenURL)
        #expect(remaining.isEmpty)
        let stored = try PromotionLedgerStore.read(fileURL: brokenURL)
        #expect(stored.attributions.count == 1)
        #expect(stored.attributions[0].deletedAt == nil)
    }

    @Test("retry sobre adjudicaciones ya aplicadas es idempotente")
    func retryIsIdempotent() throws {
        let mxn = UUID()
        var ledger = PromotionLedger()
        ledger.promotions = [record(id: mxn, currency: "MXN", updatedAt: date("2026-09-09T00:00:00"))]
        try PromotionLedgerStore.replace(with: ledger, at: url)
        let transactionID = UUID()

        _ = AttributionSaver.apply(transactionID: transactionID, currency: "MXN",
                                   selectedPromotionIDs: [mxn], ledger: ledger, storeURL: url)
        let remaining = AttributionSaver.retry(transactionID: transactionID,
                                               failedPromotionIDs: [mxn], storeURL: url)
        #expect(remaining.isEmpty)
        #expect(try PromotionLedgerStore.read(fileURL: url).attributions.count == 1)
    }
}
