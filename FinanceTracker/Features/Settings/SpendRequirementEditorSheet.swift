import SwiftUI

struct SpendRequirementEditorSheet: View {
    let account: Account
    let accounts: [Account]
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var requirement: SpendRequirement?
    @State private var amountText = ""
    @State private var holidayDate = Date.now
    @State private var errorMessage: String?
    @State private var isSaving = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Gasto mínimo").font(.headline)
                    Text(account.displayName).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cerrar") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()

            Group {
                if let requirement {
                    Form {
                        Section("Requisito por ciclo") {
                            Text("La configuración se aplica únicamente a esta tarjeta.")
                                .font(.caption).foregroundStyle(.secondary)
                            Toggle("Activar seguimiento", isOn: Binding(
                                get: { requirement.enabled },
                                set: { self.requirement?.enabled = $0 }
                            ))
                            TextField("Importe mínimo (\(account.currency))", text: $amountText)
                                .textFieldStyle(.roundedBorder)
                            Stepper("Día de corte: \(requirement.statementClosingDay)", value: Binding(
                                get: { requirement.statementClosingDay },
                                set: { self.requirement?.statementClosingDay = $0 }
                            ), in: 1...31)
                            Toggle("Mover al día hábil anterior", isOn: Binding(
                                get: { requirement.adjustToPreviousBusinessDay },
                                set: { self.requirement?.adjustToPreviousBusinessDay = $0 }
                            ))
                        }
                        Section("Días inhábiles adicionales") {
                            DatePicker("Fecha", selection: $holidayDate, displayedComponents: .date)
                            Button("Agregar fecha") { addHolidayDate() }
                            ForEach(requirement.additionalNonBusinessDates.sorted(), id: \.self) { date in
                                HStack {
                                    Text(date)
                                    Spacer()
                                    Button("Eliminar", systemImage: "trash", role: .destructive) {
                                        self.requirement?.additionalNonBusinessDates.removeAll { $0 == date }
                                    }
                                    .labelStyle(.iconOnly)
                                }
                            }
                        }
                    }
                    .formStyle(.grouped)
                } else if let errorMessage {
                    ContentUnavailableView("Configuración no disponible", systemImage: "exclamationmark.triangle",
                                            description: Text(errorMessage))
                } else {
                    ProgressView("Cargando configuración…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(.horizontal, 10)

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18)
            }

            Divider()
            HStack {
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Guardar") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(requirement == nil || isSaving)
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 440, minHeight: 480)
        .task { load() }
    }

    private func load() {
        guard requirement == nil else { return }
        do {
            let settings = try SpendRequirementStore.bootstrapSuggestions(accounts: accounts)
            let current = settings.requirements.first { $0.accountID == account.id }
                ?? SpendRequirement.suggested(for: account)
                ?? SpendRequirement(accountID: account.id, name: "Gasto mínimo", amount: 0,
                                    currency: account.currency, statementClosingDay: account.statementDayOfMonth ?? 1,
                                    adjustToPreviousBusinessDay: true)
            requirement = current
            amountText = NSDecimalNumber(decimal: current.amount).stringValue
        } catch {
            errorMessage = "No se pudo leer la configuración: \(error.localizedDescription)"
        }
    }

    private func addHolidayDate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = MexicoBankingCalendar.timeZone
        let value = MexicoBankingCalendar.isoDate(holidayDate, calendar: calendar)
        guard var requirement, !requirement.additionalNonBusinessDates.contains(value) else { return }
        requirement.additionalNonBusinessDates.append(value)
        self.requirement = requirement
    }

    private func save() {
        guard var requirement,
              let amount = Decimal(string: amountText, locale: .current) else {
            errorMessage = "Escribe un importe válido."
            return
        }
        requirement.amount = amount
        requirement.currency = account.currency
        guard requirement.validate().isEmpty else {
            errorMessage = requirement.validate().joined(separator: " ")
            return
        }
        isSaving = true
        do {
            requirement.lastModifiedAt = .now
            try SpendRequirementStore.save(requirement)
            onSave()
            dismiss()
        } catch {
            isSaving = false
            errorMessage = error.localizedDescription
        }
    }
}
