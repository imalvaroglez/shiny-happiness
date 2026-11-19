import SwiftData
import SwiftUI

/// Extensión de la hoja de captura: fila opcional «Vincular compra» de la
/// categoría Reembolso y resolución del vínculo tras guardar el movimiento.
/// (En archivo separado — la hoja principal ya ronda el límite práctico del
/// type-checker de Swift 6.)
extension ManualTransactionSheet {
    /// La fila solo existe para la categoría semilla Reembolso (identidad por
    /// nombre semilla, no por nombre editable).
    var isSelectedCategoryRefund: Bool {
        CategorySemanticIdentity.matches(selectedCategory, name: "Refund")
    }

    var linkedPurchaseSummary: String? {
        guard let linkedPurchase else { return nil }
        return "\(linkedPurchase.descriptionRaw) · \(linkedPurchase.postedAt.formatted(date: .abbreviated, time: .omitted))"
    }

    /// Fila opcional de la categoría Reembolso: elige la compra que este
    /// reembolso descontará. Nada se vincula hasta guardar.
    var linkPurchaseRow: some View {
        row("Link purchase") {
            HStack(spacing: 8) {
                Button {
                    showingLinkPicker = true
                } label: {
                    HStack(spacing: 8) {
                        Text(linkedPurchaseSummary ?? String(localized: "Optional"))
                            .foregroundStyle(linkedPurchase == nil ? .secondary : .primary)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .buttonStyle(.plain)
                if linkedPurchase != nil {
                    Button {
                        linkedPurchase = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.borderless)
                    .help(String(localized: "Clear linked purchase"))
                }
            }
        }
    }

    /// Intenta vincular el reembolso recién guardado con la compra elegida.
    /// Un fallo deja el vínculo como pendiente recuperable (Reintentar o desde
    /// el detalle), nunca descarta el movimiento ya guardado.
    func linkRefundAfterSave(_ transaction: Transaction, context: ModelContext) {
        guard let purchase = linkedPurchase, isSelectedCategoryRefund else { return }
        do {
            try TransactionLinkService.linkRefund(refund: transaction, purchase: purchase, context: context)
        } catch {
            pendingLinkTransaction = transaction
            linkSaveError = String(localized: "The movement was saved, but the refund link failed: \(error.localizedDescription)")
        }
    }

    /// Tras resolver el vínculo pendiente (reintento exitoso o «Cerrar sin
    /// vincular»): aplica las adjudicaciones a promociones aún pendientes y
    /// cierra según su desenlace — nunca se descartan en silencio.
    func finishAfterLinkResolution() {
        guard let saved = pendingLinkTransaction else {
            finishAfterSuccess()
            return
        }
        pendingLinkTransaction = nil
        linkSaveError = nil
        applyAttributions(to: saved)
        if attributionFailure == nil {
            finishAfterSuccess()
        }
    }
}
