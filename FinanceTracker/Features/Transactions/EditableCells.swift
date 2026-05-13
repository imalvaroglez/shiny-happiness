import SwiftUI

/// A tap-to-edit text cell. Tapping reveals a popover with a TextField that
/// commits on Return or when the popover dismisses. The bound value is updated
/// in-place on the @Model object; persistence is the caller's responsibility.
struct EditableTextCell: View {
    let initialText: String
    let placeholder: String
    let commit: (String) -> Void

    @State private var isEditing = false
    @State private var draft = ""

    var body: some View {
        Button {
            draft = initialText
            isEditing = true
        } label: {
            Text(initialText.isEmpty ? placeholder : initialText)
                .font(.body)
                .foregroundStyle(initialText.isEmpty ? Color.secondary : Color.primary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isEditing) {
            VStack(alignment: .leading, spacing: 8) {
                TextField(placeholder, text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 280, idealWidth: 320)
                    .onSubmit { save() }
                HStack {
                    Button("Cancel") { isEditing = false }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Save") { save() }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
        }
    }

    private func save() {
        commit(draft)
        isEditing = false
    }
}

/// Tap-to-edit date cell. Uses a DatePicker inside a popover.
struct EditableDateCell: View {
    let date: Date
    let commit: (Date) -> Void

    @State private var isEditing = false
    @State private var draft: Date = .now

    var body: some View {
        Button {
            draft = date
            isEditing = true
        } label: {
            Text(date, format: .dateTime.day().month(.abbreviated).year())
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isEditing) {
            VStack(alignment: .leading, spacing: 8) {
                DatePicker("Date", selection: $draft, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                HStack {
                    Button("Cancel") { isEditing = false }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Save") {
                        commit(draft)
                        isEditing = false
                    }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
            .frame(minWidth: 320)
        }
    }
}

/// Tap-to-edit money cell. Stores Decimal. Tapping reveals a popover with a
/// numeric TextField; positive/negative is the user's responsibility.
struct EditableAmountCell: View {
    let amount: Decimal
    let currencyCode: String
    let commit: (Decimal) -> Void

    @State private var isEditing = false
    @State private var draft = ""

    var body: some View {
        Button {
            draft = Self.decimalString(amount)
            isEditing = true
        } label: {
            Text(Self.formatMoney(amount, currencyCode: currencyCode))
                .font(.body.bold().monospacedDigit())
                .foregroundStyle(amount >= 0 ? Color.green : Color.red)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isEditing) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Amount")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("0.00", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 180)
                    .onSubmit { save() }
                Text("Positive = money in, negative = money out")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                HStack {
                    Button("Cancel") { isEditing = false }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Save") { save() }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
        }
    }

    private func save() {
        if let value = Decimal(string: draft.replacingOccurrences(of: ",", with: "")) {
            commit(value)
        }
        isEditing = false
    }

    private static let _decimalFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        f.usesGroupingSeparator = false
        return f
    }()

    private static func decimalString(_ amount: Decimal) -> String {
        _decimalFormatter.string(from: amount as NSDecimalNumber) ?? "\(amount)"
    }

    private static let _moneyFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        return f
    }()

    static func formatMoney(_ amount: Decimal, currencyCode: String) -> String {
        _moneyFormatter.currencyCode = currencyCode
        return _moneyFormatter.string(from: amount as NSDecimalNumber) ?? "$0.00"
    }
}
