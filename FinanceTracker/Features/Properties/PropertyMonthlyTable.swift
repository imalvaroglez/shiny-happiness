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
    static let income: CGFloat = 150
    static let status: CGFloat = 145
    static let pending: CGFloat = 180
    static let actions: CGFloat = 180
    static var minimumWidth: CGFloat { name + income + status + pending + actions + spacing * 4 }
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
    var save: (UUID, Decimal, Bool) -> Bool
    var edit: (UUID) -> Void
    var end: (UUID) -> Void
    @State private var drafts = PropertyIncomeDraftStore()

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
                        Text("Member").frame(minWidth: PropertyMembersLayout.name, maxWidth: .infinity, alignment: .leading)
                        Text("Monthly income").frame(width: PropertyMembersLayout.income, alignment: .leading)
                        Text("Status").frame(width: PropertyMembersLayout.status, alignment: .leading)
                        Text("To contribute").frame(width: PropertyMembersLayout.pending, alignment: .trailing)
                        Text("Actions").frame(width: PropertyMembersLayout.actions)
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
                    save: { save(row.memberID, $0, $1) }, edit: { edit(row.memberID) }, end: { end(row.memberID) })
            }
            if legacyAdvance > 0 {
                Divider()
                HStack {
                    Text("Unassigned older advances").foregroundStyle(.secondary)
                    Spacer()
                    Text(propertyMoneyText(legacyAdvance)).monospacedDigit()
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
    var edit: () -> Void
    var end: () -> Void
    @FocusState private var focused: Bool

    private var amount: Decimal? { Decimal(string: draft.text.replacingOccurrences(of: ",", with: ""), locale: Locale(identifier: "en_US_POSIX")) }
    private var valid: Bool { amount.map { $0 >= 0 } ?? false }

    var body: some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: 10) {
                    HStack { name; Spacer(); income.frame(width: PropertyMembersLayout.income) }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: PropertyMembersLayout.spacing) {
                            status.fixedSize(horizontal: true, vertical: false)
                            Spacer()
                            pending.fixedSize(horizontal: true, vertical: false)
                            actions
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            HStack { status; Spacer(); pending }
                            actions.frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                }
            } else {
                HStack(spacing: PropertyMembersLayout.spacing) {
                    name.frame(minWidth: PropertyMembersLayout.name, maxWidth: .infinity, alignment: .leading)
                    income.frame(width: PropertyMembersLayout.income)
                    status.frame(width: PropertyMembersLayout.status, alignment: .leading)
                    pending.frame(width: PropertyMembersLayout.pending, alignment: .trailing)
                    actions.frame(width: PropertyMembersLayout.actions)
                }
            }
        }
        .onAppear { if !draft.dirty { reset() } }
        .onDisappear { if draft.dirty { commit(confirmed: false) } }
        .onChange(of: focused) { _, focus in if !focus && draft.dirty { commit(confirmed: false) } }
        .onChange(of: row.income) { if !focused && !draft.dirty { reset() } }
    }

    private var name: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.name).font(.callout.weight(.medium))
            if let share = row.share {
                Text(String(format: String(localized: row.shareIsEstimated ? "Shared split: %@ (estimated)" : "Shared split: %@"), propertyPercentText(share)))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            } else {
                Text("Split not yet calculated").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var income: some View {
        HStack(spacing: 4) {
            Text("$").foregroundStyle(.secondary)
            TextField("MXN", text: $draft.text).textFieldStyle(.roundedBorder).monospacedDigit().focused($focused)
                .accessibilityLabel(Text("Monthly income for \(row.name), Mexican pesos"))
                .onSubmit { commit(confirmed: true) }
            Text("MXN").font(.caption2).foregroundStyle(.secondary)
        }.disabled(isClosed)
    }
    private var status: some View {
        HStack(spacing: 6) {
            if row.confirmed && !draft.dirty {
                Label("Confirmed", systemImage: "checkmark.circle").foregroundStyle(.secondary)
            } else {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    .help(String(localized: "Estimated reference. Confirm the income to close the month."))
                Button("Confirm") { commit(confirmed: true) }
                    .disabled(!valid || isClosed).buttonStyle(.bordered)
            }
        }.font(.caption)
    }
    private var pending: some View {
        VStack(alignment: .trailing, spacing: 3) {
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
    private var actions: some View {
        HStack(spacing: 12) {
            Button(action: edit) { Label("Rename", systemImage: "pencil") }
                .accessibilityLabel(Text("Rename \(row.name)"))
            if allowsEnd {
                Button(role: .destructive, action: end) { Label("Remove", systemImage: "person.crop.circle.badge.minus") }
                    .accessibilityLabel(Text("Remove \(row.name) from this home"))
            }
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .fixedSize(horizontal: true, vertical: false)
    }
    private func reset() { draft.text = row.income.description; draft.savedText = draft.text }
    private func commit(confirmed: Bool) {
        guard let amount, amount >= 0 else { return }
        if save(amount, confirmed) { draft.savedText = draft.text }
    }
}
