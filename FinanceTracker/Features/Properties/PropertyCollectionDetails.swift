import SwiftUI

struct PropertyCollectionSelection: Identifiable { var id: UUID }

struct PropertyCollectionDetails: View {
    let paymentID: UUID
    @Bindable var workspace: PropertyWorkspaceModel
    var onOpen: ((UUID) -> Void)? = nil
    var onRemove: ((UUID) -> Void)? = nil
    var body: some View {
        let source = workspace.transactionInputs.first { $0.id == paymentID }
        let applications = workspace.ledger.paymentApplications.filter { $0.deletedAt == nil && $0.paymentTransactionID == paymentID }
        let obligations = workspace.ledger.closes.flatMap(\.obligations)
            + (workspace.householdMonthlyReport?.obligations ?? []) + workspace.reports.values.flatMap(\.obligations)
        VStack(alignment: .leading, spacing: 14) {
            Text("Collection applications").font(.headline)
            Text(source?.description ?? applications.first?.sourceDescriptionSnapshot ?? String(localized: "Transaction unavailable"))
            Text(source?.accountName ?? String(localized: "Account unavailable")).foregroundStyle(.secondary)
            if source != nil, let onOpen {
                Button("Open movement") { onOpen(paymentID) }.buttonStyle(.link)
            }
            if let amount = source?.amount ?? applications.first?.sourceAmountSnapshot {
                LabeledContent("Original receipt", value: propertyMoneyText(abs(amount), code: source?.currencyCode ?? "MXN"))
            }
            Divider()
            ForEach(applications) { application in
                let advance = PropertyPaymentAdvance.isAdvance(application)
                let obligation = obligations.first { $0.id == application.obligationID }
                let name = workspace.ledger.residents.first { $0.id == application.residentID }?.name ?? String(localized: "Former member")
                let month = workspace.ledger.closes.first { $0.obligations.contains { $0.id == application.obligationID } }?.monthStart
                    ?? ((workspace.reports.values.contains { $0.obligations.contains { $0.id == application.obligationID } }
                         || workspace.householdMonthlyReport?.obligations.contains { $0.id == application.obligationID } == true) ? workspace.selectedMonth : nil)
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        if advance { Text("Available advance") }
                        else { Text(name); Text(obligation?.title ?? String(localized: "Obligation")).font(.caption).foregroundStyle(.secondary) }
                        if let month { Text(propertyMonthText(month)).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Text(propertyMoneyText(application.amount)).monospacedDigit()
                    if let onRemove {
                        Button {
                            onRemove(application.id)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove application")
                    }
                }
            }
            if applications.isEmpty { Text("No applications recorded.").foregroundStyle(.secondary) }
        }
        .padding(20).frame(minWidth: 340, idealWidth: 440, maxWidth: 500)
    }
}
