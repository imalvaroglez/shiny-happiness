import Foundation

// MARK: - Modelo del ledger

/// Promoción creada por el usuario. La cuenta es un ancla organizativa (dónde
/// se muestra la card), no una dependencia dura; la moneda sí es una regla:
/// solo pueden adjudicársele transacciones de esa moneda.
struct PromotionRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var accountID: UUID
    var currency: String
    var windowStart: Date?
    var windowEnd: Date?
    var targetAmount: Decimal?
    var rewardNote: String?
    var notes: String?
    /// Oculta la promo de las cards conservando historial; reactivable.
    var archivedAt: Date?
    var createdAt: Date
    var updatedAt: Date
    /// Tombstone para merge; distinto de `archivedAt`.
    var deletedAt: Date?
}

/// Adjudicación manual de una transacción a una promoción. Llave natural
/// `(promotionID, transactionID)`; adjudicar dos veces es un upsert.
struct PromotionAttribution: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var promotionID: UUID
    var transactionID: UUID
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
}

/// El ledger completo persistido como JSON en Application Support.
struct PromotionLedger: Codable, Equatable, Sendable {
    var schemaVersion: Int = 1
    var updatedAt = Date.distantPast
    var promotions: [PromotionRecord] = []
    var attributions: [PromotionAttribution] = []
}

// MARK: - Evaluación pura

/// Vista ligera de una transacción para evaluación sin SwiftData: el avance se
/// calcula en vivo desde las transacciones reales, así que editar un monto o
/// restaurar una fila soft-deleted se refleja sin regrabar el ledger.
struct PromotionLedgerEntry: Equatable, Sendable {
    let id: UUID
    let amount: Decimal
    let currency: String
    let postedAt: Date
    let deletedAt: Date?
}

struct PromotionProgressSummary: Equatable, Sendable {
    let advance: Decimal
    let attributedCount: Int
    let outOfWindowCount: Int
    let orphanCount: Int
    let window: PromotionWindowState
}

enum PromotionAccumulator {
    /// `avance = −Σ tx.amount` sobre adjudicaciones activas con transacción
    /// viva (`deletedAt == nil`) de la moneda de la promo. Las adjudicaciones
    /// huérfanas (transacción inexistente) no aportan pero se cuentan. La
    /// ventana nunca filtra: marca, no bloquea.
    static func progress(promotion: PromotionRecord,
                         attributions: [PromotionAttribution],
                         transactions: [PromotionLedgerEntry],
                         asOf: Date,
                         calendar: Calendar = .current) -> PromotionProgressSummary {
        let window = PromotionWindowCalculator.state(windowStart: promotion.windowStart,
                                                     windowEnd: promotion.windowEnd,
                                                     asOf: asOf, calendar: calendar)
        let entriesByID = Dictionary(transactions.map { ($0.id, $0) },
                                     uniquingKeysWith: { first, _ in first })
        let startDay = promotion.windowStart.map { calendar.startOfDay(for: $0) }
        let endDayExclusive = promotion.windowEnd.map {
            calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: $0))!
        }

        var advance: Decimal = 0
        var attributedCount = 0
        var outOfWindowCount = 0
        var orphanCount = 0

        for attribution in attributions
        where attribution.promotionID == promotion.id && attribution.deletedAt == nil {
            guard let entry = entriesByID[attribution.transactionID] else {
                orphanCount += 1
                continue
            }
            guard entry.deletedAt == nil, entry.currency == promotion.currency else { continue }
            advance -= entry.amount
            attributedCount += 1
            let postedDay = calendar.startOfDay(for: entry.postedAt)
            if let startDay, postedDay < startDay {
                outOfWindowCount += 1
            } else if let endDayExclusive, postedDay >= endDayExclusive {
                outOfWindowCount += 1
            }
        }

        return PromotionProgressSummary(advance: advance,
                                        attributedCount: attributedCount,
                                        outOfWindowCount: outOfWindowCount,
                                        orphanCount: orphanCount,
                                        window: window)
    }
}

// MARK: - Ventana

/// Estado de la ventana promocional evaluado en días civiles de calendario local
/// (`startOfDay`), con límites inclusivos: el día de inicio es «día 1» y el día
/// de fin sigue contando como dentro de la ventana.
enum PromotionWindowState: Equatable, Sendable {
    case none
    case before(start: Date, daysUntilStart: Int)
    case during(dayNumber: Int?, totalDays: Int?, daysRemaining: Int?)
    case after(end: Date, daysSinceEnd: Int)
}

enum PromotionWindowCalculator {
    static func state(windowStart: Date?, windowEnd: Date?, asOf: Date,
                      calendar: Calendar = .current) -> PromotionWindowState {
        guard windowStart != nil || windowEnd != nil else { return .none }
        let startDay = windowStart.map { calendar.startOfDay(for: $0) }
        let endDay = windowEnd.map { calendar.startOfDay(for: $0) }
        let asOfDay = calendar.startOfDay(for: asOf)

        func civilDays(from earlier: Date, to later: Date) -> Int {
            calendar.dateComponents([.day], from: earlier, to: later).day ?? 0
        }

        if let startDay, asOfDay < startDay {
            return .before(start: startDay, daysUntilStart: civilDays(from: asOfDay, to: startDay))
        }
        if let endDay, asOfDay > endDay {
            return .after(end: endDay, daysSinceEnd: civilDays(from: endDay, to: asOfDay))
        }
        let dayNumber = startDay.map { civilDays(from: $0, to: asOfDay) + 1 }
        let totalDays: Int?
        if let startDay, let endDay {
            totalDays = civilDays(from: startDay, to: endDay) + 1
        } else {
            totalDays = nil
        }
        let daysRemaining = endDay.map { civilDays(from: asOfDay, to: $0) + 1 }
        return .during(dayNumber: dayNumber, totalDays: totalDays, daysRemaining: daysRemaining)
    }
}
