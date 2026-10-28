import SwiftData
import SwiftUI

struct CategoryChange {
    let transaction: Transaction
    let category: Category
    let keyword: String?
}

struct TransactionDetailSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let transaction: Transaction
    let onCategoryAssigned: (CategoryChange) -> Void
    var onSaved: (() -> Void)? = nil
    @State private var displayMode: DetailDisplayMode
    @State private var originalRevision: Date
    @State private var originalAccountID: UUID?
    @State private var completion = TransactionEditCompletion()
    @State private var savedBalanceMirror = false

    @State private var draftDate: Date
    @State private var draftDescription: String
    @State private var draftAbsoluteAmount: Decimal
    @State private var draftSignedAmount: Decimal
    @State private var draftFlowKind: TransactionFlowKind
    @State private var draftTreatmentKind: TransactionTreatmentKind
    @State private var draftExpenseAssignment: ExpenseAssignment
    @State private var draftCustomFerAmount: Decimal?
    @State private var draftSettlementNotes: String
    @State private var draftIncluded: Bool
    @State private var draftCategory: Category?
    @State private var showingCategoryPicker = false
    @State private var promotionsModel = PromotionLedgerViewModel()
    @State private var categoryTintTick = 0
    @State private var draftPromotionIDs: Set<UUID> = []
    @State private var originalPromotionIDs: Set<UUID> = []
    @State private var propertyLedger = PropertyLedger()
    @State private var propertySourceAtOpen: PropertyTransactionInput?
    @State private var draftPropertyID: UUID?
    @State private var draftPropertyKind: PropertyExpenseKind = .operation
    @State private var draftPropertyResponsibility: PropertyCaptureResponsibility = .shared
    @State private var draftPropertyResidentID: UUID?
    @State private var draftSelectedPropertyResidents: Set<UUID> = []
    @State private var draftMaintenanceProgramID: UUID?
    @State private var propertySaveError: String?

    @State private var pendingKeyword: String?
    @State private var categoryDidChange = false

    private var isKindEditable: Bool {
        transaction.source == .manual
        && !transaction.isTransfer
        && transaction.account?.type == .creditCard
        && !isBalanceMirror
    }

    private var isBalanceMirror: Bool {
        BalanceSnapshotService.mirroredSnapshot(for: transaction, context: modelContext) != nil
    }

    private var isSettlementEditable: Bool {
        !isBalanceMirror && HouseholdSettlementReportService.isSettlementEligible(transaction)
    }

    private var customSplitInvalid: Bool {
        draftExpenseAssignment == .custom && customSplitError != nil
    }

    private var customSplitError: String? {
        guard isSettlementEditable, draftExpenseAssignment == .custom else { return nil }
        guard let amount = draftCustomFerAmount else { return "Enter Fer's portion." }
        if amount < 0 { return "Fer’s portion cannot be negative." }
        if amount > abs(displayAmount) { return "Fer’s portion cannot exceed the original amount." }
        if amount != amount.currencyRounded { return "Use no more than two decimal places." }
        return nil
    }

    private var customUserAmount: Decimal? {
        guard customSplitError == nil, let ferAmount = draftCustomFerAmount else { return nil }
        return abs(displayAmount) - ferAmount
    }

    init(transaction: Transaction, onCategoryAssigned: @escaping (CategoryChange) -> Void,
         onSaved: (() -> Void)? = nil, initialMode: DetailDisplayMode = .consult) {
        self.transaction = transaction
        self.onCategoryAssigned = onCategoryAssigned
        self.onSaved = onSaved
        _displayMode = State(initialValue: initialMode)
        _originalRevision = State(initialValue: transaction.lastModifiedAt)
        _originalAccountID = State(initialValue: transaction.account?.id)
        _draftDate = State(initialValue: transaction.postedAt)
        _draftDescription = State(initialValue: transaction.descriptionRaw)
        _draftAbsoluteAmount = State(initialValue: abs(transaction.amount))
        _draftSignedAmount = State(initialValue: transaction.amount)
        _draftFlowKind = State(initialValue: transaction.flowKind)
        _draftTreatmentKind = State(initialValue: transaction.treatmentKind)
        _draftExpenseAssignment = State(initialValue: transaction.expenseAssignment)
        _draftCustomFerAmount = State(initialValue: transaction.customFerAmount)
        _draftSettlementNotes = State(initialValue: transaction.settlementNotes ?? "")
        _draftCategory = State(initialValue: transaction.category)
        _draftIncluded = State(initialValue: transaction.isIncludedInHouseholdSettlement)
    }

    var body: some View {
        VStack(spacing: 18) {
            header
            summaryHeader
            if displayMode == .consult { consultationPanel } else { editPanel.disabled(completion.movementSaved) }
            footer
        }
        .padding(24)
        .frame(width: 600)
        .onChange(of: draftExpenseAssignment) {
            if draftExpenseAssignment == .custom, draftCustomFerAmount == nil {
                draftCustomFerAmount = (abs(displayAmount) / 2).currencyRounded
            }
        }
        .onChange(of: draftPropertyKind) {
            if draftPropertyKind == .maintenance { draftPropertyResponsibility = .owner }
        }
        .onChange(of: draftPropertyID) { if draftPropertyID != nil { draftIncluded = false } }
        .onChange(of: draftIncluded) { if draftIncluded { draftPropertyID = nil } }
        .task {
            promotionsModel.reload(context: modelContext, includeTransactions: false)
            originalPromotionIDs = attributedPromotionIDs
            draftPromotionIDs = originalPromotionIDs
            loadPropertyDraft()
        }
        .onReceive(NotificationCenter.default.publisher(for: PromotionLedgerStore.didChangeNotification)) { _ in
            promotionsModel.scheduleReload(context: modelContext, includeTransactions: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: CategoryCustomizationStore.didChangeNotification)) { _ in
            categoryTintTick &+= 1
        }
        .sheet(isPresented: $showingCategoryPicker) {
            CategoryPickerView(transaction: transaction) { category, keyword in
                draftCategory = category
                pendingKeyword = keyword
                categoryDidChange = true
            }
        }
    }

    private var header: some View {
        Text("Transaction Details")
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private var displayAmount: Decimal {
        if isKindEditable {
            return kindDerivedSignedAmount
        }
        return draftSignedAmount
    }

    private var kindDerivedSignedAmount: Decimal {
        switch draftFlowKind {
        case .charge, .expense: return -abs(draftAbsoluteAmount)
        default: return abs(draftAbsoluteAmount)
        }
    }

    private var summaryHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            Circle()
                .fill(categoryColor.opacity(0.18))
                .overlay {
                    Circle()
                        .fill(categoryColor)
                        .frame(width: 8, height: 8)
                }
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 4) {
                Text(primaryLabel)
                    .font(.headline)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !metadataParts.isEmpty {
                    Text(metadataParts.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 16)

            Text(MoneyFormat.string(displayAmount, code: transaction.currency))
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(displayAmount >= 0 ? .green : .red)
                .lineLimit(1)
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    private var editPanel: some View {
        VStack(spacing: 0) {
            editRow("Statement Date") {
                DatePicker("", selection: $draftDate, displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            panelDivider

            editRow("Description") {
                TextField("Description", text: $draftDescription, axis: .vertical)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(1...3)
            }
            panelDivider

            if isKindEditable {
                kindRow
                panelDivider
            }

            editRow("Amount") {
                HStack(spacing: 8) {
                    if isKindEditable {
                        TextField("Amount", value: $draftAbsoluteAmount, format: .number)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                    } else {
                        TextField("Amount", value: $draftSignedAmount, format: .number)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                    }
                    Text(transaction.currency)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            panelDivider

            if transaction.source == .manual && !isBalanceMirror {
                treatmentRow
                panelDivider
            }

            if !isBalanceMirror {
                propertyRows
                panelDivider
                categoryRow
                panelDivider
            }

            if !isBalanceMirror, !selectablePromotions.isEmpty {
                promotionsRow
                panelDivider
            }

            if isSettlementEditable {
                settlementRows
                panelDivider
            }

            if let account = transaction.account {
                readOnlyRow("Account", value: account.displayName)
            }

            if let card = transaction.cardLast4 {
                panelDivider
                readOnlyRow("Card", value: "••••\(card)")
            }
        }
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    private var consultationPanel: some View {
        VStack(spacing: 0) {
            readOnlyRow("Statement Date", value: transaction.postedAt.formatted(date: .abbreviated, time: .omitted))
            panelDivider
            readOnlyRow("Description", value: transaction.descriptionRaw)
            panelDivider
            readOnlyRow("Amount", value: MoneyFormat.string(transaction.amount, code: transaction.currency))
            if transaction.source == .manual && !isBalanceMirror {
                panelDivider
                readOnlyRow("Treatment", value: transaction.treatmentKind.displayName)
            }
            if !isBalanceMirror {
                panelDivider
                readOnlyRow("Property", value: collectionPropertyLabel)
                panelDivider
                readOnlyRow("Category", value: transaction.category?.localizedName ?? String(localized: "Uncategorized"))
                if !attributedPromotionIDs.isEmpty {
                    panelDivider
                    let names = promotionsModel.ledger.promotions.filter { attributedPromotionIDs.contains($0.id) }.map(\.name)
                    readOnlyRow("Promotions", value: names.joined(separator: ", "))
                }
                if isSettlementEditable {
                    panelDivider
                    readOnlyRow("Assignment", value: transaction.isIncludedInHouseholdSettlement
                        ? transaction.expenseAssignment.displayName : String(localized: "Not included"))
                    if transaction.isIncludedInHouseholdSettlement, transaction.expenseAssignment == .custom,
                       let amount = transaction.customFerAmount {
                        panelDivider
                        readOnlyRow("Fer’s portion", value: MoneyFormat.string(amount, code: transaction.currency))
                    }
                    if let notes = transaction.settlementNotes, !notes.isEmpty {
                        panelDivider
                        readOnlyRow("Notes", value: notes)
                    }
                }
            }
            if let account = transaction.account {
                panelDivider
                readOnlyRow("Account", value: account.displayName)
            }
            if let card = transaction.cardLast4 {
                panelDivider
                readOnlyRow("Card", value: "••••\(card)")
            }
        }
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
    }

    private var collectionPropertyLabel: String {
        let applications = propertyLedger.paymentApplications.filter { $0.paymentTransactionID == transaction.id && $0.deletedAt == nil }
        if !applications.isEmpty {
            let labels = applications.map { application in
                let property = propertyLedger.properties.first { $0.id == application.propertyID }?.name
                    ?? (application.propertyID == (propertyLedger.householdLink ?? PropertyHouseholdAdapter.link).propertyID
                        ? PropertyDestination.householdName : String(localized: "Property unavailable"))
                let name = propertyLedger.residents.first { $0.id == application.residentID }?.name
                    ?? String(localized: "Member")
                return "\(property) · \(name)"
            }
            return Array(Set(labels)).sorted().joined(separator: ", ")
        }
        if let id = draftPropertyID { return propertyLedger.properties.first { $0.id == id }?.name ?? String(localized: "Property unavailable") }
        if transaction.isIncludedInHouseholdSettlement { return PropertyDestination.householdName }
        return String(localized: "No property")
    }

    private var selectablePromotions: [PromotionRecord] {
        PromotionBoard.selectablePromotions(ledger: promotionsModel.ledger, currency: transaction.currency)
    }

    private var propertyResidents: [PropertyResident] {
        guard let draftPropertyID else { return [] }
        return propertyLedger.residents(for: draftPropertyID, month: draftDate)
    }

    private var propertyMaintenancePrograms: [PropertyMaintenanceProgram] {
        guard let draftPropertyID else { return [] }
        return propertyLedger.maintenancePrograms.filter { $0.propertyID == draftPropertyID && $0.deletedAt == nil }
    }

    @ViewBuilder
    private var propertyRows: some View {
        if let propertySaveError {
            Text(propertySaveError).font(.caption2).foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14)
        }
        if propertyLedger.paymentApplications.contains(where: { $0.paymentTransactionID == transaction.id && $0.deletedAt == nil }) {
            readOnlyRow("Property", value: collectionPropertyLabel)
        } else {
        editRow("Propiedad") {
            Picker("Propiedad", selection: $draftPropertyID) {
                Text("Sin propiedad").tag(UUID?.none)
                if transaction.currency == "MXN" {
                    ForEach(propertyLedger.activeProperties) { property in Text(property.name).tag(UUID?.some(property.id)) }
                } else if let draftPropertyID,
                          let property = propertyLedger.properties.first(where: { $0.id == draftPropertyID }) {
                    Text("\(property.name) · solo lectura (\(transaction.currency))")
                        .tag(UUID?.some(property.id))
                }
            }.labelsHidden().frame(maxWidth: .infinity, alignment: .trailing)
        }
        if transaction.currency != "MXN", draftPropertyID != nil {
            Label("Las liquidaciones de propiedades requieren MXN. Quita la atribución de este movimiento o registra su equivalente en una cuenta MXN.",
                  systemImage: "exclamationmark.triangle")
                .font(.caption2).foregroundStyle(.orange).padding(.horizontal, 14)
        }
        if draftPropertyID != nil, transaction.currency == "MXN" {
            panelDivider
            editRow(transaction.amount > 0 ? "Tipo de ingreso" : "Tipo de gasto") {
                Picker(transaction.amount > 0 ? "Tipo de ingreso" : "Tipo de gasto", selection: $draftPropertyKind) {
                    if transaction.amount > 0 {
                        Text("Cobro de residente").tag(PropertyExpenseKind.operation)
                        Text("Reembolso recibido").tag(PropertyExpenseKind.reimbursement)
                    } else {
                        Text("Operación").tag(PropertyExpenseKind.operation)
                        Text("Mantenimiento").tag(PropertyExpenseKind.maintenance)
                        Text("Otro").tag(PropertyExpenseKind.other)
                    }
                }.labelsHidden().frame(maxWidth: .infinity, alignment: .trailing)
            }
            if transaction.amount < 0 {
                panelDivider
                editRow("Responsabilidad") {
                    Picker("Responsabilidad", selection: $draftPropertyResponsibility) {
                        Text("Compartido").tag(PropertyCaptureResponsibility.shared)
                        Text("Individual").tag(PropertyCaptureResponsibility.individual)
                        Text("Entre residentes elegidos").tag(PropertyCaptureResponsibility.selected)
                        Text("Propietario").tag(PropertyCaptureResponsibility.owner)
                    }.labelsHidden().frame(maxWidth: .infinity, alignment: .trailing)
                }
                if draftPropertyResponsibility == .individual {
                    panelDivider
                    editRow("Residente") {
                        Picker("Residente", selection: $draftPropertyResidentID) {
                            Text("Elige").tag(UUID?.none)
                            ForEach(propertyResidents) { Text($0.name).tag(UUID?.some($0.id)) }
                        }.labelsHidden().frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                if draftPropertyResponsibility == .selected {
                    ForEach(propertyResidents) { resident in
                        Toggle(resident.name, isOn: Binding(get: {
                            draftSelectedPropertyResidents.contains(resident.id)
                        }, set: { selected in
                            if selected { draftSelectedPropertyResidents.insert(resident.id) }
                            else { draftSelectedPropertyResidents.remove(resident.id) }
                        })).padding(.horizontal, 14)
                    }
                }
                if draftPropertyKind == .maintenance, !propertyMaintenancePrograms.isEmpty {
                    panelDivider
                    editRow("Programa") {
                        Picker("Programa", selection: $draftMaintenanceProgramID) {
                            Text("Sin programa").tag(UUID?.none)
                            ForEach(propertyMaintenancePrograms) { program in
                                Text("\(program.startsAt.formatted(.dateTime.month(.wide).year()))–\(program.endsAt.formatted(.dateTime.month(.wide).year()))")
                                    .tag(UUID?.some(program.id))
                            }
                        }
                        .labelsHidden().frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
        }
        }
    }

    private func loadPropertyDraft() {
        propertySourceAtOpen = propertyInput(transaction)
        do {
            propertyLedger = try PropertyLedgerStore.read()
            guard let attribution = propertyLedger.attributions.filter({
                $0.transactionID == transaction.id && $0.deletedAt == nil
            }).max(by: { $0.updatedAt < $1.updatedAt }) else { return }
            draftPropertyID = attribution.propertyID
            draftPropertyKind = transaction.amount > 0 && attribution.kind != .reimbursement
                ? .operation : attribution.kind
            draftMaintenanceProgramID = attribution.maintenanceProgramID
            switch attribution.responsibility {
            case .shared: draftPropertyResponsibility = .shared
            case .owner: draftPropertyResponsibility = .owner
            case .individual(let id): draftPropertyResponsibility = .individual; draftPropertyResidentID = id
            case .selected(let ids): draftPropertyResponsibility = .selected; draftSelectedPropertyResidents = Set(ids)
            }
        } catch { propertySaveError = error.localizedDescription }
    }

    private var attributedPromotionIDs: Set<UUID> {
        Set(PromotionBoard.attributedPromotionIDs(ledger: promotionsModel.ledger, transactionID: transaction.id))
    }

    private var outOfWindowCount: Int {
        PromotionBoard.outOfWindowPromotionIDs(ledger: promotionsModel.ledger,
                                               promotionIDs: draftPromotionIDs,
                                               date: draftDate,
                                               calendar: promotionsModel.promotionCalendar).count
    }

    @ViewBuilder
    private var promotionsRow: some View {
        VStack(spacing: 6) {
            editRow("Promociones") {
                Text("\(draftPromotionIDs.count) adjudicada\(draftPromotionIDs.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 4) {
                if let error = promotionsModel.loadError {
                    Text("Promociones no disponibles: \(error)").font(.caption2).foregroundStyle(.orange)
                }
                ForEach(selectablePromotions) { promo in
                    Toggle(promo.name, isOn: Binding(
                        get: { draftPromotionIDs.contains(promo.id) },
                        set: { isOn in
                            if isOn { draftPromotionIDs.insert(promo.id) }
                            else { draftPromotionIDs.remove(promo.id) }
                        }))
                    .font(.caption)
                    .toggleStyle(.checkbox)
                }
                if outOfWindowCount > 0 {
                    Text(outOfWindowCount == 1
                         ? "1 promoción adjudicada está fuera de su ventana — cuenta igual; solo es un aviso."
                         : "\(outOfWindowCount) promociones adjudicadas están fuera de su ventana — cuentan igual; solo es un aviso.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 14)
        }
    }

    @ViewBuilder
    private var kindRow: some View {
        editRow("Kind") {
            Picker("Kind", selection: $draftFlowKind) {
                Text("Charge").tag(TransactionFlowKind.charge)
                Text("Card Credit").tag(TransactionFlowKind.cardCredit)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var treatmentRow: some View {
        VStack(spacing: 6) {
            editRow("Treatment") {
                Picker("Treatment", selection: $draftTreatmentKind) {
                    ForEach(TransactionTreatmentKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            VStack(alignment: .trailing, spacing: 2) {
                Text("Treatment changes how this transaction is counted in Income, Expenses, and Cash Flow reporting. It does not change the underlying account movement or transfer status.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.trailing)
                if transaction.isTransfer {
                    Text("This transaction remains a transfer for Income, Expenses, and Cash Flow.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.trailing)
                }
            }
            .padding(.horizontal, 14)
        }
    }

    @ViewBuilder
    private var settlementRows: some View {
        editRow("Include in Household Settlement") {
            Toggle("", isOn: $draftIncluded)
                .labelsHidden()
                .accessibilityIdentifier("transaction.household.includeToggle")
        }
        if draftIncluded {
            panelDivider
            editRow("Assignment") {
                Picker("Assignment", selection: $draftExpenseAssignment) {
                    ForEach(ExpenseAssignment.allCases) { assignment in
                        Text(assignment == .user ? String(localized: "Mine") : assignment.displayName)
                            .accessibilityIdentifier("transaction.assignment.\(assignment.rawValue)")
                            .tag(assignment)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityIdentifier("transaction.assignment.picker")
            }
            if draftExpenseAssignment == .custom {
            panelDivider
            editRow("Fer’s portion") {
                HStack(spacing: 8) {
                    TextField(
                        "0.00",
                        value: $draftCustomFerAmount,
                        format: .number.precision(.fractionLength(0...2))
                    )
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .accessibilityIdentifier("transaction.customSplit.ferAmount")
                    Text(transaction.currency)
                        .foregroundStyle(.secondary)
                }
            }
            panelDivider
            editRow("Your portion") {
                Text(customUserAmount.map { MoneyFormat.string($0, code: transaction.currency) } ?? "—")
                    .monospacedDigit()
                    .accessibilityIdentifier("transaction.customSplit.userAmount")
            }
            if let userAmount = customUserAmount,
               let ferAmount = draftCustomFerAmount,
               abs(displayAmount) > 0 {
                Text("Tú \(HouseholdSettlementReport.percent(userAmount / abs(displayAmount))) / Fer \(HouseholdSettlementReport.percent(ferAmount / abs(displayAmount)))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
                    .accessibilityLabel("Tú \(HouseholdSettlementReport.percent(userAmount / abs(displayAmount))), Fer \(HouseholdSettlementReport.percent(ferAmount / abs(displayAmount)))")
            }
            if let customSplitError {
                Text(customSplitError)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
            }
        }
        } else {
            Text("Only included transactions appear in Household Settlement and affect the amount to recover from Fer.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
        }
        panelDivider
        editRow("Settlement Notes") {
            TextField("Optional", text: $draftSettlementNotes, axis: .vertical)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .lineLimit(1...3)
        }
    }

    private func editRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(LocalizedStringKey(label))
                .font(.callout)
                .foregroundStyle(.primary)
                .frame(width: 118, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func readOnlyRow(_ label: String, value: String) -> some View {
        editRow(label) {
            Text(value)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var panelDivider: some View {
        Divider()
            .padding(.leading, 132)
    }

    private var primaryLabel: String {
        let merchant = draftDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return merchant.isEmpty ? "Untitled Transaction" : merchant
    }

    private var metadataParts: [String] {
        var parts: [String] = []
        if let account = transaction.account?.displayName {
            parts.append(account)
        }
        if let card = transaction.cardLast4 {
            parts.append("••••\(card)")
        }
        return parts
    }

    private var categoryColor: Color {
        if isBalanceMirror {
            return .secondary
        }
        if let category = draftCategory {
            return CategoryBadgeColor.color(for: category)
        }
        return .secondary
    }

    @ViewBuilder
    private var categoryValue: some View {
        if let category = draftCategory {
            HStack(spacing: 6) {
                Circle()
                    .fill(CategoryBadgeColor.color(for: category))
                    .frame(width: 8, height: 8)
                Text(category.localizedName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else {
            Text("Uncategorized")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var categoryRow: some View {
        Button {
            showingCategoryPicker = true
        } label: {
            HStack {
                Text("Category")
                    .font(.callout)
                    .frame(width: 118, alignment: .leading)
                Spacer()
                categoryValue
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack {
            Button(displayMode == .consult || completion.movementSaved ? "Close" : "Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Spacer()
            if displayMode == .consult {
                Button("Edit") {
                    originalPromotionIDs = attributedPromotionIDs
                    draftPromotionIDs = originalPromotionIDs
                    displayMode = .edit
                }.buttonStyle(.glassProminent)
            } else {
                Button(completion.movementSaved ? "Retry saving" : "Save") { save() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(customSplitInvalid)
                    .accessibilityIdentifier("transaction.save.button")
                    .accessibilityValue(customSplitInvalid ? "Disabled: invalid custom split" : "Enabled")
            }
        }
    }

    private func save() {
        if completion.movementSaved { finishSavedMovement(); return }
        do { try validatePropertyDraft() }
        catch { propertySaveError = error.localizedDescription; return }
        do {
            try TransactionEditRevisionGuard.validate(transactionID: transaction.id, revision: originalRevision,
                accountID: originalAccountID, expected: propertySourceAtOpen, container: modelContext.container)
        } catch { propertySaveError = error.localizedDescription; return }
        if draftPromotionIDs != originalPromotionIDs {
            do {
                let current = try PromotionLedgerStore.read()
                guard Set(PromotionBoard.attributedPromotionIDs(ledger: current, transactionID: transaction.id)) == originalPromotionIDs else {
                    throw PromotionLedgerStore.StoreError.attributionChanged
                }
            } catch { propertySaveError = error.localizedDescription; return }
        }
        let isBalanceMirror = BalanceSnapshotService.mirroredSnapshot(for: transaction, context: modelContext) != nil
        // Capture before mutation: if the row leaves Fer, its due-date override is cleared.
        let previousAssignment = transaction.expenseAssignment
        let amountToStore: Decimal
        if isBalanceMirror, let account = transaction.account {
            amountToStore = account.type.isLiability ? -abs(draftSignedAmount) : abs(draftSignedAmount)
            transaction.isDuplicate = true
            transaction.movementKindRaw = TransactionMovementKind.adjustment.rawValue
            transaction.treatmentKindRaw = TransactionTreatmentKind.valuationAdjustment.rawValue
        } else if isKindEditable {
            switch draftFlowKind {
            case .charge: amountToStore = -abs(draftAbsoluteAmount)
            default: amountToStore = abs(draftAbsoluteAmount)
            }
            transaction.flowKindRaw = draftFlowKind.rawValue
            transaction.movementKindRaw = Transaction.movementKind(
                from: draftFlowKind,
                amount: amountToStore,
                isTransfer: transaction.isTransfer
            ).rawValue
        } else {
            amountToStore = draftSignedAmount
        }

        transaction.postedAt = draftDate
        transaction.descriptionRaw = draftDescription
        transaction.merchantNormalized = draftDescription
        transaction.amount = amountToStore
        // Treatment is reporting-only: store `.regular` as nil to keep data quiet,
        // and never touch flow/movement/transfer here.
        if !isBalanceMirror {
            transaction.setReportingTreatment(draftTreatmentKind)
        }
        if isSettlementEditable {
            // Write the assignment/custom first; only persist scope once that
            // succeeds so a validation error can't leave a half-mutated row.
            if draftIncluded {
                if draftExpenseAssignment == .custom, let ferAmount = draftCustomFerAmount {
                    do {
                        try transaction.setCustomFerAmount(ferAmount)
                    } catch {
                        return
                    }
                } else {
                    transaction.setExpenseAssignment(draftExpenseAssignment)
                }
            }
            // Scope is always persisted explicitly. Exclusion preserves any latent
            // assignment/custom as inactive metadata (do not clear them here).
            transaction.setHouseholdScope(draftIncluded ? .included : .excluded)
            let notes = draftSettlementNotes.trimmingCharacters(in: .whitespacesAndNewlines)
            transaction.settlementNotes = notes.isEmpty ? nil : notes
        }

        if !isBalanceMirror, categoryDidChange, let newCategory = draftCategory {
            transaction.category = newCategory
            let keyword = MerchantExtractor.extractMerchant(from: draftDescription)
            LearningHooks.recordCategorization(
                keyword: keyword,
                category: newCategory,
                sourceDescription: draftDescription,
                in: modelContext
            )
            pendingKeyword = keyword
        }

        transaction.touch()
        BalanceSnapshotService.syncMirroredSnapshot(for: transaction, context: modelContext)
        do { try modelContext.save() }
        catch {
            propertySaveError = "No se pudieron guardar los cambios del movimiento: \(error.localizedDescription)"
            return
        }
        savedBalanceMirror = isBalanceMirror
        completion = TransactionEditCompletion(movementSaved: true,
            dueDatePending: draftIncluded && previousAssignment == .partner && draftExpenseAssignment != .partner,
            propertyPending: !isBalanceMirror, promotionPending: draftPromotionIDs != originalPromotionIDs)
        finishSavedMovement()
    }

    private func finishSavedMovement() {
        var pending = completion
        do {
            try pending.run(purgeDueDate: {
                try SettlementDueDateService.purge(for: [transaction.id], context: modelContext)
            }, saveProperty: {
                try savePropertyAssociation(transaction)
            }, savePromotions: {
                try PromotionLedgerStore.setAttributions(transactionID: transaction.id, currency: transaction.currency,
                    expected: originalPromotionIDs, selected: draftPromotionIDs)
            })
        } catch let failure as TransactionEditCompletion.Failure {
            completion = pending
            let key: String.LocalizationValue
            switch failure.stage {
            case .dueDate: key = "The movement was saved, but its due date could not be cleared: %@"
            case .property: key = "The movement was saved, but its property association could not be saved: %@"
            case .promotion: key = "The movement was saved, but the promotion assignments could not be saved: %@"
            }
            propertySaveError = String(format: String(localized: key), failure.underlying.localizedDescription)
            return
        } catch {
            completion = pending
            propertySaveError = error.localizedDescription
            return
        }
        completion = pending
        originalPromotionIDs = draftPromotionIDs
        if !savedBalanceMirror, categoryDidChange, let cat = draftCategory {
            onCategoryAssigned(
                CategoryChange(transaction: transaction, category: cat, keyword: pendingKeyword)
            )
        }

        onSaved?()
        dismiss()
    }

    private func propertyDraftResponsibility() throws -> PropertyResponsibility {
        if transaction.amount > 0 { return .owner }
        switch draftPropertyResponsibility {
        case .shared: return .shared
        case .owner: return .owner
        case .individual:
            guard let id = draftPropertyResidentID else { throw PropertyAssignmentService.AssignmentError.invalid("Choose an active member for this period.") }
            return .individual(residentID: id)
        case .selected:
            return .selected(residentIDs: draftSelectedPropertyResidents.sorted { $0.uuidString < $1.uuidString })
        }
    }

    private func validatePropertyDraft() throws {
        let ledger = try PropertyLedgerStore.read()
        let original = ledger.attributions.first { $0.transactionID == transaction.id && $0.deletedAt == nil }
        let draftResponsibility = draftPropertyID != nil ? try propertyDraftResponsibility() : nil
        if PropertyAssignmentService.isLocked(transaction.id, ledger: ledger) {
            let associationChanged = draftPropertyID != original?.propertyID
                || (draftPropertyID != nil && draftResponsibility != original?.responsibility)
                || (draftPropertyID != nil && draftPropertyKind != original?.kind)
            let householdChanged = draftIncluded != transaction.isIncludedInHouseholdSettlement
                || (draftIncluded && (draftExpenseAssignment != transaction.expenseAssignment
                    || (draftExpenseAssignment == .custom && draftCustomFerAmount != transaction.customPartnerPercent)))
            if associationChanged || householdChanged {
                throw PropertyAssignmentService.AssignmentError.invalid("This transaction belongs to a closed calculation. Record an adjustment in an open period.")
            }
        }
        if let id = draftPropertyID {
            try PropertyAssignmentService.validate(try propertyDraftResponsibility(), propertyID: id, month: draftDate, ledger: ledger)
            var input = propertyInput(transaction)
            input.isHouseholdAssigned = draftIncluded
            guard PropertyAssignmentService.isAvailable(input, propertyID: id, ledger: ledger) else {
                throw PropertyAssignmentService.AssignmentError.invalid("This transaction has another destination or is not eligible.")
            }
        }
    }

    private func propertyInput(_ transaction: Transaction) -> PropertyTransactionInput {
        PropertyTransactionInput(capturing: transaction)
    }

    private func savePropertyAssociation(_ transaction: Transaction) throws {
        var ledger = try PropertyLedgerStore.read()
        let existingIndex = ledger.attributions.firstIndex { $0.transactionID == transaction.id && $0.deletedAt == nil }
        // A financial-source correction may surface a discrepancy, but never rewrites a closed split.
        if PropertyAssignmentService.isLocked(transaction.id, ledger: ledger) { return }
        guard let draftPropertyID else {
            guard let index = existingIndex else { return }
            ledger.attributions[index].deletedAt = .now; ledger.attributions[index].updatedAt = .now
            try PropertyLedgerStore.replace(with: ledger)
            return
        }
        let responsibility = try propertyDraftResponsibility()
        var proposed: PropertyTransactionAttribution
        if let existingIndex { proposed = ledger.attributions[existingIndex] }
        else { proposed = PropertyTransactionAttribution(propertyID: draftPropertyID, transactionID: transaction.id,
            kind: draftPropertyKind, responsibility: responsibility) }
        proposed.kind = draftPropertyKind
        proposed.responsibility = try propertyDraftResponsibility()
        proposed.maintenanceProgramID = draftMaintenanceProgramID
        let source = propertyInput(transaction)
        let sourceWasEdited = propertySourceAtOpen.map {
            PropertySettlementCalculator.hasSourceChanged(amount: $0.amount, postedAt: $0.postedAt,
                currencyCode: $0.currencyCode, description: $0.description, versus: source)
        } ?? false
        let previous = existingIndex.map { ledger.attributions[$0] }
        let responsibilityOnly = !sourceWasEdited && previous?.kind == proposed.kind
            && previous?.maintenanceProgramID == proposed.maintenanceProgramID
        try PropertyAssignmentService.upsert(proposed, source: source, ledger: &ledger, responsibilityOnly: responsibilityOnly)
        try PropertyLedgerStore.replace(with: ledger)
    }
}

@MainActor
enum TransactionEditRevisionGuard {
    enum EditError: LocalizedError {
        case changed
        var errorDescription: String? { String(localized: "This movement changed. Reopen it before saving.") }
    }

    static func validate(transactionID: UUID, revision: Date, accountID: UUID?,
                         expected: PropertyTransactionInput?, container: ModelContainer) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let id = transactionID
        let descriptor = FetchDescriptor<Transaction>(predicate: #Predicate<Transaction> { $0.id == id })
        guard let live = try context.fetch(descriptor).first, let expected,
              live.lastModifiedAt == revision, live.account?.id == accountID,
              !PropertySettlementCalculator.hasSourceChanged(amount: expected.amount, postedAt: expected.postedAt,
                  currencyCode: expected.currencyCode, description: expected.description,
                  versus: PropertyTransactionInput(capturing: live)) else { throw EditError.changed }
    }
}

struct TransactionEditCompletion {
    enum Stage { case dueDate, property, promotion }
    struct Failure: Error { var stage: Stage; var underlying: Error }
    var movementSaved = false
    var dueDatePending = false
    var propertyPending = false
    var promotionPending = false

    mutating func run(purgeDueDate: () throws -> Void, saveProperty: () throws -> Void,
                      savePromotions: () throws -> Void) throws {
        if dueDatePending {
            do { try purgeDueDate(); dueDatePending = false }
            catch { throw Failure(stage: .dueDate, underlying: error) }
        }
        if propertyPending {
            do { try saveProperty(); propertyPending = false }
            catch { throw Failure(stage: .property, underlying: error) }
        }
        if promotionPending {
            do { try savePromotions(); promotionPending = false }
            catch { throw Failure(stage: .promotion, underlying: error) }
        }
    }
}
