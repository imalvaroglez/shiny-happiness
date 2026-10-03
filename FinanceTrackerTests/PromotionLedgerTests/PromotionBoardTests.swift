import Foundation
import Testing
@testable import FinanceTracker

@Suite("PromotionBoard (consultas puras del ledger para la UI)")
struct PromotionBoardTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = MexicoBankingCalendar.timeZone
        return calendar
    }()

    private let asOf = Self.date("2026-09-30")
    private let platinumAccount = UUID()
    private let goldAccount = UUID()

    private static func date(_ value: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = MexicoBankingCalendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)!
    }

    private func record(id: UUID = UUID(), name: String = "Platinum 90 días", accountID: UUID,
                        currency: String = "MXN", archived: Bool = false,
                        windowStart: Date? = nil, windowEnd: Date? = nil,
                        deleted: Bool = false) -> PromotionRecord {
        PromotionRecord(id: id, name: name, accountID: accountID, currency: currency,
                        windowStart: windowStart, windowEnd: windowEnd, targetAmount: 100_000,
                        rewardNote: nil, notes: nil,
                        archivedAt: archived ? Self.date("2026-09-25") : nil,
                        createdAt: Self.date("2026-09-09"), updatedAt: Self.date("2026-09-09"),
                        deletedAt: deleted ? Self.date("2026-09-26") : nil)
    }

    private func entry(_ id: UUID, amount: Decimal, currency: String = "MXN",
                       postedAt: Date? = nil, deleted: Bool = false) -> PromotionLedgerEntry {
        PromotionLedgerEntry(id: id, amount: amount, currency: currency,
                             postedAt: postedAt ?? asOf, deletedAt: deleted ? asOf : nil)
    }

    private func attribution(_ promotionID: UUID, _ transactionID: UUID,
                             deleted: Bool = false) -> PromotionAttribution {
        PromotionAttribution(id: UUID(), promotionID: promotionID, transactionID: transactionID,
                             createdAt: asOf, updatedAt: asOf, deletedAt: deleted ? asOf : nil)
    }

    @Test("activeSummaries ancla por cuenta, excluye archivadas y eliminadas, y trae el avance")
    func activeSummariesScopedToAccount() {
        let activeID = UUID()
        var ledger = PromotionLedger()
        ledger.promotions = [
            record(id: activeID, accountID: platinumAccount),
            record(name: "Archivada", accountID: platinumAccount, archived: true),
            record(name: "Eliminada", accountID: platinumAccount, deleted: true),
            record(name: "De otra cuenta", accountID: goldAccount),
        ]
        let tx = UUID()
        ledger.attributions = [attribution(activeID, tx)]
        let entries = [entry(tx, amount: -40_000)]

        let summaries = PromotionBoard.activeSummaries(ledger: ledger, anchoredTo: platinumAccount,
                                                       transactions: entries, asOf: asOf,
                                                       calendar: Self.calendar)
        #expect(summaries.count == 1)
        #expect(summaries.first?.record.id == activeID)
        #expect(summaries.first?.progress.advance == 40_000)
    }

    @Test("allSummaries para Settings incluye archivadas y excluye eliminadas")
    func allSummariesIncludeArchived() {
        var ledger = PromotionLedger()
        ledger.promotions = [
            record(accountID: platinumAccount),
            record(name: "Archivada", accountID: goldAccount, archived: true),
            record(name: "Eliminada", accountID: platinumAccount, deleted: true),
        ]
        let summaries = PromotionBoard.allSummaries(ledger: ledger, transactions: [],
                                                    asOf: asOf, calendar: Self.calendar)
        #expect(summaries.count == 2)
        #expect(summaries.contains { $0.record.name == "Archivada" })
    }

    @Test("attributedPromotionIDs devuelve las promos vivas de una tx")
    func attributedPromotionIDs() {
        let first = UUID(), second = UUID(), dead = UUID()
        let tx = UUID()
        var ledger = PromotionLedger()
        ledger.attributions = [
            attribution(first, tx),
            attribution(second, tx),
            attribution(dead, tx, deleted: true),
            attribution(first, UUID()),
        ]
        let ids = PromotionBoard.attributedPromotionIDs(ledger: ledger, transactionID: tx)
        #expect(Set(ids) == Set([first, second]))
    }

    @Test("selectablePromotions filtra por moneda, solo activas, ordenadas por nombre")
    func selectablePromotionsByCurrency() {
        var ledger = PromotionLedger()
        ledger.promotions = [
            record(name: "Zafiro", accountID: platinumAccount),
            record(name: "Ametrina", accountID: goldAccount),
            record(name: "Dólares", accountID: platinumAccount, currency: "USD"),
            record(name: "Archivada", accountID: platinumAccount, archived: true),
            record(name: "Eliminada", accountID: platinumAccount, deleted: true),
        ]
        let selectable = PromotionBoard.selectablePromotions(ledger: ledger, currency: "MXN")
        #expect(selectable.map(\.name) == ["Ametrina", "Zafiro"])
    }

    @Test("detailRows lista contribuciones con signo, fuera de ventana, y huérfanas al final")
    func detailRowsComposeContributions() {
        let promoID = UUID()
        let purchase = UUID(), credit = UUID(), ghost = UUID(), erased = UUID()
        var ledger = PromotionLedger()
        ledger.promotions = [record(id: promoID, accountID: platinumAccount,
                                    windowStart: Self.date("2026-09-09"),
                                    windowEnd: Self.date("2026-12-07"))]
        ledger.attributions = [
            attribution(promoID, credit),
            attribution(promoID, ghost),
            attribution(promoID, purchase),
            attribution(promoID, erased),
        ]
        let entries = [
            entry(purchase, amount: -31_674, postedAt: Self.date("2026-09-15")),
            entry(credit, amount: 31_674, postedAt: Self.date("2026-10-01")),
            entry(erased, amount: -500, deleted: true),
        ]

        let rows = PromotionBoard.detailRows(promotionID: promoID, ledger: ledger,
                                             transactions: entries, calendar: Self.calendar)
        #expect(rows.count == 4)
        let byTx = Dictionary(uniqueKeysWithValues: rows.map { ($0.transactionID, $0) })
        #expect(byTx[purchase]?.contribution == 31_674)
        #expect(byTx[purchase]?.isOutOfWindow == false)
        #expect(byTx[credit]?.contribution == -31_674)
        #expect(byTx[ghost]?.contribution == nil)
        #expect(byTx[ghost]?.excludedReason == "sin transacción")
        #expect(byTx[erased]?.contribution == nil)
        #expect(byTx[erased]?.excludedReason == "transacción eliminada")
        // La huérfana va al final; las contribuciones primero, por fecha descendente.
        #expect(rows.last?.transactionID == ghost)
        #expect(rows.first?.transactionID == credit)
    }

    @Test("detailRows marca compras fuera de ventana sin excluirlas")
    func detailRowsFlagOutOfWindow() {
        let promoID = UUID()
        let early = UUID()
        var ledger = PromotionLedger()
        ledger.promotions = [record(id: promoID, accountID: platinumAccount,
                                    windowStart: Self.date("2026-09-09"),
                                    windowEnd: Self.date("2026-12-07"))]
        ledger.attributions = [attribution(promoID, early)]
        let entries = [entry(early, amount: -100, postedAt: Self.date("2026-09-01"))]

        let rows = PromotionBoard.detailRows(promotionID: promoID, ledger: ledger,
                                             transactions: entries, calendar: Self.calendar)
        #expect(rows.first?.contribution == 100)
        #expect(rows.first?.isOutOfWindow == true)
    }
}
