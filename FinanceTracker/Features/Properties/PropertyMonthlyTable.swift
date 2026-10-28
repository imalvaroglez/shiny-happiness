import SwiftUI
import Observation

struct PropertyMonthlyMemberRow: Identifiable, Equatable {
    struct ID: Hashable { var member: UUID; var month: Date }
    var memberID: UUID
    var month: Date
    var name: String
    var income: Decimal
    var confirmed: Bool
    var pending: Decimal?
    var historical: Bool
    var share: Decimal? = nil
    var shareIsEstimated = false
    var priorDebt: Decimal = 0
    var advance: Decimal = 0
    var settlement: PropertyMemberSettlement? = nil
    var former = false
    var id: ID { ID(member: memberID, month: month) }

    static func rows(report: PropertyMonthlyReport, visibleIDs: Set<UUID>? = nil,
                     canCalculate: Bool, isClosed: Bool, historical: Bool) -> [Self] {
        let residents = report.residents.filter { visibleIDs?.contains($0.id) ?? true }
        let estimated = !isClosed && residents.contains { !$0.confirmed }
        let shareAvailable = isClosed || residents.reduce(Decimal.zero) { $0 + $1.share } > 0
        return residents.map {
            Self(memberID: $0.id, month: report.monthStart, name: $0.name, income: $0.income,
                 confirmed: $0.confirmed, pending: isClosed || canCalculate ? $0.balance : nil,
                 historical: historical, share: shareAvailable ? $0.share : nil, shareIsEstimated: estimated,
                 priorDebt: $0.priorDebt)
        }
    }
}

enum PropertyMembersLayout {
    static let spacing: CGFloat = 10
    static let name: CGFloat = 100
    static let income: CGFloat = 190
    static let payment: CGFloat = 155
    static let pending: CGFloat = 180
    static let actions: CGFloat = 180
    static var minimumWidth: CGFloat { name + income + payment + pending + actions + spacing * 4 }

    /// Canonical per-column alignments, shared by headers and cells so the
    /// amounts line up across rows regardless of each cell's content. Money
    /// columns are trailing; text columns are leading.
    static let nameAlignment: Alignment = .leading
    static let incomeAlignment: Alignment = .trailing
    static let pendingAlignment: Alignment = .trailing
    static let paymentAlignment: Alignment = .leading
    static let actionsAlignment: Alignment = .leading
}

@MainActor @Observable
private final class PropertyIncomeDraft {
    var text: String
    var savedText: String
    var dirty: Bool { text != savedText }
    init(amount: Decimal) { text = amount.description; savedText = amount.description }
}

@MainActor @Observable
private final class PropertyIncomeDraftStore {
    @ObservationIgnored private var drafts: [PropertyMonthlyMemberRow.ID: PropertyIncomeDraft] = [:]
    func draft(for row: PropertyMonthlyMemberRow) -> PropertyIncomeDraft {
        if let draft = drafts[row.id] { return draft }
        let draft = PropertyIncomeDraft(amount: row.income)
        drafts[row.id] = draft
        return draft
    }
}

struct PropertyMonthlyTable: View {
    var rows: [PropertyMonthlyMemberRow]
    var isClosed: Bool
    var allowsEnd = true
    var legacyAdvance: Decimal = 0
    var legacyAdvancePresent = false
    var legacyAdvanceNeedsReview = false
    var save: (UUID, Decimal, Bool) -> Bool
    var end: (UUID) -> Void
    var openPayments: (UUID) -> Void
    var collect: (UUID) -> Void
    var applyAdvance: (UUID) -> Void
    var openLegacyAdvance: () -> Void
    /// Inline rename hook. Returns false when the name could not be saved;
    /// the row then keeps the draft and surfaces an inline error.
    var rename: (UUID, String) -> Bool = { _, _ in false }
    @State private var drafts = PropertyIncomeDraftStore()
    /// Member whose name is being renamed inline; only one at a time.
    @State private var renamingMemberID: UUID?

    var body: some View {
        PropertyTableCard {
            // One fit decision governs the entire table, including its header.
            ViewThatFits(in: .horizontal) {
                table(compact: false).frame(minWidth: PropertyMembersLayout.minimumWidth)
                table(compact: true)
            }
        }
        .accessibilityLabel("Members and monthly contributions")
    }

    private func table(compact: Bool) -> some View {
        VStack(spacing: 12) {
            Group {
                if compact { Text("Members and contributions").frame(maxWidth: .infinity, alignment: .leading) }
                else {
                    HStack(spacing: PropertyMembersLayout.spacing) {
                        Text("Member").frame(minWidth: PropertyMembersLayout.name, maxWidth: .infinity, alignment: PropertyMembersLayout.nameAlignment)
                        Text("Monthly income").frame(width: PropertyMembersLayout.income, alignment: PropertyMembersLayout.incomeAlignment)
                        Text("To contribute").frame(width: PropertyMembersLayout.pending, alignment: PropertyMembersLayout.pendingAlignment)
                        Text("Payment status").frame(width: PropertyMembersLayout.payment, alignment: PropertyMembersLayout.paymentAlignment)
                        Text("Actions").frame(width: PropertyMembersLayout.actions, alignment: PropertyMembersLayout.actionsAlignment)
                    }
                }
            }.font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            if rows.isEmpty {
                Text("There are no active members in this period.").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(rows) { row in
                Divider()
                PropertyIncomeTableRow(row: row, compact: compact, draft: drafts.draft(for: row), isClosed: isClosed, allowsEnd: allowsEnd,
                    save: { save(row.memberID, $0, $1) }, end: { end(row.memberID) },
                    openPayments: { openPayments(row.memberID) }, collect: { collect(row.memberID) },
                    applyAdvance: { applyAdvance(row.memberID) },
                    rename: { name in rename(row.memberID, name) }, renamingMemberID: $renamingMemberID)
            }
            if legacyAdvancePresent {
                Divider()
                HStack {
                    Text("Unassigned older advances").foregroundStyle(.secondary)
                    Spacer()
                    if legacyAdvanceNeedsReview { Text("Review required").foregroundStyle(.orange) }
                    else { Text(propertyMoneyText(legacyAdvance)).monospacedDigit() }
                    Button("Review", action: openLegacyAdvance).buttonStyle(.link)
                }.font(.caption)
            }
        }
    }
}

private struct PropertyIncomeTableRow: View {
    let row: PropertyMonthlyMemberRow
    var compact: Bool
    @Bindable var draft: PropertyIncomeDraft
    var isClosed: Bool
    var allowsEnd: Bool
    var save: (Decimal, Bool) -> Bool
    var end: () -> Void
    var openPayments: () -> Void
    var collect: () -> Void
    var applyAdvance: () -> Void
    var rename: (String) -> Bool
    @Binding var renamingMemberID: UUID?
    @FocusState private var focused: Bool
    @State private var editingIncome = false
    @State private var renameText = ""
    @State private var renameFailed = false
    @FocusState private var renameFocused: Bool

    private var amount: Decimal? { Decimal(string: draft.text.replacingOccurrences(of: ",", with: ""), locale: Locale(identifier: "en_US_POSIX")) }
    private var valid: Bool { amount.map { $0 >= 0 } ?? false }
    private var isRenaming: Bool { renamingMemberID == row.memberID }

    var body: some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: 10) {
                    HStack { name; Spacer(); income.frame(width: PropertyMembersLayout.income, alignment: PropertyMembersLayout.incomeAlignment) }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: PropertyMembersLayout.spacing) {
                            payment.fixedSize(horizontal: true, vertical: false)
                            Spacer()
                            pending.fixedSize(horizontal: true, vertical: false)
                            actions
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            HStack { payment; Spacer(); pending }
                            actions.frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                }
            } else {
                HStack(spacing: PropertyMembersLayout.spacing) {
                    name.frame(minWidth: PropertyMembersLayout.name, maxWidth: .infinity, alignment: PropertyMembersLayout.nameAlignment)
                    income.frame(width: PropertyMembersLayout.income, alignment: PropertyMembersLayout.incomeAlignment)
                    pending.frame(width: PropertyMembersLayout.pending, alignment: PropertyMembersLayout.pendingAlignment)
                    payment.frame(width: PropertyMembersLayout.payment, alignment: PropertyMembersLayout.paymentAlignment)
                    actions.frame(width: PropertyMembersLayout.actions, alignment: PropertyMembersLayout.actionsAlignment)
                }
            }
        }
        .onAppear { if !draft.dirty { reset() } }
        .onDisappear { if draft.dirty { commit(confirmed: false) } }
        .onChange(of: focused) { _, focus in if !focus && draft.dirty { commit(confirmed: false) } }
        .onChange(of: row.income) { if !focused && !draft.dirty { reset() } }
    }

    private var name: some View {
        VStack(alignment: PropertyMembersLayout.nameAlignment.horizontal, spacing: 3) {
            if isRenaming {
                renameEditor
            } else {
                Text(row.name).font(.callout.weight(.medium))
                if row.former { Text("Participation ended").font(.caption).foregroundStyle(.secondary) }
                if let share = row.share {
                    Text(String(format: String(localized: row.shareIsEstimated ? "Shared split: %@ (estimated)" : "Shared split: %@"), propertyPercentText(share)))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    Text("Split not yet calculated").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
    /// Inline name editor. It replaces the whole name cell — the share and
    /// participation captions step aside — so no other column moves. Enter
    /// or Save commits, Escape or Cancel restores, and a failed rename keeps
    /// the draft with an inline error, mirroring `EditableValueField`.
    private var renameEditor: some View {
        VStack(alignment: PropertyMembersLayout.nameAlignment.horizontal, spacing: 3) {
            HStack(spacing: 6) {
                TextField("Rename member", text: $renameText)
                    .focused($renameFocused)
                    .font(.callout)
                    .onSubmit(commitRename)
                Button("Save", action: commitRename)
                    .buttonStyle(.borderless).font(.caption)
                    .fixedSize(horizontal: true, vertical: false)
                Button("Cancel", action: cancelRename)
                    .buttonStyle(.borderless).font(.caption)
                    .fixedSize(horizontal: true, vertical: false)
            }
            if renameFailed {
                Label("Could not rename. The name is unchanged.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            // Hidden Escape handler inside the row, so it never collides
            // with the cancelAction of a containing sheet.
            Button("Cancel", action: cancelRename)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .onAppear { renameFocused = true }
    }
    private var income: some View {
        VStack(alignment: PropertyMembersLayout.incomeAlignment.horizontal, spacing: 4) {
            if row.former { Text("—").foregroundStyle(.secondary) }
            else if isClosed { Text(propertyMoneyText(row.income)).monospacedDigit() }
            else {
                EditableMoneyField(value: row.income, onCommit: { _ in }, onSave: { value in
                    save(value, true) ? nil : String(localized: "Could not save the income. Try again.")
                }, onBlurSave: { value in
                    save(value, false) ? nil : String(localized: "Could not save the income. Try again.")
                }, fieldLabel: "Monthly income for \(row.name), Mexican pesos",
                    changeAccessibilityLabel: Text("Change monthly income for \(row.name)"),
                    onEditingChange: { editingIncome = $0 })
            }
            if !row.former { status }
        }
    }
    private var status: some View {
        HStack(spacing: 6) {
            if row.confirmed && !draft.dirty && !editingIncome {
                Label("Confirmed", systemImage: "checkmark.circle").foregroundStyle(.secondary)
            } else {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    .help(String(localized: "Estimated reference. Confirm the income to close the month."))
                Button("Confirm") { commit(confirmed: true) }
                    .disabled(!valid || isClosed || editingIncome).buttonStyle(.bordered)
            }
        }.font(.caption)
    }
    private var pending: some View {
        VStack(alignment: PropertyMembersLayout.pendingAlignment.horizontal, spacing: 3) {
            if row.historical { Text("Pending reconciliation") }
            else if let pending = row.pending {
                Text(propertyMoneyText(max(0, pending))).monospacedDigit()
                if pending < 0 { Text("In your favor: \(propertyMoneyText(-pending))").font(.caption).foregroundStyle(.secondary) }
            } else { Text("Not yet calculated").foregroundStyle(.secondary) }
            if row.priorDebt > 0 {
                Text("Prior debt · \(propertyMoneyText(row.priorDebt))").font(.caption).foregroundStyle(.secondary)
            }
            if row.advance > 0 {
                Text("Available advance · \(propertyMoneyText(row.advance))").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var payment: some View {
        VStack(alignment: PropertyMembersLayout.paymentAlignment.horizontal, spacing: 4) {
            if let settlement = row.settlement {
                statusLink(settlement.status, action: openPayments)
                if let payable = settlement.payable, payable > 0 {
                    Button("Register payment", action: collect).buttonStyle(.borderless)
                } else if settlement.status == .toCalculate || settlement.status == .toReconcile {
                    Button("Register payment", action: collect).buttonStyle(.borderless)
                }
                if (settlement.due ?? 0) > 0 && settlement.advanceAvailable > 0 {
                    Button("Apply advance", action: applyAdvance).buttonStyle(.borderless)
                }
            }
        }.font(.caption)
    }
    /// Single styling point for a member's settlement status in the table:
    /// a caption-sized link; settled states step back to secondary; states
    /// that need attention warn in orange like every other warning. Color
    /// stays reserved for actions and warnings.
    @ViewBuilder
    private func statusLink(_ status: PropertyMemberSettlement.Status, action: @escaping () -> Void) -> some View {
        let link = Button(action: action) { Text(LocalizedStringKey(status.title)) }
            .buttonStyle(.link)
            .font(.caption)
        switch status {
        case .toCalculate, .toReconcile, .review: link.foregroundStyle(.orange)
        case .paid, .nothingDue: link.foregroundStyle(.secondary)
        default: link
        }
    }
    private var actions: some View {
        HStack(spacing: 12) {
            if !row.former {
                Button(action: beginRename) { Label("Rename", systemImage: "pencil") }
                    .accessibilityLabel(Text("Rename \(row.name)"))
                    .disabled(isRenaming)
                if allowsEnd {
                    Button(role: .destructive, action: end) { Label("Remove", systemImage: "person.crop.circle.badge.minus") }
                        .accessibilityLabel(Text("Remove \(row.name) from this home"))
                }
            }
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .fixedSize(horizontal: true, vertical: false)
    }
    private func beginRename() {
        renameText = row.name
        renameFailed = false
        renamingMemberID = row.memberID
    }
    private func commitRename() {
        if rename(renameText) {
            renamingMemberID = nil
            renameFailed = false
        } else {
            renameFailed = true
        }
    }
    private func cancelRename() {
        renamingMemberID = nil
        renameFailed = false
    }
    private func reset() { draft.text = row.income.description; draft.savedText = draft.text }
    private func commit(confirmed: Bool) {
        guard let amount, amount >= 0 else { return }
        if save(amount, confirmed) { draft.savedText = draft.text }
    }
}

extension PropertyMemberSettlement.Status {
    var title: String {
        switch self {
        case .pending: "Pending"
        case .partial: "Partially paid"
        case .paid: "Paid"
        case .nothingDue: "Nothing due"
        case .toCalculate: "Not yet calculated"
        case .toReconcile: "Pending reconciliation"
        case .review: "Review required"
        }
    }
}
