import SwiftUI
import SwiftData

struct PropertyMemberCollectionSelection: Identifiable {
    var id: UUID
}

/// Detail scopes the member account sheet hands back to its presenter: the
/// sheet never navigates by itself, it dismisses and reports the surface the
/// caller should open next.
enum PropertyAccountDetailScope {
    case sharedCharges
    case memberCharges
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

/// Unbacked exposure the review notes name, mirroring the settlement's own
/// walk over the same ledger and inputs: non-advance collections whose source
/// vanished or changed, and advances that lost their backing. Exposure only —
/// none of this money enters a balance or an availability figure.
struct PropertyMemberCollectionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Bindable var workspace: PropertyWorkspaceModel
    let propertyID: UUID
    let residentID: UUID
    var onShowDetail: ((PropertyAccountDetailScope) -> Void)? = nil
    var registerPayment: (() -> Void)? = nil
    @State private var movement: Transaction?
    @State private var error: String?

    private var report: PropertyMonthlyReport? {
        workspace.destination == .household ? workspace.householdMonthlyReport : workspace.reports[propertyID]
    }
    private var account: PropertyMemberAccount? {
        guard let report else { return nil }
        return workspace.memberAccount(propertyID: propertyID, residentID: residentID, report: report)
    }
    private var displayName: String {
        residentID == PropertyPaymentAdvance.placeholderResidentID(propertyID: propertyID)
            ? String(localized: "Unassigned older advances")
            : workspace.member(id: residentID)?.name ?? String(localized: "Former member")
    }
    var body: some View {
        let account = self.account
        return VStack(alignment: .leading, spacing: 16) {
            Text(String(format: String(localized: "%1$@ — Account as of %2$@"), displayName,
                workspace.asOf.formatted(date: .abbreviated, time: .omitted)))
                .font(.headline)
            HStack(spacing: 4) {
                Text(workspace.title)
                Text("·").foregroundStyle(.tertiary)
                Text(propertyMonthText(workspace.selectedMonth))
                if account?.isProjection == true {
                    Text("·").foregroundStyle(.tertiary)
                    Text("Projection")
                }
            }
            .font(.subheadline).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let account {
                        breakdown(of: account)
                        reviewNotes(for: account)
                    }
                }
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            HStack {
                Button("Register payment") {
                    dismiss()
                    registerPayment?()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20).frame(minWidth: 480, idealWidth: 560, minHeight: 280, idealHeight: 420)
        .sheet(item: $movement) { transaction in
            TransactionDetailSheet(transaction: transaction, onCategoryAssigned: { _ in
                Task { await workspace.refreshPeriod(force: true) }
            }, onSaved: { Task { await workspace.refreshPeriod(force: true) } })
        }
    }

    /// Aligned account breakdown: the member's addends first (share, rent,
    /// individual charges, adjustments, prior debt), then the applied payments
    /// subtracted with an explicit minus, then the balance they reproduce —
    /// the column sums by hand and ends on the number that opens the capture.
    /// A figure the model cannot compute stays «Not yet calculated»; it never
    /// collapses to 0.00.
    private func breakdown(of account: PropertyMemberAccount) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            DetailRow("House shared expenses", alignment: .trailing) {
                HStack(spacing: 8) {
                    Button("View detail") {
                        dismiss()
                        onShowDetail?(.sharedCharges)
                    }.buttonStyle(.link).font(.caption)
                    amountOrPending(account.houseSharedTotal)
                }
            }
            DetailRow("\(displayName)'s share", alignment: .trailing) {
                amountOrPending(account.memberSharedShare)
            }
            DetailRow("Individual charges", alignment: .trailing) {
                HStack(spacing: 8) {
                    Button("View detail") {
                        dismiss()
                        onShowDetail?(.memberCharges)
                    }.buttonStyle(.link).font(.caption)
                    amountOrPending(account.individualCharges)
                }
            }
            if let rent = account.rent, rent > 0 {
                DetailRow("Rent", alignment: .trailing) {
                    Text(propertyMoneyText(rent)).monospacedDigit()
                }
            }
            if account.priorDebt > 0 {
                DetailRow("Prior debt", alignment: .trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(propertyMoneyText(account.priorDebt)).monospacedDigit()
                        if account.priorPaid > 0 {
                            Text("Net of earlier collections").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let adjustments = account.adjustments, adjustments != 0 {
                DetailRow("Adjustments", alignment: .trailing) {
                    Text(propertyMoneyText(adjustments)).monospacedDigit()
                }
            }
            DetailRow("Applied payments", alignment: .trailing) {
                Text(propertyMoneyText(-account.appliedPayments)).monospacedDigit()
            }
            DetailRow("Outstanding balance", alignment: .trailing) {
                if let balance = account.balanceDue {
                    Text(propertyMoneyText(balance)).monospacedDigit()
                } else {
                    Text(LocalizedStringKey(account.status.title)).foregroundStyle(.secondary)
                }
            }
            .font(.callout.weight(.semibold))
            if account.advanceAvailable > 0 {
                DetailRow("Available advance", alignment: .trailing) {
                    Text(propertyMoneyText(-account.advanceAvailable)).monospacedDigit()
                }
                .foregroundStyle(.secondary)
                DetailRow("Suggested payment", alignment: .trailing) {
                    amountOrPending(account.suggestedPayment)
                }
            }
        }
        .font(.callout)
    }

    /// Independent review notes after the table: every unbacked or
    /// over-applied record the account exposes, named and with the movement to
    /// reopen when it still exists. No silent warnings.
    private func reviewNotes(for account: PropertyMemberAccount) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if account.unbackedCollectedMissing > 0 {
                note(String(format: String(localized: "This balance does not discount a previous record of %@ because its movement could not be found."),
                    propertyMoneyText(account.unbackedCollectedMissing)))
            }
            if account.unbackedCollectedChanged > 0 {
                note(String(format: String(localized: "This balance does not discount a previous record of %@ because its movement changed after registration."),
                    propertyMoneyText(account.unbackedCollectedChanged)))
            }
            if account.unbackedAdvances > 0 {
                note(String(format: String(localized: "An advance of %@ lost its backing; it is not available money."),
                    propertyMoneyText(account.unbackedAdvances)),
                    movementID: account.unbackedAdvanceReceiptIDs.first)
            }
            ForEach(account.overallocatedReceiptIDs, id: \.self) { receiptID in
                overallocatedNote(for: receiptID)
            }
        }
    }

    /// One reconciliation-flagged receipt, named by its amount and
    /// description. The receipt exists while reconciliation flags it, so the
    /// button reopens it; the snapshot fallback only names a source that
    /// vanished between both computations.
    private func overallocatedNote(for receiptID: UUID) -> some View {
        let source = workspace.transactionInputs.first { $0.id == receiptID }
        let snapshot = source == nil
            ? workspace.ledger.paymentApplications.first { $0.paymentTransactionID == receiptID } : nil
        let amount = source?.amount ?? snapshot?.sourceAmountSnapshot
        let description = source?.description ?? snapshot?.sourceDescriptionSnapshot
            ?? String(localized: "Transaction unavailable")
        return note(String(format: String(localized: "The collection of %1$@ · %2$@ is applied beyond its amount."),
            amount.map { propertyMoneyText(abs($0)) } ?? "—", description), movementID: source?.id)
    }

    /// One orange caption with the movement to reopen on its trailing edge.
    private func note(_ text: String, movementID: UUID? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text).font(.caption).foregroundStyle(.orange)
            Spacer(minLength: 8)
            if let movementID {
                Button("Open movement") { openMovement(movementID) }
                    .buttonStyle(.link).font(.caption)
            }
        }
    }

    @ViewBuilder
    private func amountOrPending(_ value: Decimal?) -> some View {
        if let value {
            Text(propertyMoneyText(value)).monospacedDigit()
        } else {
            Text("Not yet calculated").foregroundStyle(.secondary)
        }
    }

    private func openMovement(_ id: UUID) {
        let descriptor = FetchDescriptor<Transaction>(predicate: #Predicate<Transaction> { $0.id == id })
        do { movement = try modelContext.fetch(descriptor).first }
        catch { self.error = error.localizedDescription }
    }
}
