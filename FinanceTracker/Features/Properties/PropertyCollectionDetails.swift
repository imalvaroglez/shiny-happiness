import SwiftUI
import SwiftData

struct PropertyMemberCollectionSelection: Identifiable {
    var id: UUID
}

enum PropertyCollectionHistory {
    static func needsReview(_ application: PropertyPaymentApplication, source: PropertyTransactionInput?) -> Bool {
        guard let source else { return true }
        return !PropertySettlementCalculator.isValidCollectionPayment(source, asOf: .distantFuture)
            || PropertySettlementCalculator.hasSourceChanged(amount: application.sourceAmountSnapshot,
                postedAt: application.sourcePostedAtSnapshot, currencyCode: application.sourceCurrencySnapshot,
                description: application.sourceDescriptionSnapshot, versus: source)
    }
    static func isVisible(_ application: PropertyPaymentApplication,
                          source: PropertyTransactionInput?, asOf: Date) -> Bool {
        if needsReview(application, source: source) { return true }
        let date = source?.postedAt ?? application.sourcePostedAtSnapshot
        return date == nil || date! <= asOf
    }

    static func includes(_ application: PropertyPaymentApplication, source: PropertyTransactionInput?,
                         obligationIDs: Set<UUID>, asOf: Date) -> Bool {
        (PropertyPaymentAdvance.isAdvance(application) || obligationIDs.contains(application.obligationID)
            || needsReview(application, source: source)) && isVisible(application, source: source, asOf: asOf)
    }
}

struct PropertyMemberCollectionsSheet: View {
    private struct ReceiptGroup: Identifiable {
        var id: UUID
        var entries: [PropertyPaymentApplication]
        var source: PropertyTransactionInput?
    }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Bindable var workspace: PropertyWorkspaceModel
    let propertyID: UUID
    let residentID: UUID
    @State private var movement: Transaction?
    @State private var removalID: UUID?
    @State private var removalLabel = ""
    @State private var error: String?

    private var applications: [PropertyPaymentApplication] {
        let sources = Dictionary(workspace.transactionInputs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let obligations = Set(workspace.ledger.closes.filter {
            $0.propertyID == propertyID && $0.monthStart <= workspace.selectedMonth
        }.flatMap { $0.obligations.map(\.id) } + currentObligations.map(\.id))
        return workspace.ledger.paymentApplications.filter { application in
            let source = sources[application.paymentTransactionID]
            return application.propertyID == propertyID && application.residentID == residentID && application.deletedAt == nil
                && PropertyCollectionHistory.includes(application, source: source, obligationIDs: obligations, asOf: workspace.asOf)
        }
    }
    private var currentObligations: [PropertyObligationSnapshot] {
        (workspace.destination == .household ? workspace.householdMonthlyReport : workspace.reports[propertyID])?.obligations ?? []
    }
    private var grouped: [ReceiptGroup] {
        let sources = Dictionary(workspace.transactionInputs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Dictionary(grouping: applications, by: \.paymentTransactionID)
            .map { ReceiptGroup(id: $0.key, entries: $0.value, source: sources[$0.key]) }
            .sorted { left, right in
                let a = left.source?.postedAt ?? left.entries.first?.sourcePostedAtSnapshot ?? .distantPast
                let b = right.source?.postedAt ?? right.entries.first?.sourcePostedAtSnapshot ?? .distantPast
                return a == b ? left.id.uuidString < right.id.uuidString : a > b
            }
    }
    private var applicationLabels: [UUID: String] {
        var labels: [UUID: String] = [:]
        for close in workspace.ledger.closes where close.propertyID == propertyID {
            for obligation in close.obligations {
                labels[obligation.id] = "\(obligation.title) · \(propertyMonthText(close.monthStart))"
            }
        }
        for obligation in currentObligations where labels[obligation.id] == nil {
            labels[obligation.id] = "\(obligation.title) · \(propertyMonthText(workspace.selectedMonth))"
        }
        return labels
    }
    private var settlement: PropertyMemberSettlement? {
        guard let report = workspace.destination == .household ? workspace.householdMonthlyReport : workspace.reports[propertyID] else { return nil }
        return workspace.memberSettlements(propertyID: propertyID, report: report).first { $0.residentID == residentID }
    }
    private var directContribution: Decimal {
        let report = workspace.destination == .household ? workspace.householdMonthlyReport : workspace.reports[propertyID]
        return report?.residents.first { $0.id == residentID }?.directContribution ?? 0
    }

    var body: some View {
        let receipts = grouped
        let labels = applicationLabels
        return VStack(alignment: .leading, spacing: 16) {
            Text("Member collections").font(.headline)
            Text(residentID == PropertyPaymentAdvance.placeholderResidentID(propertyID: propertyID)
                ? String(localized: "Unassigned older advances")
                : workspace.member(id: residentID)?.name ?? String(localized: "Former member"))
                .font(.subheadline).foregroundStyle(.secondary)
            Text(workspace.title).font(.caption).foregroundStyle(.secondary)
            if let settlement {
                HStack {
                    Text(LocalizedStringKey(settlement.status.title))
                    Spacer()
                    if let due = settlement.due { Text(propertyMoneyText(due)).monospacedDigit() }
                }.font(.callout)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if receipts.isEmpty {
                        Text("No collections recorded for this member.").foregroundStyle(.secondary)
                        if directContribution > 0 {
                            Text("Covered by directly paid expenses · \(propertyMoneyText(directContribution))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(receipts) { group in
                        let id = group.id
                        let entries = group.entries
                        let transaction = group.source
                        let snapshot = entries.first
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(transaction?.description ?? snapshot?.sourceDescriptionSnapshot ?? String(localized: "Transaction unavailable"))
                                    .font(.callout.weight(.medium))
                                Spacer()
                                if let amount = transaction?.amount ?? snapshot?.sourceAmountSnapshot {
                                    Text(propertyMoneyText(abs(amount))).monospacedDigit()
                                }
                            }
                            Text(transaction?.accountName ?? String(localized: "Account unavailable"))
                                .font(.caption).foregroundStyle(.secondary)
                            if let date = transaction?.postedAt ?? snapshot?.sourcePostedAtSnapshot {
                                Text(date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                            }
                            let applied = entries.filter { !PropertyPaymentAdvance.isAdvance($0) }.reduce(Decimal.zero) { $0 + $1.amount }
                            let advance = entries.filter(PropertyPaymentAdvance.isAdvance).reduce(Decimal.zero) { $0 + $1.amount }
                            Text("Applied to member · \(propertyMoneyText(applied))").font(.caption).foregroundStyle(.secondary)
                            if advance > 0 { Text("Available advance · \(propertyMoneyText(advance))").font(.caption).foregroundStyle(.secondary) }
                            if let transaction {
                                if !PropertySettlementCalculator.isValidCollectionPayment(transaction, asOf: .distantFuture)
                                    || entries.contains(where: { application in
                                        PropertySettlementCalculator.hasSourceChanged(amount: application.sourceAmountSnapshot,
                                            postedAt: application.sourcePostedAtSnapshot, currencyCode: application.sourceCurrencySnapshot,
                                            description: application.sourceDescriptionSnapshot, versus: transaction)
                                    }) {
                                    Label("Source changed · review required", systemImage: "exclamationmark.triangle")
                                        .font(.caption).foregroundStyle(.orange)
                                }
                            } else {
                                Label("Source unavailable · historical reference", systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                            ForEach(entries) { application in
                                HStack {
                                    let label = PropertyPaymentAdvance.isAdvance(application) ? String(localized: "Available advance")
                                        : labels[application.obligationID] ?? String(localized: "Obligation")
                                    Text(label)
                                    Spacer()
                                    Text(propertyMoneyText(application.amount)).monospacedDigit()
                                    Button { removalLabel = label; removalID = application.id } label: { Image(systemName: "minus.circle") }
                                        .buttonStyle(.borderless).accessibilityLabel(Text("Remove application: \(label)"))
                                }.font(.caption)
                            }
                            if transaction != nil {
                                Button("Open movement") {
                                    let id = id
                                    let descriptor = FetchDescriptor<Transaction>(predicate: #Predicate<Transaction> { $0.id == id })
                                    do { movement = try modelContext.fetch(descriptor).first }
                                    catch { self.error = error.localizedDescription }
                                }.buttonStyle(.link)
                            }
                        }
                        Divider()
                    }
                }
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            HStack {
                Button("Close") { dismiss() }
            }
        }
        .padding(20).frame(minWidth: 480, idealWidth: 560, minHeight: 280, idealHeight: 420)
        .sheet(item: $movement) { transaction in
            TransactionDetailSheet(transaction: transaction, onCategoryAssigned: { _ in
                Task { await workspace.refreshPeriod(force: true) }
            }, onSaved: { Task { await workspace.refreshPeriod(force: true) } })
        }
        .confirmationDialog("Remove this collection application", isPresented: Binding(
            get: { removalID != nil }, set: { if !$0 { removalID = nil } }), titleVisibility: .visible) {
            Button("Withdraw application", role: .destructive) {
                guard let removalID else { return }
                if !workspace.removeCollectionApplication(id: removalID) { error = workspace.error }
                self.removalID = nil
            }
            Button("Cancel", role: .cancel) { removalID = nil }
        } message: {
            Text("Remove application: \(removalLabel). The original financial transaction is preserved; the amount remains available to reconcile.")
        }
    }
}
