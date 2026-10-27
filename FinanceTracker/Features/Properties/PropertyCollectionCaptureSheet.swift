import SwiftUI

/// A receipt has four decisions in the usual flow. Existing bank receipts use the
/// same member reconciliation without creating another transaction.
struct PropertyCollectionCaptureSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var workspace: PropertyWorkspaceModel
    let property: PropertyRecord
    let report: PropertyMonthlyReport
    let accounts: [Account]
    var existingSources: [PropertyTransactionInput]? = nil
    @State private var accountID: UUID?
    @State private var residentID: UUID?
    @State private var existingID: UUID?
    @State private var amountText = ""
    @State private var date = Date.now
    @State private var pendingTransactionID: UUID?
    @State private var pendingAmount: Decimal?
    @State private var errorText: String?
    @State private var isSubmitting = false
    @State private var didSave = false

    private var isRecovery: Bool { existingSources != nil }
    private var displayedAccounts: [Account] {
        accounts
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }
    private var hasEligibleAccount: Bool {
        accounts.contains { PropertyWorkspaceModel.eligibleCollectionAccount($0, on: date) }
    }
    private var selectedAccount: Account? { accounts.first { $0.id == accountID } }
    private var selectedSource: PropertyTransactionInput? { existingSources?.first { $0.id == existingID } }
    private var members: [(id: UUID, name: String)] {
        let closeIDs = workspace.ledger.closes.filter { $0.propertyID == property.id && $0.monthStart <= report.monthStart }
            .flatMap { $0.residents.map { ($0.id, $0.name) } }
        let all = report.residents.map { ($0.id, $0.name) } + closeIDs
        var seen = Set<UUID>()
        return all.filter { seen.insert($0.0).inserted }.map { ($0.0, $0.1) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private var amount: Decimal? {
        PropertyCollectionPosting.parseEntryAmount(amountText)
    }
    private var canSave: Bool {
        residentID != nil && (isRecovery ? selectedSource != nil : selectedAccount.map {
            PropertyWorkspaceModel.eligibleCollectionAccount($0, on: date)
        } == true
            && amount.map(PropertyWorkspaceModel.isMXNCollectionAmount) == true && date <= .now)
            && pendingTransactionID == nil && !isSubmitting && !didSave
    }
    private var includeCurrent: Bool {
        workspace.destination != .household
            || workspace.ledger.closes.contains { $0.propertyID == property.id && $0.monthStart == report.monthStart }
            || workspace.householdMonth(report.monthStart) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(isRecovery ? LocalizedStringKey("Reconcile existing receipt") : LocalizedStringKey("Register collection"))
                .font(.headline).frame(maxWidth: .infinity)
            Text(property.name).font(.subheadline).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
            VStack(spacing: 0) {
                if isRecovery {
                    row("Registered income") {
                        Picker("Registered income", selection: $existingID) {
                            Text("Choose a receipt").tag(UUID?.none)
                            ForEach(existingSources ?? []) { source in
                                Text("\(source.postedAt.formatted(date: .abbreviated, time: .omitted)) · \(source.description) · \(propertyMoneyText(source.amount))")
                                    .tag(UUID?.some(source.id))
                            }
                        }.labelsHidden().frame(maxWidth: .infinity, alignment: .trailing)
                            .disabled(pendingTransactionID != nil)
                    }
                    Divider()
                } else {
                    row("Account") {
                        Picker("Account", selection: $accountID) {
                            Text("Choose an account").tag(UUID?.none)
                            ForEach(displayedAccounts) { account in
                                Text(accountLabel(account)).tag(UUID?.some(account.id))
                                    .disabled(!PropertyWorkspaceModel.eligibleCollectionAccount(account, on: date))
                            }
                        }.labelsHidden().frame(maxWidth: .infinity, alignment: .trailing)
                            .disabled(pendingTransactionID != nil)
                    }
                    Divider()
                }
                row("Member") {
                    Picker("Member", selection: $residentID) {
                        Text("Choose a member").tag(UUID?.none)
                        ForEach(members, id: \.id) { member in
                            Text(member.name).tag(UUID?.some(member.id))
                        }
                    }.labelsHidden().frame(maxWidth: .infinity, alignment: .trailing)
                        .disabled(pendingTransactionID != nil)
                }
                Divider()
                row("Amount") {
                    if isRecovery {
                        Text(selectedSource.map { propertyMoneyText($0.amount) } ?? "—").monospacedDigit()
                    } else {
                        TextField("Amount in MXN", text: $amountText).multilineTextAlignment(.trailing)
                            .textFieldStyle(.roundedBorder).monospacedDigit()
                            .disabled(pendingTransactionID != nil)

                    }
                }
                Divider()
                row("Date") {
                    if isRecovery {
                        Text(selectedSource?.postedAt.formatted(date: .abbreviated, time: .omitted) ?? "—")
                    } else {
                        DatePicker("Date", selection: $date, in: ...Date.now, displayedComponents: .date)
                            .labelsHidden().frame(maxWidth: .infinity, alignment: .trailing)
                            .disabled(pendingTransactionID != nil)
                    }
                }
            }
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: GlassRadius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: GlassRadius.card).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
            if !isRecovery && !hasEligibleAccount {
                Text("An active MXN account is required to register a collection.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if isRecovery && existingSources?.isEmpty == true {
                Text("No eligible income is available to reconcile. Check the account and the receipt's destination.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let errorText { Label(errorText, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            if pendingTransactionID != nil {
                Text("The income was saved to the account, but its property payment is pending. Retry linking this receipt; another income will not be created.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                if pendingTransactionID != nil {
                    Button("Retry linking") { save() }.buttonStyle(.borderedProminent).disabled(isSubmitting || didSave)
                } else {
                    Button(action: save) {
                        Text(isRecovery ? LocalizedStringKey("Reconcile receipt") : LocalizedStringKey("Save collection"))
                    }
                    .buttonStyle(.borderedProminent).disabled(!canSave)
                }
            }
        }
        .padding(20).frame(minWidth: 540, idealWidth: 620, maxWidth: 720)
        .onChange(of: residentID) { suggestAmount() }
        .onChange(of: existingID) { suggestAmount() }
    }

    private func row<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            Text(title).frame(width: 118, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func suggestAmount() {
        guard let residentID else { return }
        if let source = selectedSource { amountText = source.amount.description; return }
        let suggested = PropertyCollectionPosting.suggestedAmount(propertyID: property.id, residentID: residentID,
            report: report, ledger: workspace.ledger, inputs: workspace.transactionInputs,
            asOf: max(workspace.asOf, .now), includeCurrent: includeCurrent)
        amountText = PropertyCollectionPosting.suggestedEntryText(suggested)
    }

    private func accountLabel(_ account: Account) -> String {
        let name = account.displayName
        if account.archivedAt != nil { return "\(name) · \(String(localized: "Archived account"))" }
        if account.closedAt != nil { return "\(name) · \(String(localized: "Closed account"))" }
        if account.currency != "MXN" { return "\(name) · \(account.currency) (\(String(localized: "MXN only")))" }
        return name
    }

    private func save() {
        guard !isSubmitting && !didSave else { return }
        guard let residentID else { return }
        let sourceID = pendingTransactionID ?? selectedSource?.id
        let actualAmount = sourceID.flatMap { id in
            (workspace.transactionInputs + (existingSources ?? [])).first { $0.id == id }?.amount
        } ?? pendingAmount ?? amount
        guard let actualAmount else { return }
        isSubmitting = true
        defer { if !didSave { isSubmitting = false } }
        let result = workspace.registerCollection(propertyID: property.id, residentID: residentID,
            account: selectedAccount, amount: actualAmount, date: selectedSource?.postedAt ?? date,
            pendingTransactionID: sourceID)
        switch result {
        case .saved: didSave = true; dismiss()
        case .needsLink(let id):
            pendingTransactionID = id
            pendingAmount = actualAmount
            errorText = workspace.error ?? String(localized: "Could not link the receipt to the property.")
        case .rejected(let reason): errorText = reason
        }
    }
}
