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
        let url = try fileURL ?? defaultURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return PromotionLedger() }
        let ledger = try JSONDecoder().decode(PromotionLedger.self, from: Data(contentsOf: url))
        guard ledger.schemaVersion == 1 else {
            throw StoreError.invalid(["versión de archivo desconocida (\(ledger.schemaVersion))"])
        }
        return normalized(ledger)
    }

    // MARK: Escritura

    static func replace(with ledger: PromotionLedger, at fileURL: URL? = nil) throws {
        guard ledger.schemaVersion == 1 else {
            throw StoreError.invalid(["versión de archivo desconocida (\(ledger.schemaVersion))"])
        }
        try write(normalized(ledger), to: try fileURL ?? defaultURL())
    }

    static func save(promotion: PromotionRecord, at fileURL: URL? = nil) throws {
        let url = try fileURL ?? defaultURL()
        var ledger = try read(fileURL: url)
        if let index = ledger.promotions.firstIndex(where: { $0.id == promotion.id }) {
            ledger.promotions[index] = promotion
        } else {
            ledger.promotions.append(promotion)
        }
        ledger.updatedAt = .now
        try write(ledger, to: url)
    }

    static func deletePromotion(id: UUID, at fileURL: URL? = nil) throws {
        let url = try fileURL ?? defaultURL()
        var ledger = try read(fileURL: url)
        guard let index = ledger.promotions.firstIndex(where: { $0.id == id }) else { return }
        guard ledger.promotions[index].deletedAt == nil else { return }
        ledger.promotions[index].deletedAt = .now
        ledger.promotions[index].updatedAt = .now
        ledger.updatedAt = .now
        try write(ledger, to: url)
    }

    static func attribute(transactionID: UUID, promotionID: UUID, at fileURL: URL? = nil) throws {
        let url = try fileURL ?? defaultURL()
        var ledger = try read(fileURL: url)
        let now = Date.now
        if let index = ledger.attributions.firstIndex(where: {
            $0.promotionID == promotionID && $0.transactionID == transactionID
        }) {
            ledger.attributions[index].deletedAt = nil
            ledger.attributions[index].updatedAt = now
        } else {
            ledger.attributions.append(
                PromotionAttribution(id: UUID(), promotionID: promotionID,
                                     transactionID: transactionID, createdAt: now,
                                     updatedAt: now, deletedAt: nil))
        }
        ledger.updatedAt = now
        try write(ledger, to: url)
    }

    static func unattribute(transactionID: UUID, promotionID: UUID, at fileURL: URL? = nil) throws {
        let url = try fileURL ?? defaultURL()
        var ledger = try read(fileURL: url)
        guard let index = ledger.attributions.firstIndex(where: {
            $0.promotionID == promotionID && $0.transactionID == transactionID
        }) else { return }
        guard ledger.attributions[index].deletedAt == nil else { return }
        ledger.attributions[index].deletedAt = .now
        ledger.attributions[index].updatedAt = .now
        ledger.updatedAt = .now
        try write(ledger, to: url)
    }

    // MARK: Merge

    static func merge(_ incoming: PromotionLedger, at fileURL: URL? = nil) throws {
        guard incoming.schemaVersion == 1 else {
            throw StoreError.invalid(["versión de archivo desconocida (\(incoming.schemaVersion))"])
        }
        let url = try fileURL ?? defaultURL()
        var current = try read(fileURL: url)
        current.promotions = mergeRows(local: current.promotions, incoming: incoming.promotions,
                                       id: { $0.id })
        let mergedAttributions = mergeRows(local: current.attributions,
                                           incoming: incoming.attributions,
                                           id: { $0.id })
        current.attributions = collapseByNaturalKey(mergedAttributions)
        current.updatedAt = max(current.updatedAt, incoming.updatedAt)
        try write(current, to: url)
    }

    static func reset(fileURL: URL? = nil) throws {
        let url = try fileURL ?? defaultURL()
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
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

    private static func normalized(_ ledger: PromotionLedger) -> PromotionLedger {
        var normalized = ledger
        normalized.attributions = collapseByNaturalKey(ledger.attributions)
        normalized.promotions = {
            var seen = Set<UUID>()
            return ledger.promotions.filter { seen.insert($0.id).inserted }
                .sorted { $0.id.uuidString < $1.id.uuidString }
        }()
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
    static func write(_ ledger: PromotionLedger, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(ledger).write(to: url, options: .atomic)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}
