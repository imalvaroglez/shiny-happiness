import Foundation

/// Persistencia del ledger de promociones: un JSON atómico en Application
/// Support (patrón de `SpendRequirementStore`), cero schema SwiftData (AD-023).
///
/// Contrato:
/// - La llave natural `(promotionID, transactionID)` es única; adjudicar es un
///   upsert idempotente y los duplicados cross-id se colapsan al ganador
///   (mayor `updatedAt`, desempate por `id.uuidString`) en lectura y merge.
/// - Eliminar es tombstone (`deletedAt`), nunca borrar la fila, para que el
///   merge sea determinista.
/// - Archivo corrupto o de versión desconocida: error visible, sin reparación
///   silenciosa.
/// - Toda escritura exitosa notifica `didChangeNotification`; la caché y la
///   notificación nunca se emiten si el `.atomic` falla.
enum PromotionLedgerStore {
    static let didChangeNotification = Notification.Name("promotionLedgerDidChange")

    enum StoreError: LocalizedError {
        case invalid([String])

        var errorDescription: String? {
            switch self {
            case .invalid(let issues):
                "Ledger de promociones inválido: \(issues.joined(separator: "; "))."
            }
        }
    }

    // MARK: Lectura

    static func read(fileURL: URL? = nil) throws -> PromotionLedger {
        try readWithDiagnostics(fileURL: fileURL).ledger
    }

    static func readWithDiagnostics(fileURL: URL? = nil) throws -> (ledger: PromotionLedger, diagnostics: [String]) {
        let url = try fileURL ?? defaultURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return (PromotionLedger(), []) }
        let ledger = try JSONDecoder().decode(PromotionLedger.self, from: Data(contentsOf: url))
        guard ledger.schemaVersion == 1 else {
            throw StoreError.invalid(["versión de archivo desconocida (\(ledger.schemaVersion))"])
        }
        return (normalized(ledger), validate(ledger))
    }

    // MARK: Escritura

    static func replace(with ledger: PromotionLedger, at fileURL: URL? = nil, notify: Bool = true) throws {
        guard ledger.schemaVersion == 1 else {
            throw StoreError.invalid(["versión de archivo desconocida (\(ledger.schemaVersion))"])
        }
        try write(normalized(ledger), to: try fileURL ?? defaultURL(), notify: notify)
    }

    static func save(promotion: PromotionRecord, at fileURL: URL? = nil) throws {
        let url = try fileURL ?? defaultURL()
        var ledger = try read(fileURL: url)
        var promotion = promotion
        promotion.updatedAt = PersistedMutationClock.next(after: ledger.promotions.first { $0.id == promotion.id }?.updatedAt,
                                                          now: promotion.updatedAt)
        if let index = ledger.promotions.firstIndex(where: { $0.id == promotion.id }) {
            ledger.promotions[index] = promotion
        } else {
            ledger.promotions.append(promotion)
        }
        ledger.updatedAt = max(ledger.updatedAt, promotion.updatedAt)
        try write(ledger, to: url)
    }

    static func deletePromotion(id: UUID, at fileURL: URL? = nil) throws {
        let url = try fileURL ?? defaultURL()
        var ledger = try read(fileURL: url)
        guard let index = ledger.promotions.firstIndex(where: { $0.id == id }) else { return }
        guard ledger.promotions[index].deletedAt == nil else { return }
        let stamp = PersistedMutationClock.next(after: ledger.promotions[index].updatedAt)
        ledger.promotions[index].deletedAt = stamp
        ledger.promotions[index].updatedAt = stamp
        ledger.updatedAt = max(ledger.updatedAt, stamp)
        try write(ledger, to: url)
    }

    static func attribute(transactionID: UUID, promotionID: UUID, at fileURL: URL? = nil) throws {
        let url = try fileURL ?? defaultURL()
        var ledger = try read(fileURL: url)
        let now = Date.now
        if let index = ledger.attributions.firstIndex(where: {
            $0.promotionID == promotionID && $0.transactionID == transactionID
        }) {
            guard ledger.attributions[index].deletedAt != nil else { return }
            ledger.attributions[index].deletedAt = nil
            ledger.attributions[index].updatedAt = PersistedMutationClock.next(after: ledger.attributions[index].updatedAt, now: now)
        } else {
            ledger.attributions.append(
                PromotionAttribution(id: UUID(), promotionID: promotionID,
                                     transactionID: transactionID, createdAt: now,
                                     updatedAt: now, deletedAt: nil))
        }
        ledger.updatedAt = max(ledger.updatedAt, ledger.attributions.map(\.updatedAt).max() ?? now)
        try write(ledger, to: url)
    }

    static func unattribute(transactionID: UUID, promotionID: UUID, at fileURL: URL? = nil) throws {
        let url = try fileURL ?? defaultURL()
        var ledger = try read(fileURL: url)
        guard let index = ledger.attributions.firstIndex(where: {
            $0.promotionID == promotionID && $0.transactionID == transactionID
        }) else { return }
        guard ledger.attributions[index].deletedAt == nil else { return }
        let stamp = PersistedMutationClock.next(after: ledger.attributions[index].updatedAt)
        ledger.attributions[index].deletedAt = stamp
        ledger.attributions[index].updatedAt = stamp
        ledger.updatedAt = max(ledger.updatedAt, stamp)
        try write(ledger, to: url)
    }

    // MARK: Merge

    @discardableResult
    static func merge(_ incoming: PromotionLedger, at fileURL: URL? = nil, notify: Bool = true) throws -> [String] {
        guard incoming.schemaVersion == 1 else {
            throw StoreError.invalid(["versión de archivo desconocida (\(incoming.schemaVersion))"])
        }
        let url = try fileURL ?? defaultURL()
        var current = try read(fileURL: url)
        let conflicts = mergeConflicts(local: current, incoming: incoming)
        current.promotions = mergeRows(local: current.promotions, incoming: incoming.promotions,
                                       id: { $0.id })
        let mergedAttributions = mergeRows(local: current.attributions,
                                           incoming: incoming.attributions,
                                           id: { $0.id })
        current.attributions = collapseByNaturalKey(mergedAttributions)
        current.updatedAt = max(current.updatedAt, incoming.updatedAt)
        try write(current, to: url, notify: notify)
        return conflicts
    }

    static func mergeConflicts(local: PromotionLedger, incoming: PromotionLedger) -> [String] {
        let conflicts = incoming.promotions.filter { candidate in
            local.promotions.contains { $0.id == candidate.id && $0.updatedAt == candidate.updatedAt && $0 != candidate }
        }.count + incoming.attributions.filter { candidate in
            local.attributions.contains { $0.id == candidate.id && $0.updatedAt == candidate.updatedAt && $0 != candidate }
        }.count
        return conflicts == 0 ? [] : ["\(conflicts) conflictos de promociones con fecha idéntica: se conservó la versión local."]
    }

    static func reset(fileURL: URL? = nil, notify: Bool = true) throws {
        let url = try fileURL ?? defaultURL()
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        if notify { NotificationCenter.default.post(name: didChangeNotification, object: nil) }
    }

    /// Migración única del V1: el `PromotionOverrides.json` del evaluador
    /// automático retirado jamás se reinterpreta como adjudicaciones — se
    /// renombra a una copia `retired` recuperable junto al ledger. No-op si el
    /// archivo legacy no existe.
    static func retireLegacyOverridesIfNeeded(overridesURL: URL? = nil) throws {
        let legacyURL: URL
        if let overridesURL {
            legacyURL = overridesURL
        } else {
            let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                      in: .userDomainMask, appropriateFor: nil, create: true)
            legacyURL = support.appendingPathComponent("FinanceTracker/PromotionOverrides.json")
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyURL.path) else { return }
        let stamp = ISO8601DateFormatter().string(from: .now)
            .replacingOccurrences(of: ":", with: "-")
        let retired = legacyURL.deletingLastPathComponent()
            .appendingPathComponent("PromotionOverrides.retired-\(stamp).json")
        try fm.moveItem(at: legacyURL, to: retired)
    }

    // MARK: Ubicación

    static func defaultURL() throws -> URL {
        let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCInjectBundleInto"] != nil
        let support: URL
        if isRunningTests {
            support = FileManager.default.temporaryDirectory
                .appendingPathComponent("FinanceTrackerTests-\(ProcessInfo.processInfo.processIdentifier)",
                                        isDirectory: true)
        } else {
            support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                  in: .userDomainMask, appropriateFor: nil, create: true)
        }
        let directory = support.appendingPathComponent("FinanceTracker", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("PromotionLedger.json")
    }

    // MARK: Normalización

    /// Colapsa duplicados de la llave natural `(promotionID, transactionID)`
    /// dejando al ganador (mayor `updatedAt`, desempate por id).
    private static func collapseByNaturalKey(_ attributions: [PromotionAttribution]) -> [PromotionAttribution] {
        var winners: [PromotionAttribution.PairKey: PromotionAttribution] = [:]
        for candidate in attributions {
            let key = PromotionAttribution.PairKey(candidate)
            if let existing = winners[key], !displaces(candidate, existing) { continue }
            winners[key] = candidate
        }
        return winners.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    /// Reporta las reparaciones deterministas que la lectura aplicaría sobre
    /// `ledger` (duplicados de llave natural y de id de promo). La UI de
    /// Settings lo muestra para que el colapso no sea silencioso.
    static func validate(_ ledger: PromotionLedger) -> [String] {
        var notes: [String] = []
        var seenPairs = Set<PromotionAttribution.PairKey>()
        var duplicatePairs = 0
        for attribution in ledger.attributions {
            if !seenPairs.insert(PromotionAttribution.PairKey(attribution)).inserted {
                duplicatePairs += 1
            }
        }
        if duplicatePairs > 0 {
            notes.append("\(duplicatePairs) adjudicaciones duplicadas se colapsan al leer (gana la más reciente)")
        }
        var seenPromotions = Set<UUID>()
        var duplicatePromotions = 0
        for promotion in ledger.promotions {
            if !seenPromotions.insert(promotion.id).inserted {
                duplicatePromotions += 1
            }
        }
        if duplicatePromotions > 0 {
            notes.append("\(duplicatePromotions) promociones duplicadas por id se colapsan al leer")
        }
        return notes
    }

    private static func normalized(_ ledger: PromotionLedger) -> PromotionLedger {
        var normalized = ledger
        normalized.attributions = collapseByNaturalKey(ledger.attributions)
        var winners: [UUID: PromotionRecord] = [:]
        for candidate in ledger.promotions {
            if let existing = winners[candidate.id], !displaces(candidate, existing) { continue }
            winners[candidate.id] = candidate
        }
        normalized.promotions = winners.values.sorted { $0.id.uuidString < $1.id.uuidString }
        return normalized
    }

    /// Fusión por identidad: gana la fila con mayor `updatedAt`; en empate, el
    /// `id.uuidString` mayor. Los tombstones participan como filas normales.
    private static func mergeRows<T>(local: [T], incoming: [T], id: (T) -> UUID) -> [T]
    where T: Identifiable & updatedAtComparable {
        var byID = Dictionary(local.map { (id($0), $0) }, uniquingKeysWith: { first, _ in first })
        for candidate in incoming {
            if let existing = byID[id(candidate)], !displaces(candidate, existing) { continue }
            byID[id(candidate)] = candidate
        }
        return byID.values.sorted { id($0).uuidString < id($1).uuidString }
    }

    private static func displaces<T>(_ candidate: T, _ existing: T) -> Bool
    where T: updatedAtComparable {
        if candidate.updatedAtStamp != existing.updatedAtStamp {
            return candidate.updatedAtStamp > existing.updatedAtStamp
        }
        return candidate.idStamp > existing.idStamp
    }
}

private extension PromotionAttribution {
    struct PairKey: Hashable {
        let promotionID: UUID
        let transactionID: UUID
        init(_ attribution: PromotionAttribution) {
            promotionID = attribution.promotionID
            transactionID = attribution.transactionID
        }
    }
}

/// Comparabilidad determinista compartida por las filas del ledger.
protocol updatedAtComparable {
    var updatedAtStamp: Date { get }
    var idStamp: String { get }
}

extension PromotionRecord: updatedAtComparable {
    var updatedAtStamp: Date { updatedAt }
    var idStamp: String { id.uuidString }
}

extension PromotionAttribution: updatedAtComparable {
    var updatedAtStamp: Date { updatedAt }
    var idStamp: String { id.uuidString }
}

private extension PromotionLedgerStore {
    static func write(_ ledger: PromotionLedger, to url: URL, notify: Bool = true) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(truncatingDatesToWholeSeconds(ledger)).write(to: url, options: .atomic)
        if notify { NotificationCenter.default.post(name: didChangeNotification, object: nil) }
    }

    /// El archivo local codifica fechas como `Double` (fracción sub-segundo
    /// completa) y el bundle como ISO8601 (segundos). Sin truncar, un restore
    /// puede ver la MISMA fila como «más nueva» local que en el bundle y
    /// elegir un ganador equivocado al mezclar. Segundos enteros en ambas
    /// representaciones; el desempate por id queda como contrato consistente.
    static func truncatingDatesToWholeSeconds(_ ledger: PromotionLedger) -> PromotionLedger {
        func trunc(_ date: Date) -> Date {
            Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
        }
        var truncated = ledger
        truncated.updatedAt = trunc(ledger.updatedAt)
        truncated.promotions = ledger.promotions.map { promotion in
            var promotion = promotion
            promotion.windowStart = promotion.windowStart.map(trunc)
            promotion.windowEnd = promotion.windowEnd.map(trunc)
            promotion.archivedAt = promotion.archivedAt.map(trunc)
            promotion.createdAt = trunc(promotion.createdAt)
            promotion.updatedAt = trunc(promotion.updatedAt)
            promotion.deletedAt = promotion.deletedAt.map(trunc)
            return promotion
        }
        truncated.attributions = ledger.attributions.map { attribution in
            var attribution = attribution
            attribution.createdAt = trunc(attribution.createdAt)
            attribution.updatedAt = trunc(attribution.updatedAt)
            attribution.deletedAt = attribution.deletedAt.map(trunc)
            return attribution
        }
        return truncated
    }
}

// MARK: - Protocolo de dos almacenes

/// Ejecuta la adjudicación DESPUÉS de persistir la transacción (spec
/// §Protocolo de guardado). `retry` re-ejecuta únicamente el upsert
/// idempotente del ledger — jamás crea otra transacción.
enum AttributionSaver {
    struct Outcome: Equatable {
        let appliedPromotionIDs: Set<UUID>
        let failedPromotionIDs: Set<UUID>
    }

    /// Filtra defensivamente por moneda viva de la promo (PA-05) y adjudica;
    /// devuelve los ids cuya escritura falló (fail-visible).
    @discardableResult
    static func apply(transactionID: UUID, currency: String,
                      selectedPromotionIDs: Set<UUID>,
                      ledger: PromotionLedger,
                      storeURL: URL? = nil) -> Outcome {
        let allowed = Set(PromotionBoard.selectablePromotions(ledger: ledger, currency: currency).map(\.id))
        let candidates = selectedPromotionIDs.intersection(allowed)
        var failed = Set<UUID>()
        for promotionID in candidates {
            do {
                try PromotionLedgerStore.attribute(transactionID: transactionID,
                                                   promotionID: promotionID, at: storeURL)
            } catch {
                failed.insert(promotionID)
            }
        }
        return Outcome(appliedPromotionIDs: candidates.subtracting(failed),
                       failedPromotionIDs: failed)
    }

    /// Reintento del solo-ledger: idempotente por llave natural.
    @discardableResult
    static func retry(transactionID: UUID, failedPromotionIDs: Set<UUID>,
                      storeURL: URL? = nil) -> Set<UUID> {
        var failed = Set<UUID>()
        for promotionID in failedPromotionIDs {
            do {
                try PromotionLedgerStore.attribute(transactionID: transactionID,
                                                   promotionID: promotionID, at: storeURL)
            } catch {
                failed.insert(promotionID)
            }
        }
        return failed
    }
}
