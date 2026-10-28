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
