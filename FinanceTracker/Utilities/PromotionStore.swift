import Foundation

struct PromotionOverrides: Codable, Equatable {
    var schemaVersion = 1
    var updatedAt = Date.distantPast
    var definitions: [PromotionDefinition] = []
    var deletedIDs: [String] = []
}

enum PromotionStore {
    enum StoreError: LocalizedError {
        case invalidDefinition([String])

        var errorDescription: String? {
            switch self {
            case .invalidDefinition(let issues): "La promoción tiene datos inválidos: \(issues.joined(separator: "; "))."
            }
        }
    }

    static func load(bundle: Bundle = .main, fileURL: URL? = nil) -> PromotionCatalog {
        let catalog = PromotionCatalog.load(bundle: bundle)
        do {
            let url = try fileURL ?? defaultURL()
            guard FileManager.default.fileExists(atPath: url.path) else { return catalog }
            let data = try Data(contentsOf: url)
            let overrides = try JSONDecoder().decode(PromotionOverrides.self, from: data)
            guard overrides.schemaVersion == 1 else {
                return catalog.withWarning("La configuración de promociones usa una versión no compatible.")
            }
            return catalog.applying(overrides)
        } catch {
            return catalog.withWarning("No se pudo leer la configuración de promociones: \(error.localizedDescription)")
        }
    }

    static func read(fileURL: URL) throws -> PromotionOverrides {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return PromotionOverrides() }
        let overrides = try JSONDecoder().decode(PromotionOverrides.self, from: Data(contentsOf: fileURL))
        guard overrides.schemaVersion == 1 else { throw StoreError.invalidDefinition(["versión de archivo desconocida"]) }
        return overrides
    }

    static func save(_ definition: PromotionDefinition, to fileURL: URL? = nil) throws {
        let issues = PromotionCatalog.validationIssues(definition)
        guard issues.isEmpty else { throw StoreError.invalidDefinition(issues) }
        let url = try fileURL ?? defaultURL()
        var overrides = try read(fileURL: url)
        if let index = overrides.definitions.firstIndex(where: { $0.id == definition.id }) {
            overrides.definitions[index] = definition
        } else {
            overrides.definitions.append(definition)
        }
        overrides.deletedIDs.removeAll { $0 == definition.id }
        overrides.updatedAt = .now
        try write(overrides, to: url)
    }

    static func delete(id: String, to fileURL: URL? = nil) throws {
        let url = try fileURL ?? defaultURL()
        var overrides = try read(fileURL: url)
        overrides.definitions.removeAll { $0.id == id }
        if !overrides.deletedIDs.contains(id) { overrides.deletedIDs.append(id) }
        overrides.updatedAt = .now
        try write(overrides, to: url)
    }

    static func replace(with overrides: PromotionOverrides, at fileURL: URL? = nil) throws {
        try write(overrides, to: fileURL ?? defaultURL())
    }

    static func merge(_ incoming: PromotionOverrides, at fileURL: URL? = nil) throws {
        let url = try fileURL ?? defaultURL()
        let current = try read(fileURL: url)
        guard incoming.updatedAt > current.updatedAt else { return }
        try write(incoming, to: url)
    }

    static func reset(fileURL: URL? = nil) throws {
        let url = try fileURL ?? defaultURL()
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    static func defaultURL() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        let directory = support.appendingPathComponent("FinanceTracker", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("PromotionOverrides.json")
    }

    private static func write(_ overrides: PromotionOverrides, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(overrides).write(to: url, options: .atomic)
    }
}

private extension PromotionCatalog {
    func withWarning(_ message: String) -> PromotionCatalog {
        PromotionCatalog(definitions: definitions,
                         warnings: warnings + [.init(kind: .storageFailed, definitionID: nil, message: message)],
                         channelTable: channelTable, channelTableAvailable: channelTableAvailable)
    }
}
