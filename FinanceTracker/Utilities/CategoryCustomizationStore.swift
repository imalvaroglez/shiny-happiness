import Foundation

/// Personalización de categorías persistida como JSON (renombres con origen
/// seed + tinte del badge). Cero schema SwiftData (AD-023): el modelo
/// `Category` sigue congelado y esta capa vive aparte, como el ledger de
/// promociones.
struct CategoryCustomization: Codable, Equatable, Identifiable, Sendable {
    var id: UUID { categoryID }
    let categoryID: UUID
    /// Nombre original si la categoría provenía del seed: evita que el
    /// bootstrap re-cree la categoría con su nombre de fábrica tras un rename.
    var seedName: String?
    /// Tinte del badge en formato "#RRGGBB"; nil = color automático por nombre.
    var tintHex: String?
    var updatedAt: Date
    var deletedAt: Date?
}

struct CategoryCustomizationCatalog: Codable, Equatable, Sendable {
    var schemaVersion: Int = 1
    var updatedAt = Date.distantPast
    var entries: [CategoryCustomization] = []
}

enum CategoryCustomizationStore {
    static let didChangeNotification = Notification.Name("categoryCustomizationDidChange")

    enum StoreError: LocalizedError {
        case invalid([String])

        var errorDescription: String? {
            switch self {
            case .invalid(let issues):
                "Personalización de categorías inválida: \(issues.joined(separator: "; "))."
            }
        }
    }

    // MARK: Lectura

    static func read(fileURL: URL? = nil) throws -> CategoryCustomizationCatalog {
        let url = try fileURL ?? defaultURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return CategoryCustomizationCatalog()
        }
        let catalog = try JSONDecoder().decode(CategoryCustomizationCatalog.self,
                                               from: Data(contentsOf: url))
        guard catalog.schemaVersion == 1 else {
            throw StoreError.invalid(["versión de archivo desconocida (\(catalog.schemaVersion))"])
        }
        return normalized(catalog)
    }

    // MARK: Escritura

    static func replace(with catalog: CategoryCustomizationCatalog, at fileURL: URL? = nil) throws {
        guard catalog.schemaVersion == 1 else {
            throw StoreError.invalid(["versión de archivo desconocida (\(catalog.schemaVersion))"])
        }
        try write(normalized(catalog), to: try fileURL ?? defaultURL())
    }

    static func setSeedName(categoryID: UUID, seedName: String, at fileURL: URL? = nil) throws {
        try mutate(categoryID: categoryID, at: fileURL) { entry in
            entry.seedName = seedName
        }
    }

    static func setTint(categoryID: UUID, hex: String, at fileURL: URL? = nil) throws {
        try mutate(categoryID: categoryID, at: fileURL) { entry in
            entry.tintHex = hex
        }
    }

    static func clearTint(categoryID: UUID, at fileURL: URL? = nil) throws {
        try mutate(categoryID: categoryID, at: fileURL) { entry in
            entry.tintHex = nil
        }
    }

    // MARK: Merge / reset

    static func merge(_ incoming: CategoryCustomizationCatalog, at fileURL: URL? = nil) throws {
        guard incoming.schemaVersion == 1 else {
            throw StoreError.invalid(["versión de archivo desconocida (\(incoming.schemaVersion))"])
        }
        let url = try fileURL ?? defaultURL()
        var current = try read(fileURL: url)
        var byCategory = Dictionary(current.entries.map { ($0.categoryID, $0) },
                                    uniquingKeysWith: { first, _ in first })
        for candidate in incoming.entries {
            if let existing = byCategory[candidate.categoryID],
               !displaces(candidate, existing) { continue }
            byCategory[candidate.categoryID] = candidate
        }
        current.entries = byCategory.values.sorted { $0.categoryID.uuidString < $1.categoryID.uuidString }
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
        return directory.appendingPathComponent("CategoryCustomization.json")
    }

    // MARK: Privado

    private static func mutate(categoryID: UUID, at fileURL: URL?,
                               change: (inout CategoryCustomization) -> Void) throws {
        let url = try fileURL ?? defaultURL()
        var catalog = try read(fileURL: url)
        var entry = catalog.entries.first { $0.categoryID == categoryID }
            ?? CategoryCustomization(categoryID: categoryID, seedName: nil, tintHex: nil,
                                     updatedAt: Date.distantPast, deletedAt: nil)
        change(&entry)
        entry.updatedAt = .now
        entry.deletedAt = nil
        catalog.entries.removeAll { $0.categoryID == categoryID }
        catalog.entries.append(entry)
        catalog.updatedAt = .now
        try write(catalog, to: url)
    }

    private static func normalized(_ catalog: CategoryCustomizationCatalog) -> CategoryCustomizationCatalog {
        var normalized = catalog
        var winners: [UUID: CategoryCustomization] = [:]
        for candidate in catalog.entries {
            if let existing = winners[candidate.categoryID], !displaces(candidate, existing) { continue }
            winners[candidate.categoryID] = candidate
        }
        normalized.entries = winners.values.sorted { $0.categoryID.uuidString < $1.categoryID.uuidString }
        return normalized
    }

    private static func displaces(_ candidate: CategoryCustomization,
                                  _ existing: CategoryCustomization) -> Bool {
        if candidate.updatedAt != existing.updatedAt {
            return candidate.updatedAt > existing.updatedAt
        }
        return candidate.categoryID.uuidString > existing.categoryID.uuidString
    }

    private static func write(_ catalog: CategoryCustomizationCatalog, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(truncatingDatesToWholeSeconds(catalog)).write(to: url, options: .atomic)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    /// Segundos enteros en archivo local y bundle (paridad de precisión al
    /// mezclar restores, igual que el ledger de promociones).
    private static func truncatingDatesToWholeSeconds(_ catalog: CategoryCustomizationCatalog)
        -> CategoryCustomizationCatalog {
        func trunc(_ date: Date) -> Date {
            Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
        }
        var truncated = catalog
        truncated.updatedAt = trunc(catalog.updatedAt)
        truncated.entries = catalog.entries.map { entry in
            var entry = entry
            entry.updatedAt = trunc(entry.updatedAt)
            entry.deletedAt = entry.deletedAt.map(trunc)
            return entry
        }
        return truncated
    }
}
