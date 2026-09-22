import SwiftUI

/// Salud de promociones (spec H): errores de configuración visibles SIN entrar a ninguna
/// cuenta — definiciones rotas, desvinculadas (sin UUID o UUID inexistente) y recursos
/// ausentes. Una advertencia sobre una cuenta inexistente no puede depender de abrir esa cuenta.
struct PromotionHealthSection: View {
    var body: some View {
        SectionCard(title: "Promotions") {
            let catalog = PromotionCatalog.load()
            let unbound = catalog.definitions.filter { $0.accountUUID == nil }
            let broken = catalog.warnings

            if broken.isEmpty && unbound.isEmpty {
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
            Text("Las definiciones viven en Domain/Promotions/Catalog (bundle); editarlas es editar el JSON, no la app.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}
