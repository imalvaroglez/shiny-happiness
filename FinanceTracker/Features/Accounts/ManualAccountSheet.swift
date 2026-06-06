import SwiftData
import SwiftUI

struct ManualAccountSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let onCreated: (Account) -> Void

    @State private var kind: ManualAccountKind = .debit
    @State private var name = ""
    @State private var institution = ""
    @State private var accountNumber = ""
    @State private var currency = "MXN"
    @State private var openingAmount: Decimal = 0
    @State private var creditLimit: Decimal = 0
    @State private var openingDate = Date.now
    @State private var tint = Color.accentColor
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 18) {
            Text("Add Account")
                .font(.headline)

            VStack(spacing: 0) {
                row("Type") {
                    Picker("Type", selection: $kind) {
                        ForEach(ManualAccountKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                Divider().padding(.leading, 132)

                row("Name") {
                    TextField("Gold Elite Credit Card", text: $name)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                }
                Divider().padding(.leading, 132)

                row(kind == .loan ? "Lender" : "Institution") {
                    TextField("Institution", text: $institution)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                }
                Divider().padding(.leading, 132)

                row("Number") {
                    TextField("Optional account/card number", text: $accountNumber)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                }
                Divider().padding(.leading, 132)

                row("Currency") {
                    TextField("MXN", text: $currency)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                }
                Divider().padding(.leading, 132)

                row(kind.isLiability ? "Amount Owed" : "Balance") {
                    TextField("0.00", value: $openingAmount, format: .number)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                }

                Divider().padding(.leading, 132)
                row("Opening Date") {
                    DatePicker("", selection: $openingDate, displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.compact)
                }

                if kind == .creditCard {
                    Divider().padding(.leading, 132)
                    row("Credit Limit") {
                        TextField("0.00", value: $creditLimit, format: .number)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                    }
                }

                Divider().padding(.leading, 132)
                row("Color") {
                    ColorPicker("", selection: $tint)
                        .labelsHidden()
                }
            }
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
            )

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
                Button("Create") { create() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onChange(of: kind) {
            if name.isEmpty {
                name = kind.displayName
            }
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label)
                .frame(width: 116, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func create() {
        do {
            let account = try AccountCreationService.create(
                kind: kind,
                name: name,
                institution: institution,
                accountNumber: accountNumber,
                currency: currency,
                openingAmount: openingAmount,
                creditLimit: creditLimit > 0 ? creditLimit : nil,
                tintHex: tint.hexString,
                openedAt: openingDate,
                context: modelContext
            )
            onCreated(account)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
