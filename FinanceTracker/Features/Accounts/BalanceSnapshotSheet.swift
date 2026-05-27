import SwiftData
import SwiftUI

struct BalanceSnapshotSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let account: Account
    let onSaved: () -> Void

    @State private var date = Date.now
    @State private var amount: Decimal = 0
    @State private var note = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 18) {
            Text("Add Balance Snapshot")
                .font(.headline)

            VStack(spacing: 0) {
                row("Account") {
                    Text(account.displayName)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Divider().padding(.leading, 132)

                row("Date") {
                    DatePicker("", selection: $date, displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.compact)
                }
                Divider().padding(.leading, 132)

                row(account.type.isLiability ? "Amount Owed" : "Balance") {
                    HStack(spacing: 8) {
                        TextField("0.00", value: $amount, format: .number)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                        Text(account.currency)
                            .foregroundStyle(.secondary)
                    }
                }
                Divider().padding(.leading, 132)

                row("Note") {
                    TextField("Optional", text: $note)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                }
            }
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label).frame(width: 116, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func save() {
        do {
            _ = try BalanceSnapshotService.createAdjustment(
                account: account,
                date: date,
                displayAmount: amount,
                note: note,
                context: modelContext
            )
            onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
