import Foundation

/// Fail-soft por promoción: una definición defectuosa no bloquea las entradas válidas.
struct PromotionCatalog: Equatable {
    struct Warning: Equatable {
        enum Kind: Equatable { case decodeFailed, invalidDefinition, invalidChannelTable, missingResource }
        let kind: Kind
        let definitionID: String?
        let message: String
    }

    let definitions: [PromotionDefinition]
    let warnings: [Warning]
    var channelTable: ChannelTable = ChannelTable(entries: [])
    var channelTableAvailable = false

    static func load(bundle: Bundle = .main) -> PromotionCatalog {
        var catalog = bundle.url(forResource: "promotions", withExtension: "json")
            .map { decodeFile($0) }
            ?? PromotionCatalog(definitions: [], warnings: [
                .init(kind: .missingResource, definitionID: nil, message: "promotions.json no encontrado en el bundle")
            ])

        guard let url = bundle.url(forResource: "channel_table", withExtension: "json"),
              let data = try? Data(contentsOf: url), let table = decodeChannelTable(data) else {
            catalog = PromotionCatalog(definitions: catalog.definitions,
                warnings: catalog.warnings + [.init(kind: .invalidChannelTable, definitionID: nil,
                    message: "channel_table.json ausente o inválido")], channelTable: catalog.channelTable)
            return catalog
        }
        return PromotionCatalog(definitions: catalog.definitions, warnings: catalog.warnings,
                                channelTable: table, channelTableAvailable: true)
    }

    private static func decodeFile(_ url: URL) -> PromotionCatalog {
        guard let data = try? Data(contentsOf: url) else {
            return PromotionCatalog(definitions: [], warnings: [
                .init(kind: .missingResource, definitionID: nil, message: "No se pudo leer \(url.lastPathComponent)")
            ])
        }
        return decode(data)
    }

    static func decode(_ data: Data) -> PromotionCatalog {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["promotions"] as? [Any] else {
            return PromotionCatalog(definitions: [], warnings: [
                .init(kind: .decodeFailed, definitionID: nil, message: "Catálogo ilegible o falta promotions[]")
            ])
        }

        var definitions: [PromotionDefinition] = []
        var warnings: [Warning] = []
        var ids: Set<String> = []
        for entry in entries {
            let raw = (try? JSONSerialization.data(withJSONObject: entry)) ?? Data()
            let id = (entry as? [String: Any])?["id"] as? String
            do {
                let definition = try JSONDecoder().decode(PromotionDefinition.self, from: raw)
                var issues = validate(definition)
                if (entry as? [String: Any])?["knownUnknowns"] == nil {
                    issues.append("falta knownUnknowns")
                }
                if !ids.insert(definition.id).inserted { issues.append("id duplicado en el catálogo") }
                guard issues.isEmpty else {
                    warnings.append(.init(kind: .invalidDefinition, definitionID: definition.id,
                                           message: "\(definition.id): \(issues.joined(separator: "; "))"))
                    continue
                }
                definitions.append(definition)
            } catch {
                warnings.append(.init(kind: .decodeFailed, definitionID: id,
                                      message: "\(id ?? "entrada sin id"): \(error)"))
            }
        }
        return PromotionCatalog(definitions: definitions, warnings: warnings)
    }

    static func decodeChannelTable(_ data: Data) -> ChannelTable? {
        guard let table = try? ChannelTable.decode(data), validChannelTable(table) else { return nil }
        return table
    }

    private static func validate(_ def: PromotionDefinition) -> [String] {
        var errors: [String] = []
        if def.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errors.append("id vacío") }
        if !Locale.isoCurrencyCodes.contains(def.scope.currency) { errors.append("currency no es un código ISO válido") }
        if !valid(def.window) { errors.append("ventana con fechas inválidas o duración no positiva") }

        let merchantIDs = def.scope.merchants.map(\.id)
        if merchantIDs.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            || Set(merchantIDs).count != merchantIDs.count {
            errors.append("id de comercio vacío o duplicado")
        }
        for pattern in def.scope.merchants.flatMap(\.patterns)
            + def.msiPolicy.reversalPatterns + def.reward.descriptorPatterns where !validRegex(pattern) {
            errors.append("regex inválida: \(pattern)")
        }
        if def.scope.merchants.contains(where: {
            $0.patterns.isEmpty || $0.patterns.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }) { errors.append("comercio sin patrones válidos") }

        switch def.shape {
        case .spendThreshold(let target, let reward):
            if target <= 0 || reward < 0 { errors.append("umbral o recompensa inválidos") }
        case .cashbackCap(let rate, let cap):
            if rate < 0 || rate > 100 || cap <= 0 { errors.append("tasa o tope cashback inválido") }
        case .tieredPeriods(let periods, let threshold, let reward, let cap, let capScope):
            if threshold <= 0 || reward < 0 || cap < 0 || periods.isEmpty {
                errors.append("umbral, recompensa, tope o periodos inválidos")
            }
            var previousEnd: Date?
            for period in periods {
                guard let start = date(period.start), let end = date(period.end), start <= end else {
                    errors.append("periodo inválido \(period.start)…\(period.end)")
                    continue
                }
                if let previousEnd, start <= previousEnd { errors.append("periodos solapados o desordenados") }
                previousEnd = end
                if let window = resolved(def.window), !(window.lowerBound <= start && end < window.upperBound) {
                    errors.append("periodo fuera de la ventana de promoción")
                }
                if capScope == .calendarYear,
                   Calendar.cdmx.component(.year, from: start) != Calendar.cdmx.component(.year, from: end) {
                    errors.append("periodo calendarYear cruza años; dividirlo por año civil CDMX")
                }
            }
        }
        if let threshold = def.msiPolicy.conversionRiskThreshold, threshold <= 0 {
            errors.append("conversionRiskThreshold debe ser positivo")
        }
        if def.reward.expectedAmount < 0 { errors.append("expectedAmount no puede ser negativo") }
        return errors
    }

    private static func valid(_ window: PromotionDefinition.PromotionWindow) -> Bool {
        switch window {
        case .fixed(let start, let end, _):
            guard let s = date(start), let e = date(end) else { return false }
            return s <= e
        case .anchored(let start, let days, _):
            guard days > 0, let startDate = date(start) else { return false }
            return Calendar.cdmx.date(byAdding: .day, value: days, to: startDate) != nil
        case .unknown: return true
        }
    }

    private static func resolved(_ window: PromotionDefinition.PromotionWindow) -> Range<Date>? {
        switch window {
        case .fixed(let start, let end, _):
            guard let s = date(start), let e = date(end), let next = Calendar.cdmx.date(byAdding: .day, value: 1, to: e) else { return nil }
            return s..<next
        case .anchored(let start, let days, _):
            guard let s = date(start), let next = Calendar.cdmx.date(byAdding: .day, value: days, to: s) else { return nil }
            return s..<next
        case .unknown: return nil
        }
    }

    private static func date(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/Mexico_City")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let parsed = formatter.date(from: raw), formatter.string(from: parsed) == raw else { return nil }
        return parsed
    }

    private static func validRegex(_ raw: String) -> Bool { (try? NSRegularExpression(pattern: raw)) != nil }

    private static func validChannelTable(_ table: ChannelTable) -> Bool {
        guard !table.entries.isEmpty else { return false }
        var keys: Set<String> = []
        return table.entries.allSatisfy { entry in
            let hasPattern = entry.pattern?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            let hasMerchant = entry.merchantID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            guard hasPattern != hasMerchant else { return false }
            guard entry.pattern.map(validRegex) ?? true else { return false }
            let identity: String
            if hasPattern, let pattern = entry.pattern {
                identity = "pattern:\(pattern)"
            } else if hasMerchant, let merchantID = entry.merchantID {
                identity = "merchant:\(merchantID)"
            } else {
                return false
            }
            guard keys.insert(identity).inserted else { return false }
            return entry.channel == .aggregator ? hasPattern : hasMerchant
        }
    }
}

private extension Calendar {
    static var cdmx: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Mexico_City")!
        return calendar
    }
}
