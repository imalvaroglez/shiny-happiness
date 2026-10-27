import SwiftUI

struct PropertyAssignmentDraft: Identifiable {
    let id = UUID()
    var ids: Set<UUID>
    var destination: PropertyDestination
    var month: Date
    var isCustom: Bool
    var members: Set<UUID> = []
    var amount: Decimal = 0
}

struct PropertyAssignmentEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var workspace: PropertyWorkspaceModel
    let draft: PropertyAssignmentDraft
    let residents: [PropertyResident]
    var onSuccess: () -> Void
    @State private var members: Set<UUID>
    @State private var amount: Decimal

    init(workspace: PropertyWorkspaceModel, draft: PropertyAssignmentDraft, residents: [PropertyResident], onSuccess: @escaping () -> Void) {
        self.workspace = workspace; self.draft = draft; self.residents = residents; self.onSuccess = onSuccess
        _members = State(initialValue: draft.members); _amount = State(initialValue: draft.amount)
    }
    var body: some View {
        StandardEditorForm(title: draft.isCustom ? "Custom split" : "Responsible members",
            isValid: draft.isCustom ? amount >= 0 : !members.isEmpty,
            onCancel: { dismiss() }, onSave: {
                guard workspace.destination == draft.destination, workspace.selectedMonth == draft.month else {
                    workspace.error = String(localized: "The selected property or period changed. Reopen the editor."); return
                }
                if workspace.assign(ids: draft.ids, choice: draft.isCustom ? .custom : .group,
                    group: members, customAmount: amount) { onSuccess(); dismiss() }
            }) {
                if draft.isCustom {
                    LabeledContent("Fer’s amount per selected expense") {
                        TextField("MXN", value: $amount, format: .number.precision(.fractionLength(0...2)))
                            .frame(width: 150).monospacedDigit()
                    }
                    Text("Each expense keeps its original total. Your portion is the remainder.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(residents) { resident in
                        Toggle(resident.name, isOn: Binding(get: { members.contains(resident.id) }, set: {
                            if $0 { members.insert(resident.id) } else { members.remove(resident.id) }
                        }))
                    }
                }
                if let error = workspace.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
    }
}
