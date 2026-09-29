import Foundation

struct SpendRequirementSettings: Codable, Equatable {
    var schemaVersion = 1
    var updatedAt = Date.distantPast
    var requirements: [SpendRequirement] = []

    func validate(accountIDs: Set<UUID>? = nil, accountCurrencies: [UUID: String]? = nil) -> [String] {
        var issues: [String] = []
        var seen = Set<UUID>()
        for requirement in requirements {
            if !seen.insert(requirement.accountID).inserted { issues.append("Hay más de un requisito para la misma cuenta.") }
            issues += requirement.validate()
            if requirement.enabled, let accountIDs, !accountIDs.contains(requirement.accountID) {
                issues.append("El requisito está vinculado a una cuenta inexistente.")
            }
            if requirement.enabled, let currency = accountCurrencies?[requirement.accountID],
               requirement.currency != currency {
                issues.append("La moneda del requisito no coincide con la cuenta.")
            }
        }
        return issues
    }
}

enum SpendRequirementStore {
    enum StoreError: LocalizedError {
        case invalid([String])
        var errorDescription: String? {
            switch self {
            case .invalid(let issues): "Configuración de gasto mínimo inválida: \(issues.joined(separator: "; "))."
            }
        }
    }

    static func read(fileURL: URL? = nil) throws -> SpendRequirementSettings {
        let url = try fileURL ?? defaultURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return SpendRequirementSettings() }
        let settings = try JSONDecoder().decode(SpendRequirementSettings.self, from: Data(contentsOf: url))
        guard settings.schemaVersion == 1, settings.validate().isEmpty else {
            throw StoreError.invalid(settings.validate().isEmpty ? ["versión de archivo desconocida"] : settings.validate())
        }
        return settings
    }

    static func bootstrapSuggestions(accounts: [Account], fileURL: URL? = nil) throws -> SpendRequirementSettings {
        let url = try fileURL ?? defaultURL()
        var settings = try read(fileURL: url)
        let existing = Set(settings.requirements.map(\.accountID))
        let suggestions = accounts.compactMap { account -> SpendRequirement? in
            guard let value = SpendRequirement.suggested(for: account) else { return nil }
            let key = accountKey(account)
            return accounts.filter { accountKey($0) == key }.count == 1 ? value : nil
        }
        let additions = suggestions.filter { !existing.contains($0.accountID) }
        guard !additions.isEmpty else { return settings }
        settings.requirements += additions
        settings.updatedAt = .now
        try write(settings, to: url)
        return settings
    }

    static func save(_ requirement: SpendRequirement, to fileURL: URL? = nil) throws {
        let url = try fileURL ?? defaultURL()
        var settings = try read(fileURL: url)
        if let index = settings.requirements.firstIndex(where: { $0.accountID == requirement.accountID }) {
            settings.requirements[index] = requirement
        } else {
            settings.requirements.append(requirement)
        }
        settings.updatedAt = .now
        try write(settings, to: url)
    }

    static func disable(accountID: UUID, at fileURL: URL? = nil) throws {
        let url = try fileURL ?? defaultURL()
        var settings = try read(fileURL: url)
        guard let index = settings.requirements.firstIndex(where: { $0.accountID == accountID }) else { return }
        settings.requirements[index].enabled = false
        settings.requirements[index].lastModifiedAt = .now
        settings.updatedAt = .now
        try write(settings, to: url)
    }

    static func replace(with settings: SpendRequirementSettings, at fileURL: URL? = nil,
                        accountIDs: Set<UUID>? = nil, accountCurrencies: [UUID: String]? = nil) throws {
        let issues = settings.validate(accountIDs: accountIDs, accountCurrencies: accountCurrencies)
        guard settings.schemaVersion == 1, issues.isEmpty else {
            throw StoreError.invalid(issues.isEmpty ? ["versión de archivo desconocida"] : issues)
        }
        try write(settings, to: fileURL ?? defaultURL())
    }

    static func merge(_ incoming: SpendRequirementSettings, at fileURL: URL? = nil,
                      accountIDs: Set<UUID>? = nil, accountCurrencies: [UUID: String]? = nil) throws {
        let url = try fileURL ?? defaultURL()
        let issues = incoming.validate(accountIDs: accountIDs, accountCurrencies: accountCurrencies)
        guard incoming.schemaVersion == 1, issues.isEmpty else {
            throw StoreError.invalid(issues.isEmpty ? ["versión de archivo desconocida"] : issues)
        }
        var current = try read(fileURL: url)
        var byAccount = Dictionary(uniqueKeysWithValues: current.requirements.map { ($0.accountID, $0) })
        for candidate in incoming.requirements {
            if let existing = byAccount[candidate.accountID] {
                if candidate.lastModifiedAt > existing.lastModifiedAt { byAccount[candidate.accountID] = candidate }
            } else {
                byAccount[candidate.accountID] = candidate
            }
        }
        current.requirements = byAccount.values.sorted { $0.accountID.uuidString < $1.accountID.uuidString }
        current.updatedAt = max(current.updatedAt, incoming.updatedAt)
        try write(current, to: url)
    }

    static func reset(fileURL: URL? = nil) throws {
        let url = try fileURL ?? defaultURL()
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    static func defaultURL() throws -> URL {
        let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCInjectBundleInto"] != nil
        let support: URL
        if isRunningTests {
            support = FileManager.default.temporaryDirectory
                .appendingPathComponent("FinanceTrackerTests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        } else {
            support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        }
        let directory = support.appendingPathComponent("FinanceTracker", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("SpendRequirements.json")
    }

    private static func write(_ settings: SpendRequirementSettings, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(settings).write(to: url, options: .atomic)
    }

    private static func accountKey(_ account: Account) -> String {
        [account.nickname, account.institution, account.type.rawValue, account.currency]
            .map { $0.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es_MX")) }
            .joined(separator: "|")
    }
}
