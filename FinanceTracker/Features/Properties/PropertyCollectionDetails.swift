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
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: String(localized: "%1$@ — Account as of %2$@"), displayName,
                    workspace.asOf.formatted(date: .abbreviated, time: .omitted)))
                    .font(.headline)
                if account?.isProjection == true {
                    Text("Projection").font(.caption).foregroundStyle(.secondary)
                }
            }
            // Elastic height: the block draws without scrolling while it fits
            // the sheet, and scrolls only once it exceeds it; the cap keeps
            // the sheet from growing without limit.
            ViewThatFits(in: .vertical) {
                collectionsDetail
                ScrollView { collectionsDetail }
            }
            .frame(maxHeight: 520)
            Divider()
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
        .padding(20).frame(minWidth: 480, idealWidth: 560, maxWidth: 680)
        .sheet(item: $movement) { transaction in
            TransactionDetailSheet(transaction: transaction, onCategoryAssigned: { _ in
                Task { await workspace.refreshPeriod(force: true) }
            }, onSaved: { Task { await workspace.refreshPeriod(force: true) } })
        }
    }

    /// Table plus review notes: the exact block the sheet renders without
    /// scrolling while it fits, and scrolls once it no longer does.
    private var collectionsDetail: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let account {
                breakdown(of: account)
                reviewNotes(for: account)
            }
        }
    }

    /// Aligned account breakdown: the member's addends first (share, rent,
    /// individual charges, adjustments, prior debt), then the applied payments
    /// subtracted with an explicit minus, then the balance they reproduce —
    /// the column sums by hand and ends on the number that opens the capture.
    /// Three Grid columns share widths across every row — flexible concept,
    /// trailing monospaced amount, trailing «View detail» action — so amounts
    /// stay aligned however long they get, and rows without an action keep
    /// the column with an empty cell. A figure the model cannot compute stays
    /// «Not yet calculated»; it never collapses to 0.00.
    private func breakdown(of account: PropertyMemberAccount) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
            GridRow {
                concept("House shared expenses")
                amountOrPending(account.houseSharedTotal)
                    .gridCellAnchor(.trailing)
                detailAction(.sharedCharges)
            }
            GridRow {
                concept("\(displayName)'s share")
                amountOrPending(account.memberSharedShare)
                    .gridCellAnchor(.trailing)
                noAction
            }
            GridRow {
                concept("Individual charges")
                amountOrPending(account.individualCharges)
                    .gridCellAnchor(.trailing)
                detailAction(.memberCharges)
            }
            if let rent = account.rent, rent > 0 {
                GridRow {
                    concept("Rent")
                    Text(propertyMoneyText(rent)).monospacedDigit()
                        .gridCellAnchor(.trailing)
                    noAction
                }
            }
            // Shown whenever it exists, negative included: a negative prior
            // debt is a data error this row lets you see, and the visible
            // arithmetic still closes on the balance below.
            if account.priorDebt != 0 {
                GridRow {
                    concept("Prior debt")
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(propertyMoneyText(account.priorDebt)).monospacedDigit()
                        if account.priorPaid > 0 {
                            Text("Net of earlier collections").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .gridCellAnchor(.trailing)
                    noAction
                }
            }
            if let adjustments = account.adjustments, adjustments != 0 {
                GridRow {
                    concept("Adjustments")
                    Text(propertyMoneyText(adjustments)).monospacedDigit()
                        .gridCellAnchor(.trailing)
                    noAction
                }
            }
            // Bounded by the month's own charges when computable: collecting
            // more than the month charged is review work, and the row must
            // still let the column sum by hand to the balance below.
            GridRow {
                concept("Applied payments")
                Text(propertyMoneyText(-account.boundedAppliedPayments)).monospacedDigit()
                    .gridCellAnchor(.trailing)
                noAction
            }
            GridRow {
                Text("Outstanding balance")
                    .font(.callout.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Group {
                    if let balance = account.balanceDue {
                        Text(propertyMoneyText(balance)).monospacedDigit()
                    } else {
                        Text(LocalizedStringKey(account.status.title)).foregroundStyle(.secondary)
                    }
                }
                .font(.callout.weight(.semibold))
                .gridCellAnchor(.trailing)
                noAction
            }
            if account.advanceAvailable > 0 {
                GridRow {
                    concept("Available advance").foregroundStyle(.secondary)
                    Text(propertyMoneyText(-account.advanceAvailable)).monospacedDigit()
                        .foregroundStyle(.secondary)
                        .gridCellAnchor(.trailing)
                    noAction
                }
                GridRow {
                    concept("Suggested payment").foregroundStyle(.secondary)
                    amountOrPending(account.suggestedPayment)
                        .foregroundStyle(.secondary)
                        .gridCellAnchor(.trailing)
                    noAction
                }
            }
        }
        .font(.callout)
    }

    /// Concept column: a flexible, leading-aligned label with room to grow,
    /// so long concepts don't wrap while width remains.
    private func concept(_ title: LocalizedStringKey) -> some View {
        Text(title).frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Action column: the filtered activity behind a figure, after its amount.
    private func detailAction(_ scope: PropertyAccountDetailScope) -> some View {
        Button("View detail") {
            dismiss()
            onShowDetail?(scope)
        }
        .buttonStyle(.link).font(.caption)
        .gridCellAnchor(.trailing)
    }

    /// Empty action cell that keeps the third column present on rows
    /// without an action.
    private var noAction: some View { Color.clear.frame(width: 0) }

    /// Independent review notes after the table: every unbacked or
    /// over-applied record the account exposes, named and with the movement to
    /// reopen when it still exists. No silent warnings.
    private func reviewNotes(for account: PropertyMemberAccount) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if account.unbackedCollectedMissing > 0 {
                note(String(format: String(localized: "This balance does not discount a previous record of %@ because its movement could not be found."),
                    propertyMoneyText(account.unbackedCollectedMissing)))
            }
            ForEach(account.unbackedChangedReceipts, id: \.id) { receipt in
                changedReceiptNote(receipt)
            }
            if account.monthCollectionExcess > 0 {
                note(String(format: String(localized: "Month collections exceed its charges by %@; review required."),
                    propertyMoneyText(account.monthCollectionExcess)))
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

    /// One changed unbacked collection, named by its amount and the fields
    /// that no longer match, leading to the movement that changed: the source
    /// exists, so «Open movement» reopens it. A source that only stopped being
    /// a valid receipt without changing any captured field keeps the sentence
    /// without the parenthetical.
    private func changedReceiptNote(_ receipt: PropertyMemberSettlement.UnbackedReceipt) -> some View {
        let fields = receipt.fields.map(\.displayName).joined(separator: ", ")
        let suffix = fields.isEmpty ? "" : " (\(fields))"
        return note(String(format: String(localized: "This balance does not discount a previous record of %@ because its movement changed after registration%@."),
            propertyMoneyText(receipt.amount), suffix), movementID: receipt.id)
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
