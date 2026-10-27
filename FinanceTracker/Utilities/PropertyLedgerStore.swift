import Foundation

enum PropertyLedgerStore {
    static let didChangeNotification = Notification.Name("propertyLedgerDidChange")

    enum StoreError: LocalizedError {
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .invalid(let reason): "El registro de propiedades no es válido: \(reason)"
            }
        }
    }

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
        return directory.appendingPathComponent("PropertyLedger.json")
    }

    static func read(fileURL: URL? = nil) throws -> PropertyLedger {
        let url = try fileURL ?? defaultURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return PropertyLedger() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var ledger = try decoder.decode(PropertyLedger.self, from: Data(contentsOf: url))
        let errors = validate(ledger)
        guard errors.isEmpty else { throw StoreError.invalid(errors.joined(separator: "; ")) }
        ledger.schemaVersion = 2 // Upgrade only in memory; reading never rewrites a legacy file.
        return ledger
    }

    static func replace(with ledger: PropertyLedger, at fileURL: URL? = nil, notify: Bool = true) throws {
        let errors = validate(ledger)
        guard errors.isEmpty else { throw StoreError.invalid(errors.joined(separator: "; ")) }
        let url = try fileURL ?? defaultURL()
        var saved = ledger
        saved.schemaVersion = 2
        saved.updatedAt = max(saved.updatedAt, Date.now)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(saved)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        if notify { NotificationCenter.default.post(name: didChangeNotification, object: nil) }
    }

    @discardableResult
    static func merge(_ incoming: PropertyLedger, at fileURL: URL? = nil, notify: Bool = true) throws -> [String] {
        let errors = validate(incoming)
        guard errors.isEmpty else { throw StoreError.invalid(errors.joined(separator: "; ")) }
        var local = try read(fileURL: fileURL)
        var warnings: [String] = []
        local.properties = mergeRows(local.properties, incoming.properties, timestamp: \.updatedAt)
        local.residents = mergeRows(local.residents, incoming.residents, timestamp: \.updatedAt)
        local.incomes = mergeRows(local.incomes, incoming.incomes, timestamp: \.updatedAt)
        local.rents = mergeRows(local.rents, incoming.rents, timestamp: \.updatedAt)
        local.serviceBudgets = mergeRows(local.serviceBudgets, incoming.serviceBudgets, timestamp: \.updatedAt)
        local.attributions = mergeRows(local.attributions, incoming.attributions, timestamp: \.updatedAt)
        local.paymentApplications = mergeRows(local.paymentApplications, incoming.paymentApplications, timestamp: \.updatedAt)
        local.adjustments = mergeRows(local.adjustments, incoming.adjustments, timestamp: \.mergeUpdatedAt)
        local.maintenancePrograms = mergeRows(local.maintenancePrograms, incoming.maintenancePrograms, timestamp: \.updatedAt)
        local.maintenanceRecoveries = mergeRows(local.maintenanceRecoveries, incoming.maintenanceRecoveries, timestamp: \.updatedAt)
        local.reserveMovements = mergeRows(local.reserveMovements, incoming.reserveMovements, timestamp: \.mergeUpdatedAt)

        for close in incoming.closes {
            if let existingIndex = local.closes.firstIndex(where: {
                $0.propertyID == close.propertyID && $0.monthStart == close.monthStart
            }) {
                if local.closes[existingIndex] != close {
                    warnings.append("Hay cierres distintos para \(close.monthStart.formatted(date: .numeric, time: .omitted)); se conservó el cierre local.")
                }
            } else {
                local.closes.append(close)
            }
        }
        if let link = incoming.householdLink {
            if let existing = local.householdLink, existing.propertyID != link.propertyID {
                throw StoreError.invalid("enlaces del hogar incompatibles; concilia los registros antes de combinar")
            }
            if local.householdLink == nil || local.householdLink!.updatedAt < link.updatedAt {
                local.householdLink = link
            }
        }
        local.householdMonths = mergeRows(local.householdMonths ?? [], incoming.householdMonths ?? [], timestamp: \.updatedAt)
        local.schemaVersion = 2
        local.updatedAt = max(local.updatedAt, incoming.updatedAt)
        try replace(with: local, at: fileURL, notify: notify)
        return warnings
    }

    static func reset(fileURL: URL? = nil, notify: Bool = true) throws {
        let url = try fileURL ?? defaultURL()
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        if notify { NotificationCenter.default.post(name: didChangeNotification, object: nil) }
    }

    static func validate(_ ledger: PropertyLedger) -> [String] {
        guard (1...2).contains(ledger.schemaVersion) else { return ["versión de archivo desconocida (\(ledger.schemaVersion))"] }
        var errors: [String] = []
        let propertyIDs = Set(ledger.properties.map(\.id))
        let residentIDs = Set(ledger.residents.map(\.id))
        if propertyIDs.count != ledger.properties.count { errors.append("identificadores de propiedad repetidos") }
        if residentIDs.count != ledger.residents.count { errors.append("identificadores de residente repetidos") }
        if Set(ledger.incomes.map(\.id)).count != ledger.incomes.count { errors.append("identificadores de ingreso repetidos") }
        if Set(ledger.rents.map(\.id)).count != ledger.rents.count { errors.append("identificadores de renta repetidos") }
        if Set(ledger.serviceBudgets.map(\.id)).count != ledger.serviceBudgets.count { errors.append("identificadores de presupuesto repetidos") }
        if Set(ledger.attributions.map(\.id)).count != ledger.attributions.count { errors.append("identificadores de atribución repetidos") }
        if Set(ledger.paymentApplications.map(\.id)).count != ledger.paymentApplications.count { errors.append("identificadores de aplicación repetidos") }
        let activeApplications = ledger.paymentApplications.filter { $0.deletedAt == nil }
        let receiptDestinations = Dictionary(grouping: activeApplications, by: \.paymentTransactionID)
        if receiptDestinations.values.contains(where: { Set($0.map(\.propertyID)).count > 1 }) {
            errors.append("un cobro no puede tener destinos económicos en dos casas")
        }
        if activeApplications.contains(where: { application in
            ledger.attributions.contains { $0.deletedAt == nil && $0.transactionID == application.paymentTransactionID }
        }) { errors.append("un movimiento no puede ser gasto o reembolso y cobro simultáneamente") }
        let activeAdvances = ledger.paymentApplications.filter { $0.deletedAt == nil && PropertyPaymentAdvance.isAdvance($0) }
        if Set(activeAdvances.map(\.paymentTransactionID)).count != activeAdvances.count {
            errors.append("un cobro tiene más de un anticipo activo")
        }
        if Set(ledger.adjustments.map(\.id)).count != ledger.adjustments.count { errors.append("identificadores de ajuste repetidos") }
        if Set(ledger.maintenancePrograms.map(\.id)).count != ledger.maintenancePrograms.count { errors.append("identificadores de programa repetidos") }
        if Set(ledger.maintenanceRecoveries.map(\.id)).count != ledger.maintenanceRecoveries.count { errors.append("identificadores de recuperación repetidos") }
        if Set(ledger.reserveMovements.map(\.id)).count != ledger.reserveMovements.count { errors.append("identificadores de fondo repetidos") }
        if Set(ledger.closes.map(\.id)).count != ledger.closes.count { errors.append("identificadores de cierre repetidos") }
        if ledger.residents.contains(where: { !propertyIDs.contains($0.propertyID) }) { errors.append("residente sin propiedad") }
        if ledger.incomes.contains(where: { income in
            guard let resident = ledger.residents.first(where: { $0.id == income.residentID }) else { return true }
            return resident.propertyID != income.propertyID || income.amount < 0
        }) {
            errors.append("ingreso con residente desconocido o importe negativo")
        }
        if ledger.rents.contains(where: { !propertyIDs.contains($0.propertyID) || $0.monthlyAmount < 0 }) {
            errors.append("acuerdo de renta con propiedad desconocida o importe negativo")
        }
        if ledger.attributions.contains(where: { !propertyIDs.contains($0.propertyID) }) { errors.append("atribución con propiedad desconocida") }
        if ledger.serviceBudgets.contains(where: { !propertyIDs.contains($0.propertyID) }) { errors.append("presupuesto con propiedad desconocida") }
        let activeAttributions = ledger.attributions.filter { $0.deletedAt == nil }
        if Set(activeAttributions.map(\.transactionID)).count != activeAttributions.count {
            errors.append("un movimiento está atribuido a más de una propiedad")
        }
        if ledger.attributions.contains(where: { attribution in
            switch attribution.responsibility {
            case .individual(let residentID):
                return !ledger.residents.contains(where: { $0.id == residentID && $0.propertyID == attribution.propertyID })
            case .selected(let residentIDs):
                return residentIDs.contains { id in
                    !ledger.residents.contains(where: { $0.id == id && $0.propertyID == attribution.propertyID })
                }
            case .shared, .owner: return false
            }
        }) { errors.append("atribución con residente responsable desconocido") }
        if ledger.paymentApplications.contains(where: { application in
            application.amount <= 0 || !propertyIDs.contains(application.propertyID)
                || (PropertyPaymentAdvance.isAdvance(application)
                    && (application.id != application.obligationID
                        || (application.residentID != PropertyPaymentAdvance.placeholderResidentID(propertyID: application.propertyID)
                            && !ledger.residents.contains { $0.id == application.residentID && $0.propertyID == application.propertyID })))
                || (!PropertyPaymentAdvance.isAdvance(application)
                    && !ledger.residents.contains(where: { $0.id == application.residentID && $0.propertyID == application.propertyID }))
        }) {
            errors.append("aplicación de cobro inválida")
        }
        if ledger.adjustments.contains(where: {
            !propertyIDs.contains($0.propertyID) || ($0.residentID != nil && !residentIDs.contains($0.residentID!))
        }) { errors.append("ajuste con propiedad o residente desconocido") }
        if ledger.maintenancePrograms.contains(where: { !propertyIDs.contains($0.propertyID) }) {
            errors.append("programa de mantenimiento con propiedad desconocida")
        }
        if ledger.maintenanceRecoveries.contains(where: { recovery in
            !propertyIDs.contains(recovery.propertyID)
                || !ledger.maintenancePrograms.contains(where: { $0.id == recovery.programID })
        }) { errors.append("recuperación con programa o propiedad desconocidos") }
        if ledger.reserveMovements.contains(where: { !propertyIDs.contains($0.propertyID) }) { errors.append("movimiento de fondo con propiedad desconocida") }
        if ledger.closes.contains(where: { !propertyIDs.contains($0.propertyID) }) { errors.append("cierre con propiedad desconocida") }
        let closeKeys = ledger.closes.map { "\($0.propertyID.uuidString)-\($0.monthStart.timeIntervalSince1970)" }
        if Set(closeKeys).count != closeKeys.count { errors.append("hay más de un cierre para la misma propiedad y periodo") }
        if let link = ledger.householdLink {
            if !propertyIDs.contains(link.propertyID) || link.userID == link.partnerID
                || !ledger.residents.contains(where: { $0.id == link.userID && $0.propertyID == link.propertyID })
                || !ledger.residents.contains(where: { $0.id == link.partnerID && $0.propertyID == link.propertyID }) {
                errors.append("enlace del hogar inválido")
            }
        }
        let months = ledger.householdMonths ?? []
        if !months.isEmpty && ledger.householdLink == nil { errors.append("configuración mensual sin enlace del hogar") }
        if Set(months.map(\.id)).count != months.count { errors.append("configuraciones mensuales repetidas") }
        if Set(months.filter { $0.deletedAt == nil }.map(\.monthStart)).count != months.filter({ $0.deletedAt == nil }).count {
            errors.append("más de una configuración activa para el mismo mes")
        }
        if months.contains(where: { $0.partnerIncome < 0 || ($0.userIncome ?? 0) < 0
            || HouseholdSplitMethod(rawValue: $0.splitMethod) == nil
            || Calendar.current.propertyMonthStart(for: $0.monthStart) != $0.monthStart }) {
            errors.append("configuración mensual inválida")
        }
        return errors
    }

    private static func mergeRows<T: Codable & Equatable & Identifiable>(
        _ local: [T], _ incoming: [T], timestamp: KeyPath<T, Date>
    ) -> [T] where T.ID == UUID {
        var rows = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        for candidate in incoming {
            guard let existing = rows[candidate.id] else { rows[candidate.id] = candidate; continue }
            let oldTime = existing[keyPath: timestamp]
            let newTime = candidate[keyPath: timestamp]
            if newTime > oldTime || (newTime == oldTime && stableData(existing).lexicographicallyPrecedes(stableData(candidate))) {
                rows[candidate.id] = candidate
            }
        }
        return rows.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private static func stableData<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)) ?? Data()
    }
}
