import SwiftUI

/// Salud de promociones (spec H): errores de configuración visibles SIN entrar a ninguna
/// cuenta — definiciones rotas, desvinculadas (sin UUID o UUID inexistente) y recursos
/// ausentes. Una advertencia sobre una cuenta inexistente no puede depender de abrir esa cuenta.
struct PromotionHealthSection: View {
    let accountIDs: Set<UUID>
    var catalogOverride: PromotionCatalog? = nil

    var body: some View {
        SectionCard(title: "Promotions") {
            let catalog = catalogOverride ?? PromotionCatalog.load()
            let unbound = catalog.definitions.filter { $0.accountUUID == nil }
            let orphaned = catalog.definitions.filter { $0.accountUUID.map { !accountIDs.contains($0) } ?? false }
            let broken = catalog.warnings

            if broken.isEmpty && unbound.isEmpty && orphaned.isEmpty {
                Text("Todas las promociones del catálogo están vinculadas y legibles.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !broken.isEmpty {
                ForEach(broken, id: \.message) { warning in
                    Label(warning.message, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            ForEach(unbound, id: \.id) { def in
                VStack(alignment: .leading, spacing: 2) {
                    Label("«\(def.displayName)» pendiente de vincular — falta el UUID de la cuenta", systemImage: "link.badge.plus")
                        .font(.caption).foregroundStyle(.secondary)
                    if let nickname = def.authoringNickname {
                        Text("Ayuda de autoría: buscar «\(nickname)» al obtener su UUID.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(orphaned, id: \.id) { def in
                Label("«\(def.displayName)» pendiente de vincular — UUID de cuenta inexistente: \(def.accountUUID?.uuidString ?? "")",
                      systemImage: "link.badge.plus")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text("Las definiciones viven en Domain/Promotions/Catalog (bundle); editarlas es editar el JSON, no la app.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

#Preview("Promotions — invalid catalog and orphaned account") {
    let catalog = PromotionCatalog.load()
    let withError = PromotionCatalog(definitions: catalog.definitions,
        warnings: catalog.warnings + [.init(kind: .invalidDefinition, definitionID: "broken",
                                             message: "broken: patrón de comercio inválido")],
        channelTable: catalog.channelTable, channelTableAvailable: catalog.channelTableAvailable)
    return PromotionHealthSection(accountIDs: [], catalogOverride: withError)
}
