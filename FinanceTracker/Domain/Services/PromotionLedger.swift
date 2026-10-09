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
    var description = ""

    init(id: UUID, amount: Decimal, currency: String, postedAt: Date, deletedAt: Date?, description: String = "") {
        self.id = id
        self.amount = amount
        self.currency = currency
        self.postedAt = postedAt
        self.deletedAt = deletedAt
        self.description = description
    }
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

// MARK: - Consultas puras para la UI

/// Promo activa con su avance calculado, para cards y listas.
struct ManualPromotionSummary: Identifiable, Equatable, Sendable {
    let record: PromotionRecord
    let progress: PromotionProgressSummary
    var id: UUID { record.id }
}

/// Fila del drill-down: la contribución vive solo si la adjudicación cuenta
/// (transacción presente, viva, de la moneda de la promo).
struct PromotionDetailRow: Identifiable, Equatable, Sendable {
    let attributionID: UUID
    let transactionID: UUID
    let date: Date?
    let description: String
    /// `−tx.amount` cuando aporta; `nil` cuando está excluida.
    let contribution: Decimal?
    let isOutOfWindow: Bool
    let excludedReason: String?
    var id: UUID { attributionID }
}

enum PromotionBoard {
    /// Promos vivas (no archivadas, no eliminadas), opcionalmente ancladas a una cuenta.
    static func activePromotions(in ledger: PromotionLedger, anchoredTo accountID: UUID? = nil) -> [PromotionRecord] {
        ledger.promotions.filter {
            $0.deletedAt == nil && $0.archivedAt == nil
                && (accountID == nil || $0.accountID == accountID)
        }
    }

    static func activeSummaries(ledger: PromotionLedger, anchoredTo accountID: UUID,
                                transactions: [PromotionLedgerEntry], asOf: Date,
                                calendar: Calendar = .current) -> [ManualPromotionSummary] {
        summaries(for: activePromotions(in: ledger, anchoredTo: accountID),
                  ledger: ledger, transactions: transactions, asOf: asOf, calendar: calendar)
    }

    /// Para Settings: incluye archivadas, excluye eliminadas.
    static func allSummaries(ledger: PromotionLedger, transactions: [PromotionLedgerEntry],
                             asOf: Date, calendar: Calendar = .current) -> [ManualPromotionSummary] {
        summaries(for: ledger.promotions.filter { $0.deletedAt == nil },
                  ledger: ledger, transactions: transactions, asOf: asOf, calendar: calendar)
    }

    /// Promos vivas adjudicables a una tx de `currency`, ordenadas por nombre.
    static func selectablePromotions(ledger: PromotionLedger, currency: String) -> [PromotionRecord] {
        activePromotions(in: ledger)
            .filter { $0.currency == currency }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func attributedPromotionIDs(ledger: PromotionLedger, transactionID: UUID) -> [UUID] {
        ledger.attributions
            .filter { $0.transactionID == transactionID && $0.deletedAt == nil }
            .map(\.promotionID)
    }

    /// Filas del drill-down: contribuciones primero (fecha descendente),
    /// luego excluidas con razón, y las referencias ausentes al final.
    static func detailRows(promotionID: UUID, ledger: PromotionLedger,
                           transactions: [PromotionLedgerEntry],
                           calendar: Calendar = .current) -> [PromotionDetailRow] {
        guard let promotion = ledger.promotions.first(where: { $0.id == promotionID }) else { return [] }
        let entriesByID = Dictionary(transactions.map { ($0.id, $0) },
                                     uniquingKeysWith: { first, _ in first })
        let startDay = promotion.windowStart.map { calendar.startOfDay(for: $0) }
        let endDayExclusive = promotion.windowEnd.map {
            calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: $0))!
        }

        var contributions: [PromotionDetailRow] = []
        var excluded: [PromotionDetailRow] = []
        var missing: [PromotionDetailRow] = []

        for attribution in ledger.attributions
        where attribution.promotionID == promotionID && attribution.deletedAt == nil {
            guard let entry = entriesByID[attribution.transactionID] else {
                missing.append(PromotionDetailRow(attributionID: attribution.id,
                                                  transactionID: attribution.transactionID,
                                                  date: nil, description: "",
                                                  contribution: nil, isOutOfWindow: false,
                                                  excludedReason: "sin transacción"))
                continue
            }
            guard entry.deletedAt == nil else {
                excluded.append(PromotionDetailRow(attributionID: attribution.id,
                                                    transactionID: entry.id,
                                                    date: entry.postedAt,
                                                    description: entry.description,
                                                    contribution: nil, isOutOfWindow: false,
                                                    excludedReason: "transacción eliminada"))
                continue
            }
            guard entry.currency == promotion.currency else {
                excluded.append(PromotionDetailRow(attributionID: attribution.id,
                                                    transactionID: entry.id,
                                                    date: entry.postedAt,
                                                    description: entry.description,
                                                    contribution: nil, isOutOfWindow: false,
                                                    excludedReason: "otra moneda"))
                continue
            }
            let postedDay = calendar.startOfDay(for: entry.postedAt)
            var outOfWindow = false
            if let startDay, postedDay < startDay {
                outOfWindow = true
            } else if let endDayExclusive, postedDay >= endDayExclusive {
                outOfWindow = true
            }
            contributions.append(PromotionDetailRow(attributionID: attribution.id,
                                                    transactionID: entry.id,
                                                    date: entry.postedAt,
                                                    description: entry.description,
                                                    contribution: -entry.amount,
                                                    isOutOfWindow: outOfWindow,
                                                    excludedReason: nil))
        }

        return contributions
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            + excluded + missing
    }

    /// IDs de `promotionIDs` cuya ventana civil local no contiene `date`
    /// (PA-07: el aviso informa, nunca filtra).
    static func outOfWindowPromotionIDs(ledger: PromotionLedger, promotionIDs: Set<UUID>,
                                        date: Date, calendar: Calendar) -> Set<UUID> {
        let day = calendar.startOfDay(for: date)
        var out = Set<UUID>()
        for record in ledger.promotions where promotionIDs.contains(record.id) {
            guard record.windowStart != nil || record.windowEnd != nil else { continue }
            let startDay = record.windowStart.map { calendar.startOfDay(for: $0) }
            let endDayExclusive = record.windowEnd.map {
                calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: $0))!
            }
            if let startDay, day < startDay {
                out.insert(record.id)
            } else if let endDayExclusive, day >= endDayExclusive {
                out.insert(record.id)
            }
        }
        return out
    }

    private static func summaries(for promotions: [PromotionRecord], ledger: PromotionLedger,
                                  transactions: [PromotionLedgerEntry], asOf: Date,
                                  calendar: Calendar) -> [ManualPromotionSummary] {
        promotions
            .map { record in
                ManualPromotionSummary(
                    record: record,
                    progress: PromotionAccumulator.progress(promotion: record,
                                                            attributions: ledger.attributions,
                                                            transactions: transactions,
                                                            asOf: asOf, calendar: calendar))
            }
            .sorted { $0.record.name.localizedStandardCompare($1.record.name) == .orderedAscending }
    }
}
