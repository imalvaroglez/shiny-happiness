import Foundation
import Testing
@testable import FinanceTracker

@Suite("Acumulador de promoción (avance = −Σ tx.amount, en vivo)")
struct PromotionAccumulatorTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = MexicoBankingCalendar.timeZone
        return calendar
    }()

    private let asOf = Self.date("2026-09-30")

    private let promotionID = UUID()

    private static func date(_ value: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = MexicoBankingCalendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)!
    }

    private func promo(currency: String = "MXN",
                       windowStart: Date? = nil, windowEnd: Date? = nil) -> PromotionRecord {
        PromotionRecord(id: promotionID, name: "Platinum 90 días", accountID: UUID(),
                        currency: currency, windowStart: windowStart, windowEnd: windowEnd,
                        targetAmount: 100_000, rewardNote: nil, notes: nil, archivedAt: nil,
                        createdAt: Self.date("2026-09-09"), updatedAt: Self.date("2026-09-09"),
                        deletedAt: nil)
    }

    private func attribution(transactionID: UUID, deletedAt: Date? = nil) -> PromotionAttribution {
        PromotionAttribution(id: UUID(), promotionID: promotionID, transactionID: transactionID,
                             createdAt: asOf, updatedAt: asOf, deletedAt: deletedAt)
    }

    private func entry(id: UUID, amount: Decimal, currency: String = "MXN",
                       postedAt: Date? = nil, deletedAt: Date? = nil) -> PromotionLedgerEntry {
        PromotionLedgerEntry(id: id, amount: amount, currency: currency,
                             postedAt: postedAt ?? asOf, deletedAt: deletedAt)
    }

    @Test("Un cargo negativo avanza el contador completo")
    func chargeAdvances() {
        let tx = UUID()
        let summary = PromotionAccumulator.progress(
            promotion: promo(), attributions: [attribution(transactionID: tx)],
            transactions: [entry(id: tx, amount: -1_000)], asOf: asOf, calendar: Self.calendar)
        #expect(summary.advance == 1_000)
        #expect(summary.attributedCount == 1)
    }

    @Test("Un crédito positivo resta del avance")
    func creditSubtracts() {
        let tx = UUID()
        let summary = PromotionAccumulator.progress(
            promotion: promo(), attributions: [attribution(transactionID: tx)],
            transactions: [entry(id: tx, amount: 200)], asOf: asOf, calendar: Self.calendar)
        #expect(summary.advance == -200)
        #expect(summary.attributedCount == 1)
    }

    @Test("Caso canónico: compra −1,000 con devolución +200 avanza 800")
    func canonicalMixedPair() {
        let purchase = UUID()
        let refund = UUID()
        let summary = PromotionAccumulator.progress(
            promotion: promo(),
            attributions: [attribution(transactionID: purchase), attribution(transactionID: refund)],
            transactions: [entry(id: purchase, amount: -1_000), entry(id: refund, amount: 200)],
            asOf: asOf, calendar: Self.calendar)
        #expect(summary.advance == 800)
        #expect(summary.attributedCount == 2)
    }

    @Test("Una transacción soft-deleted queda fuera del avance")
    func softDeletedExcluded() {
        let tx = UUID()
        let summary = PromotionAccumulator.progress(
            promotion: promo(), attributions: [attribution(transactionID: tx)],
            transactions: [entry(id: tx, amount: -1_000, deletedAt: asOf)],
            asOf: asOf, calendar: Self.calendar)
        #expect(summary.advance == 0)
        #expect(summary.attributedCount == 0)
    }

    @Test("La misma tx adjudicada a dos promos avanza a cada una por completo")
    func multiPromotionIndependence() {
        let tx = UUID()
        let otherID = UUID()
        let other = PromotionRecord(id: otherID, name: "Gold Everyday", accountID: UUID(),
                                    currency: "MXN", windowStart: nil, windowEnd: nil,
                                    targetAmount: nil, rewardNote: nil, notes: nil, archivedAt: nil,
                                    createdAt: asOf, updatedAt: asOf, deletedAt: nil)
        let entries = [entry(id: tx, amount: -3_000)]
        let first = PromotionAccumulator.progress(
            promotion: promo(), attributions: [attribution(transactionID: tx)],
            transactions: entries, asOf: asOf, calendar: Self.calendar)
        let second = PromotionAccumulator.progress(
            promotion: other,
            attributions: [PromotionAttribution(id: UUID(), promotionID: otherID,
                                                transactionID: tx, createdAt: asOf,
                                                updatedAt: asOf, deletedAt: nil)],
            transactions: entries, asOf: asOf, calendar: Self.calendar)
        #expect(first.advance == 3_000)
        #expect(second.advance == 3_000)
    }

    @Test("Una tx de otra moneda no suma ni marca huérfana (defensa en profundidad)")
    func currencyMismatchIgnored() {
        let tx = UUID()
        let summary = PromotionAccumulator.progress(
            promotion: promo(), attributions: [attribution(transactionID: tx)],
            transactions: [entry(id: tx, amount: -50, currency: "USD")],
            asOf: asOf, calendar: Self.calendar)
        #expect(summary.advance == 0)
        #expect(summary.attributedCount == 0)
        #expect(summary.orphanCount == 0)
    }

    @Test("Una adjudicación sin transacción es huérfana visible que no aporta")
    func orphanVisibleWithoutContribution() {
        let ghost = UUID()
        let real = UUID()
        let summary = PromotionAccumulator.progress(
            promotion: promo(),
            attributions: [attribution(transactionID: ghost), attribution(transactionID: real)],
            transactions: [entry(id: real, amount: -500)],
            asOf: asOf, calendar: Self.calendar)
        #expect(summary.advance == 500)
        #expect(summary.attributedCount == 1)
        #expect(summary.orphanCount == 1)
    }

    @Test("Adjudicaciones fuera de ventana cuentan y se marcan")
    func outOfWindowCountsAndFlags() {
        let early = UUID()
        let inWindow = UUID()
        let late = UUID()
        let summary = PromotionAccumulator.progress(
            promotion: promo(windowStart: Self.date("2026-09-09"), windowEnd: Self.date("2026-12-07")),
            attributions: [attribution(transactionID: early), attribution(transactionID: inWindow),
                           attribution(transactionID: late)],
            transactions: [entry(id: early, amount: -100, postedAt: Self.date("2026-09-01")),
                           entry(id: inWindow, amount: -200, postedAt: Self.date("2026-10-15")),
                           entry(id: late, amount: -300, postedAt: Self.date("2026-12-31"))],
            asOf: asOf, calendar: Self.calendar)
        #expect(summary.advance == 600)
        #expect(summary.attributedCount == 3)
        #expect(summary.outOfWindowCount == 2)
    }

    @Test("Una adjudicación con tombstone se ignora por completo")
    func tombstonedAttributionIgnored() {
        let tx = UUID()
        let summary = PromotionAccumulator.progress(
            promotion: promo(), attributions: [attribution(transactionID: tx, deletedAt: asOf)],
            transactions: [entry(id: tx, amount: -1_000)],
            asOf: asOf, calendar: Self.calendar)
        #expect(summary.advance == 0)
        #expect(summary.attributedCount == 0)
        #expect(summary.orphanCount == 0)
    }

    @Test("Sin adjudicaciones el avance es cero y la ventana se reporta igual")
    func emptyLedger() {
        let summary = PromotionAccumulator.progress(
            promotion: promo(windowStart: Self.date("2026-09-09"), windowEnd: Self.date("2026-12-07")),
            attributions: [], transactions: [], asOf: asOf, calendar: Self.calendar)
        #expect(summary.advance == 0)
        #expect(summary.attributedCount == 0)
        #expect(summary.orphanCount == 0)
        #expect(summary.window == .during(dayNumber: 22, totalDays: 90, daysRemaining: 69))
    }
}
