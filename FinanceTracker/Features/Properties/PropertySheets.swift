import SwiftUI

struct PropertyNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    var onSave: (String) -> Bool
    var body: some View {
        Form {
            TextField("Property name", text: $name)
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Save") { if onSave(name.trimmingCharacters(in: .whitespacesAndNewlines)) { dismiss() } }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(20).frame(width: 380).navigationTitle("New property")
    }
}

struct PropertyResidentSheet: View {
    @Environment(\.dismiss) private var dismiss
    let property: PropertyRecord
    let defaultMonth: Date
    @State private var name = ""
    @State private var activeFrom: Date
    @State private var reference: Decimal = 0
    var onSave: (PropertyResident) -> Bool
    init(property: PropertyRecord, defaultMonth: Date, onSave: @escaping (PropertyResident) -> Bool) {
        self.property = property; self.defaultMonth = defaultMonth; self.onSave = onSave
        _activeFrom = State(initialValue: defaultMonth)
    }
    var body: some View {
        Form {
            TextField("Name", text: $name)
            DatePicker("Resident since", selection: $activeFrom, displayedComponents: .date)
            TextField("Reference monthly income", value: $reference, format: .number)
            Text("The reference is an estimate. Confirm the actual income in the month table.").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Add") {
                if onSave(PropertyResident(propertyID: property.id, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                    activeFrom: activeFrom, referenceMonthlyIncome: reference)) { dismiss() }
            }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || reference < 0) }
        }.padding(20).frame(width: 420).navigationTitle("Add resident")
    }
}

struct PropertyResidentRenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var saveError: String?
    @FocusState private var nameFocused: Bool
    var errorMessage: () -> String?
    var onSave: (String) -> Bool

    init(name: String, errorMessage: @escaping () -> String? = { nil }, onSave: @escaping (String) -> Bool) {
        _name = State(initialValue: name)
        self.errorMessage = errorMessage
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Rename member").font(.title2.bold())
            TextField("Name", text: $name).textFieldStyle(.roundedBorder).focused($nameFocused)
            if let saveError { Text(saveError).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    if onSave(name.trimmingCharacters(in: .whitespacesAndNewlines)) { dismiss() }
                    else { saveError = errorMessage() ?? String(localized: "Could not save the member. Try again.") }
                }.keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 420)
            .onAppear { nameFocused = true }
    }
}

struct PropertyRentSheet: View {
    @Environment(\.dismiss) private var dismiss
    let propertyID: UUID
    let month: Date
    @State private var amount: Decimal
    @State private var effectiveMonth: Date
    var onSave: (PropertyRentAgreement) -> Bool
    init(propertyID: UUID, month: Date, currentAmount: Decimal, onSave: @escaping (PropertyRentAgreement) -> Bool) {
        self.propertyID = propertyID; self.month = month; self.onSave = onSave
        _amount = State(initialValue: currentAmount)
        _effectiveMonth = State(initialValue: month)
    }
    var body: some View {
        Form {
            TextField("Monthly rent", value: $amount, format: .number)
            DatePicker("Effective from", selection: $effectiveMonth, displayedComponents: .date)
            Text("Changes do not modify already-closed months.").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Save") {
                if onSave(PropertyRentAgreement(propertyID: propertyID, monthlyAmount: amount, effectiveMonth: effectiveMonth)) { dismiss() }
            }.disabled(amount < 0) }
        }.padding(20).frame(width: 400).navigationTitle("Rent agreement")
    }
}

struct PropertyServiceSheet: View {
    @Environment(\.dismiss) private var dismiss
    let propertyID: UUID
    @State private var budgetID: UUID?
    @State private var name: String
    @State private var frequency: PropertyServiceFrequency
    @State private var monthlyReference: Decimal
    var onSave: (PropertyServiceBudget) -> Bool
    init(propertyID: UUID, budget: PropertyServiceBudget? = nil,
         onSave: @escaping (PropertyServiceBudget) -> Bool) {
        self.propertyID = propertyID; self.onSave = onSave
        _budgetID = State(initialValue: budget?.id)
        _name = State(initialValue: budget?.name ?? "")
        _frequency = State(initialValue: budget?.frequency ?? .monthly)
        _monthlyReference = State(initialValue: budget?.monthlyReference ?? 0)
    }
    var body: some View {
        Form {
            TextField("Service", text: $name)
            Picker("Frequency", selection: $frequency) {
                ForEach(PropertyServiceFrequency.allCases) { value in Text(value.localizedTitle).tag(value) }
            }
            TextField("Monthly reference", value: $monthlyReference, format: .number)
            Text("This budget creates no charges. Register and link each real payment in Transactions.").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button(budgetID == nil ? "Add" : "Save") {
                if onSave(PropertyServiceBudget(id: budgetID ?? UUID(), propertyID: propertyID,
                    name: name.trimmingCharacters(in: .whitespacesAndNewlines), frequency: frequency,
                    monthlyReference: monthlyReference, updatedAt: .now)) { dismiss() }
            }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || monthlyReference < 0) }
        }.padding(20).frame(width: 430).navigationTitle(budgetID == nil ? "Estimated service" : "Edit service")
    }
}

struct PropertyAttributionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let property: PropertyRecord
    let month: Date
    let residents: [PropertyResident]
    let programs: [PropertyMaintenanceProgram]
    let transactions: [PropertyTransactionInput]
    @State private var transactionID: UUID?
    @State private var kind: PropertyExpenseKind = .operation
    @State private var responsibility: ResponsibilityChoice = .shared
    @State private var residentID: UUID?
    @State private var selectedResidentIDs: Set<UUID> = []
    @State private var maintenanceProgramID: UUID?
    @State private var notes = ""
    @State private var hasCoverage = false
    @State private var coverageStart: Date
    @State private var coverageEnd: Date
    var onSave: (PropertyTransactionAttribution) -> Bool
    private var selectedInput: PropertyTransactionInput? { transactions.first { $0.id == transactionID } }
    init(property: PropertyRecord, month: Date, residents: [PropertyResident],
         programs: [PropertyMaintenanceProgram], transactions: [PropertyTransactionInput],
         onSave: @escaping (PropertyTransactionAttribution) -> Bool) {
        self.property = property; self.month = month; self.residents = residents
        self.programs = programs; self.transactions = transactions; self.onSave = onSave
        _coverageStart = State(initialValue: month)
        _coverageEnd = State(initialValue: month)
    }
    var body: some View {
        Form {
            Picker("Transaction", selection: $transactionID) {
                Text("Choose a transaction").tag(UUID?.none)
                ForEach(transactions) { input in
                    Text("\(input.postedAt.formatted(date: .abbreviated, time: .omitted)) · \(input.description) · \(propertyMoneyText(abs(input.amount)))")
                        .tag(UUID?.some(input.id))
                }
            }
            Picker("Type", selection: $kind) {
                Text("Operation").tag(PropertyExpenseKind.operation)
                Text("Maintenance").tag(PropertyExpenseKind.maintenance)
                Text("Other").tag(PropertyExpenseKind.other)
            }
            if kind == .maintenance, !programs.isEmpty {
                Picker("Maintenance program", selection: $maintenanceProgramID) {
                    Text("No program").tag(UUID?.none)
                    ForEach(programs) { program in
                        Text("\(propertyMonthText(program.startsAt))–\(propertyMonthText(program.endsAt))")
                            .tag(UUID?.some(program.id))
                    }
                }
            }
            Picker("Responsibility", selection: $responsibility) {
                Text("Shared · everyone").tag(ResponsibilityChoice.shared)
                Text("Individual").tag(ResponsibilityChoice.individual)
                Text("Among selected members").tag(ResponsibilityChoice.selected)
                Text("Owner").tag(ResponsibilityChoice.owner)
            }
            if responsibility == .individual {
                Picker("Member", selection: $residentID) {
                    ForEach(residents) { Text($0.name).tag(UUID?.some($0.id)) }
                }
            }
            if responsibility == .selected {
                ForEach(residents) { resident in
                    Toggle(resident.name, isOn: Binding(get: { selectedResidentIDs.contains(resident.id) }, set: { isOn in
                        if isOn { selectedResidentIDs.insert(resident.id) } else { selectedResidentIDs.remove(resident.id) }
                    }))
                }
            }
            Toggle("Indicate period covered by the receipt", isOn: $hasCoverage)
            if hasCoverage {
                DatePicker("From", selection: $coverageStart, displayedComponents: .date)
                DatePicker("Through", selection: $coverageEnd, displayedComponents: .date)
            }
            TextField("Notes", text: $notes)
            if selectedInput != nil, Calendar.current.component(.month, from: selectedInput!.postedAt) != Calendar.current.component(.month, from: month) {
                Label("The transaction settles in the month of its date.", systemImage: "info.circle").font(.caption)
            }
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Link") {
                guard let transactionID else { return }
                let ownerDefault = kind == .maintenance && responsibility == .shared
                let resolved: PropertyResponsibility
                if ownerDefault { resolved = .owner }
                else {
                    switch responsibility {
                    case .shared: resolved = .shared
                    case .individual: guard let residentID else { return }; resolved = .individual(residentID: residentID)
                    case .selected: resolved = .selected(residentIDs: selectedResidentIDs.sorted { $0.uuidString < $1.uuidString })
                    case .owner: resolved = .owner
                    }
                }
                if onSave(PropertyTransactionAttribution(propertyID: property.id, transactionID: transactionID,
                    kind: kind, responsibility: resolved, coverageStart: hasCoverage ? coverageStart : nil,
                    coverageEnd: hasCoverage ? coverageEnd : nil, maintenanceProgramID: maintenanceProgramID, notes: notes)) { dismiss() }
            }.disabled(transactionID == nil || (responsibility == .individual && residentID == nil)
                || (responsibility == .selected && selectedResidentIDs.isEmpty)
                || (hasCoverage && coverageStart > coverageEnd)) }
        }
        .padding(20).frame(width: 600, height: 460).navigationTitle("Link transaction")
        .onChange(of: kind) { if kind == .maintenance && responsibility == .shared { responsibility = .owner } }
    }
}

enum ResponsibilityChoice: String, CaseIterable, Identifiable { case shared, individual, selected, owner; var id: String { rawValue } }

struct PropertyAdjustmentSheet: View {
    @Environment(\.dismiss) private var dismiss
    let propertyID: UUID
    let month: Date
    let residents: [PropertyResidentReport]
    @State private var residentID: UUID?
    @State private var amount: Decimal = 0
    @State private var reason = ""
    var onSave: (PropertyAdjustment) -> Bool
    var body: some View {
        Form {
            Picker("Member", selection: $residentID) {
                Text("Distribute by income").tag(UUID?.none)
                ForEach(residents) { Text($0.name).tag(UUID?.some($0.id)) }
            }
            TextField("Amount (negative for credit)", value: $amount, format: .number)
            TextField("Reason", text: $reason)
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Save") {
                if onSave(PropertyAdjustment(propertyID: propertyID, monthStart: month, residentID: residentID,
                    amount: amount, reason: reason)) { dismiss() }
            }.disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(20).frame(width: 430).navigationTitle("Period adjustment")
    }
}

struct PropertyMaintenanceSheet: View {
    @Environment(\.dismiss) private var dismiss
    let propertyID: UUID
    @State private var startsAt = Calendar.current.propertyMonthStart(for: .now)
    @State private var endsAt = Calendar.current.date(byAdding: .month, value: 11,
        to: Calendar.current.propertyMonthStart(for: .now)) ?? .now
    @State private var budget: Decimal = 24_000
    @State private var monthlyLimit: Decimal = 2_000
    var onSave: (PropertyMaintenanceProgram) -> Bool
    var body: some View {
        StandardEditorForm(title: "Maintenance program", isValid: budget >= 0 && monthlyLimit >= 0 && startsAt <= endsAt,
            onCancel: { dismiss() }, onSave: {
                if onSave(PropertyMaintenanceProgram(propertyID: propertyID, startsAt: startsAt, endsAt: endsAt,
                    budget: budget, monthlyRecoveryLimit: monthlyLimit)) { dismiss() }
            }) {
                DatePicker("Start", selection: $startsAt, displayedComponents: .date)
                DatePicker("End", selection: $endsAt, displayedComponents: .date)
                LabeledContent("Investment budget") {
                    TextField("MXN", value: $budget, format: .currency(code: "MXN").locale(Locale(identifier: "es-MX")))
                        .frame(width: 170)
                }
                LabeledContent {
                    TextField("MXN", value: $monthlyLimit, format: .currency(code: "MXN").locale(Locale(identifier: "es-MX")))
                        .frame(width: 170)
                } label: {
                    Text("Maximum recovery per month").fixedSize(horizontal: false, vertical: true)
                }
                Text("The budget helps planning. Only linked expenses count as actual investment.")
                    .font(.caption).foregroundStyle(.secondary)
            }
    }
}

struct PropertyReserveSheet: View {
    @Environment(\.dismiss) private var dismiss
    let propertyID: UUID
    @State private var amount: Decimal = 0
    @State private var reason = ""
    var onSave: (PropertyReserveMovement) -> Bool
    var body: some View {
        Form {
            TextField("Amount (negative to withdraw)", value: $amount, format: .number)
            TextField("Reason", text: $reason)
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Save") {
                if onSave(PropertyReserveMovement(id: UUID(), propertyID: propertyID, amount: amount,
                    reason: reason, createdAt: .now, deletedAt: nil)) { dismiss() }
            }.disabled(amount == 0 || reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(20).frame(width: 400).navigationTitle("Reserve movement")
    }
}
