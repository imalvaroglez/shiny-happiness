import Foundation

/// Catálogo de promociones: carga fail-soft del bundle (patrón Knowledge/*.json).
/// Una entrada rota NO tumba el catálogo: se salta y produce un warning visible.
struct PromotionCatalog: Equatable {
    struct Warning: Equatable {
        enum Kind: Equatable {
            case decodeFailed
            case missingResource
        }
        let kind: Kind
        let definitionID: String?
        let message: String
    }

    let definitions: [PromotionDefinition]
    let warnings: [Warning]
    var channelTable: ChannelTable = ChannelTable(entries: [])

    /// Carga del bundle (patrón Knowledge/*.json): fail-soft; archivo ausente → catálogo
    /// vacío + warning (una promo rota o faltante nunca tumba la app).
    static func load(bundle: Bundle = .main) -> PromotionCatalog {
        var catalog = bundle.url(forResource: "promotions", withExtension: "json")
            .map { decodeFile($0, bundle: bundle) }
            ?? PromotionCatalog(definitions: [], warnings: [
                .init(kind: .missingResource, definitionID: nil,
                      message: "promotions.json no encontrado en el bundle")
            ])
        if let url = bundle.url(forResource: "channel_table", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let table = try? ChannelTable.decode(data) {
            catalog.channelTable = table
        } else {
            catalog = PromotionCatalog(
                definitions: catalog.definitions,
                warnings: catalog.warnings + [.init(kind: .missingResource, definitionID: nil,
                                                    message: "channel_table.json ausente o ilegible")],
                channelTable: catalog.channelTable)
        }
        return catalog
    }

    private static func decodeFile(_ url: URL, bundle: Bundle) -> PromotionCatalog {
        guard let data = try? Data(contentsOf: url) else {
            return PromotionCatalog(definitions: [], warnings: [
                .init(kind: .missingResource, definitionID: nil, message: "No se pudo leer \(url.lastPathComponent)")
            ])
        }
        return decode(data)
    }

    /// Decode por entrada: la primera que falle se omite con warning y el resto sigue.
    static func decode(_ data: Data) -> PromotionCatalog {
        struct Envelope: Decodable { let promotions: [PromotionDefinition] }
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            return PromotionCatalog(definitions: envelope.promotions, warnings: [])
        } catch {
            // El decode del array como bloque no da granularidad: reintentamos entrada por
            // entrada para rescatar las válidas y reportar exactamente cuáles fallaron.
            var definitions: [PromotionDefinition] = []
            var warnings: [Warning] = []
            struct LooseEnvelope: Decodable { let promotions: [LooseEntry] }
            struct LooseEntry: Decodable { let id: String? }
            if let loose = try? JSONDecoder().decode(LooseEnvelope.self, from: data) {
                let rawEntries = Self.rawEntries(in: data)
                for (index, looseEntry) in loose.promotions.enumerated() {
                    guard index < rawEntries.count else { break }
                    do {
                        definitions.append(try JSONDecoder().decode(PromotionDefinition.self, from: rawEntries[index]))
                    } catch {
                        warnings.append(Warning(kind: .decodeFailed, definitionID: looseEntry.id,
                                                 message: "\(error)"))
                    }
                }
            }
            if warnings.isEmpty {
                warnings.append(Warning(kind: .decodeFailed, definitionID: nil,
                                         message: "Catálogo ilegible: \(error)"))
            }
            return PromotionCatalog(definitions: definitions, warnings: warnings)
        }
    }

    /// Extrae el JSON crudo de cada elemento del array "promotions" para re-decodear por entrada.
    private static func rawEntries(in data: Data) -> [Data] {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let array = obj["promotions"] as? [Any] else { return [] }
        return array.compactMap { try? JSONSerialization.data(withJSONObject: $0) }
    }
}
