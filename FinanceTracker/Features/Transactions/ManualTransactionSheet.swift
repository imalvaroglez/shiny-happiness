import SwiftData
import SwiftUI

struct ManualTransactionSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \Account.nickname) private var accounts: [Account]
    @Query(filter: #Predicate<Category> { $0.deletedAt == nil },
           sort: \Category.name) private var categories: [Category]

    private var activeAccounts: [Account] {
        accounts.filter { $0.isAvailableForCapture }
    }

    let defaultAccountID: UUID?
    let lockedAccountID: UUID?
    let onSaved: () -> Void

    init(defaultAccountID: UUID? = nil, lockedAccountID: UUID? = nil, onSaved: @escaping () -> Void) {
        self.defaultAccountID = defaultAccountID
        self.lockedAccountID = lockedAccountID
        self.onSaved = onSaved
    }

    @State private var kind: ManualTransactionKind = .income
    @State private var accountID: UUID?
    @State private var counterpartyAccountID: UUID?
    @State private var date = Date.now
    @State private var description = ""
    @State private var amount: Decimal = 0
    @State private var categoryID: UUID?
    @State private var expenseAssignment: ExpenseAssignment = .user
    @State private var includeInHousehold: Bool = false
    @State private var showingCategoryPicker = false
    @State private var errorMessage: String?
    @State private var promotionsModel = PromotionLedgerViewModel()
    @State private var selectedPromotionIDs: Set<UUID> = []
    @State private var attributionFailure: AttributionFailure?
    @State private var propertyLedger = PropertyLedger()
    @State private var propertyID: UUID?
    @State private var propertyExpenseKind: PropertyExpenseKind = .operation
    @State private var propertyResponsibility: PropertyCaptureResponsibility = .shared
    @State private var propertyResidentID: UUID?
    @State private var propertySelectedResidentIDs: Set<UUID> = []
    @State private var propertyMaintenanceProgramID: UUID?
    @State private var pendingPropertyTransaction: Transaction?
    @State private var propertySaveError: String?
    @State private var didEditDate = false
    @State private var saveIntent: SaveAndNewFlow.Intent = .close
    @FocusState private var focusedField: SaveAndNewFlow.Field?

    private var selectedAccount: Account? {
        activeAccounts.first { $0.id == accountID }
    }

    private var lockedAccountIsUnavailable: Bool {
        guard let lockedAccountID else { return false }
        guard let locked = accounts.first(where: { $0.id == lockedAccountID }) else { return false }
        return !locked.isAvailableForCapture
    }

    private var selectedCategory: Category? {
        categoryID.flatMap { id in categories.first { $0.id == id } }
    }

    private var selectedPropertyResidents: [PropertyResident] {
        guard let propertyID else { return [] }
        return propertyLedger.residents(for: propertyID, month: date)
    }

    private var selectedPropertyPrograms: [PropertyMaintenanceProgram] {
        guard let propertyID else { return [] }
        return propertyLedger.maintenancePrograms.filter { $0.propertyID == propertyID && $0.deletedAt == nil }
    }

    private var availableKinds: [ManualTransactionKind] {
        guard let account = selectedAccount else {
            return [.income, .expense, .transfer]
        }
        return ManualTransactionKind.availableKinds(for: account.type)
    }

    private var allowedCategoryKinds: Set<CategoryKind> {
        switch kind {
        case .income:
            return [.income]
        case .expense, .charge, .cardCredit:
            return [.expense]
        case .payment, .transfer:
            return []
        }
    }

    var body: some View {
        VStack(spacing: 18) {
            Text("Add Transaction")
                .font(.headline)

            if let account = selectedAccount {
                kindPicker(for: account.type)
            }

            VStack(spacing: 0) {
                formContent
            }
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
            )

            promotionsSection
            attributionFailureAlert

            if lockedAccountIsUnavailable {
                Text("This account is archived or closed. Restore or reopen it in Settings → Accounts before adding a transaction.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let propertySaveError {
                Label(propertySaveError, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                if pendingPropertyTransaction != nil {
                    Button("Cerrar sin vincular") { dismiss() }
                        .buttonStyle(.borderless)
                }
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Guardar y nuevo") {
                    saveIntent = .addAnother
                    save()
                }
                .disabled(activeAccounts.isEmpty || lockedAccountIsUnavailable || attributionFailure != nil)
                Button(attributionFailure == nil ? "Save" : "Guardada ✓") {
                    saveIntent = .close
                    save()
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(activeAccounts.isEmpty || lockedAccountIsUnavailable || attributionFailure != nil)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear {
            do { propertyLedger = try PropertyLedgerStore.read() }
            catch { propertySaveError = "No se pudo leer el registro de propiedades: \(error.localizedDescription)" }
            accountID = preferredActiveAccountID
            normalizeKindAndCategory()
            updateCounterparty()
            applyDateSuggestion()
        }
        .onChange(of: accounts.map { "\($0.id.uuidString):\($0.archivedAt?.timeIntervalSince1970 ?? 0):\($0.closedAt?.timeIntervalSince1970 ?? 0)" }) {
            // Re-select only while the account is still available for capture;
            // archived and closed accounts drop out of the active list.
            if selectedAccount == nil {
                accountID = preferredActiveAccountID
            }
            updateCounterparty()
        }
        .onChange(of: accountID) {
            normalizeKindAndCategory()
            updateCounterparty()
            purgeStalePromotionSelection()
            applyDateSuggestion()
            if selectedAccount?.currency != "MXN" { propertyID = nil }
        }
        .onChange(of: kind) {
            normalizeKindAndCategory()
            updateCounterparty()
            purgeStalePromotionSelection()
            if kind == .payment || kind == .transfer || kind == .cardCredit { propertyID = nil }
            if kind == .income && propertyExpenseKind != .reimbursement { propertyExpenseKind = .operation }
            if kind != .income && propertyExpenseKind == .reimbursement { propertyExpenseKind = .operation }
        }
        .onChange(of: propertyID) { if propertyID != nil { includeInHousehold = false } }
        .onChange(of: includeInHousehold) { if includeInHousehold { propertyID = nil } }
        .onChange(of: propertyExpenseKind) { if propertyExpenseKind == .maintenance { propertyResponsibility = .owner } }
        .task { promotionsModel.reload(context: modelContext, includeTransactions: false) }
        .onReceive(NotificationCenter.default.publisher(for: PromotionLedgerStore.didChangeNotification)) { _ in
            promotionsModel.scheduleReload(context: modelContext, includeTransactions: false)
        }
        .sheet(isPresented: $showingCategoryPicker) {
            CategoryPickerView(
                selectedCategoryID: categoryID,
                allowedKinds: allowedCategoryKinds
            ) { category in
                categoryID = category.id
            }
        }
    }

    @ViewBuilder
    private func kindPicker(for accountType: AccountType) -> some View {
        let kinds = ManualTransactionKind.availableKinds(for: accountType)
        Picker("Kind", selection: $kind) {
            ForEach(kinds) { k in
                Text(k.rawValue).tag(k)
            }
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Adjudicación manual a promociones

    struct AttributionFailure: Identifiable {
        let id = UUID()
        let transactionID: UUID
        var failedIDs: Set<UUID>
    }

    @ViewBuilder
    private var promotionsSection: some View {
        let currency = selectedAccount?.currency
        let options = currency.map { PromotionBoard.selectablePromotions(ledger: promotionsModel.ledger, currency: $0) } ?? []
        if let error = promotionsModel.loadError {
            Text("Promociones no disponibles: \(error)").font(.caption).foregroundStyle(.orange)
        }
        if !options.isEmpty, kind != .transfer, kind != .payment {
            VStack(alignment: .leading, spacing: 6) {
                Text("Cuenta para promociones")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(options) { promo in
                    Toggle(promo.name, isOn: Binding(
                        get: { selectedPromotionIDs.contains(promo.id) },
                        set: { isOn in
                            if isOn { selectedPromotionIDs.insert(promo.id) }
                            else { selectedPromotionIDs.remove(promo.id) }
                        }))
                    .font(.caption)
                    .toggleStyle(.checkbox)
                }
                if let warning = outOfWindowWarning {
                    Text(warning)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    @ViewBuilder
    private var attributionFailureAlert: some View {
        if let failure = attributionFailure {
            VStack(spacing: 6) {
                Text("La transacción se guardó, pero no se pudo adjudicar a \(failure.failedIDs.count) promoción(es).")
                    .font(.caption)
                    .foregroundStyle(.orange)
                HStack {
                    Button("Reintentar") { retryPendingAttributions() }
                    Button("Más tarde") { deferAttributions() }
                }
                .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    /// Aviso informativo: la ventana nunca filtra (PA-07).
    private var outOfWindowWarning: String? {
        let outCount = PromotionBoard.outOfWindowPromotionIDs(
            ledger: promotionsModel.ledger, promotionIDs: selectedPromotionIDs,
            date: date, calendar: promotionsModel.promotionCalendar).count
        guard outCount > 0 else { return nil }
        return outCount == 1
            ? "1 promoción seleccionada está fuera de su ventana — cuenta igual; solo es un aviso."
            : "\(outCount) promociones seleccionadas están fuera de su ventana — cuentan igual; solo es un aviso."
    }

    /// Fecha sugerida: la de la última manual de la cuenta. Solo se aplica si
    /// el usuario no ha editado la fecha en esta sesión de captura.
    private func applyDateSuggestion() {
        guard !didEditDate, let accountID else { return }
        date = ManualCaptureDateStore.suggestedDate(accountID: accountID) ?? .now
    }

    /// PA-05: al cambiar de cuenta (o a transfer/pago) la selección no puede
    /// quedarse con promos de otra moneda.
    private func purgeStalePromotionSelection() {
        guard let currency = selectedAccount?.currency else {
            selectedPromotionIDs = []
            return
        }
        let allowed = Set(PromotionBoard.selectablePromotions(ledger: promotionsModel.ledger,
                                                             currency: currency).map(\.id))
        selectedPromotionIDs.formIntersection(allowed)
    }

    /// Solo reintenta el upsert del ledger (idempotente); jamás crea otra transacción.
    private func retryPendingAttributions() {
        guard let failure = attributionFailure else { return }
        let failed = AttributionSaver.retry(transactionID: failure.transactionID,
                                            failedPromotionIDs: failure.failedIDs)
        guard let resolution = SaveAndNewFlow.resolve(intent: saveIntent,
                                                      attributionFailureResolved: failed.isEmpty)
        else {
            attributionFailure = AttributionFailure(transactionID: failure.transactionID,
                                                    failedIDs: failed)
            return
        }
        attributionFailure = nil
        applyResolution(resolution)
    }

    private func deferAttributions() {
        // «Más tarde»: la adjudicación queda recuperable desde el detalle.
        attributionFailure = nil
        applyResolution(SaveAndNewFlow.resolve(intent: saveIntent))
    }

    private func finishAfterSuccess() {
        applyResolution(SaveAndNewFlow.resolve(intent: saveIntent))
    }

    private func applyResolution(_ resolution: SaveAndNewFlow.Resolution) {
        switch resolution {
        case .dismiss:
            onSaved()
            dismiss()
        case .resetForm:
            onSaved()
            resetForNextEntry()
        }
    }

    /// Reset COMPLETO tras un «Guardar y nuevo»: nada de arrastrar semántica
    /// doméstica (expenseAssignment/includeInHousehold) al siguiente movimiento.
    /// Conserva cuenta, tipo y contraparte; la fecha vuelve a la sugerencia
    /// (que ya hereda la de la tx recién guardada).
    private func resetForNextEntry() {
        description = ""
        amount = 0
        categoryID = nil
        selectedPromotionIDs = []
        expenseAssignment = .user
        includeInHousehold = false
        propertyID = nil
        propertyResponsibility = .shared
        propertyResidentID = nil
        propertySelectedResidentIDs = []
        propertyMaintenanceProgramID = nil
        pendingPropertyTransaction = nil
        propertySaveError = nil
        errorMessage = nil
        didEditDate = false
        applyDateSuggestion()
        focusedField = .description
    }

    /// La tx ya se guardó; un fallo del ledger deja la hoja abierta con Reintentar/Más tarde.
    private func applyAttributions(to transaction: Transaction) {
        guard !selectedPromotionIDs.isEmpty else { return }
        let outcome = AttributionSaver.apply(transactionID: transaction.id,
                                             currency: transaction.currency,
                                             selectedPromotionIDs: selectedPromotionIDs,
                                             ledger: promotionsModel.ledger)
        if !outcome.failedPromotionIDs.isEmpty {
            attributionFailure = AttributionFailure(transactionID: transaction.id,
                                                    failedIDs: outcome.failedPromotionIDs)
        }
    }

    @ViewBuilder
    private var formContent: some View {
        switch kind {
        case .income, .expense:
            singleRows(showCategory: true)
        case .charge, .cardCredit:
            singleRows(showCategory: true)
        case .payment:
            pairedRows(counterpartyLabel: "From Account")
        case .transfer:
            pairedRows(counterpartyLabel: "To Account")
        }
    }

    @ViewBuilder
    private func singleRows(showCategory: Bool) -> some View {
        if lockedAccountID == nil {
            accountPickerRow("Account", selection: $accountID)
            panelDivider
        }
        row("Date") {
            DatePicker("", selection: Binding(get: { date }, set: { didEditDate = true; date = $0 }), displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.compact)
        }
        panelDivider
        row("Description") {
            TextField("Merchant or note", text: $description)
                .focused($focusedField, equals: .description)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
        }
        panelDivider
        amountRow
        if showCategory {
            panelDivider
            categoryPickerRow
        }
        if kind == .expense || kind == .charge {
            panelDivider
            row("Include in Household") {
                Toggle("", isOn: $includeInHousehold)
                    .labelsHidden()
            }
            if includeInHousehold {
                panelDivider
                expenseAssignmentRow
            }
        }
        if (kind == .income || kind == .expense || kind == .charge), selectedAccount?.currency == "MXN" {
            panelDivider
            row("Propiedad") {
                Picker("Propiedad", selection: $propertyID) {
                    Text("Sin propiedad").tag(UUID?.none)
                    ForEach(propertyLedger.activeProperties) { property in
                        Text(property.name).tag(UUID?.some(property.id))
                    }
                }
                .labelsHidden()
                .frame(width: 200)
            }
            if propertyID != nil {
                if kind == .income {
                    panelDivider
                    row("Tipo de ingreso") {
                        Picker("Tipo de ingreso", selection: $propertyExpenseKind) {
                            Text("Cobro de residente").tag(PropertyExpenseKind.operation)
                            Text("Reembolso recibido").tag(PropertyExpenseKind.reimbursement)
                        }.labelsHidden().frame(width: 200)
                    }
                    panelDivider
                    Text(propertyExpenseKind == .reimbursement
                        ? "Registra el reembolso real; se reflejará en el resultado operativo."
                        : "Registra el cobro real aquí y aplícalo a residentes desde Propiedades.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.bottom, 8)
                } else {
                    panelDivider
                    row("Tipo de gasto") {
                        Picker("Tipo de gasto", selection: $propertyExpenseKind) {
                            Text("Operación").tag(PropertyExpenseKind.operation)
                            Text("Mantenimiento").tag(PropertyExpenseKind.maintenance)
                            Text("Otro").tag(PropertyExpenseKind.other)
                        }.labelsHidden().frame(width: 200)
                    }
                    panelDivider
                    row("Responsabilidad") {
                        Picker("Responsabilidad", selection: $propertyResponsibility) {
                            Text("Compartido").tag(PropertyCaptureResponsibility.shared)
                            Text("Individual").tag(PropertyCaptureResponsibility.individual)
                            Text("Entre residentes elegidos").tag(PropertyCaptureResponsibility.selected)
                            Text("Propietario").tag(PropertyCaptureResponsibility.owner)
                        }.labelsHidden().frame(width: 200)
                    }
                    if propertyResponsibility == .individual {
                        panelDivider
                        row("Residente") {
                            Picker("Residente", selection: $propertyResidentID) {
                                Text("Elige").tag(UUID?.none)
                                ForEach(selectedPropertyResidents) { resident in Text(resident.name).tag(UUID?.some(resident.id)) }
                            }.labelsHidden().frame(width: 200)
                        }
                    }
                    if propertyResponsibility == .selected {
                        ForEach(selectedPropertyResidents) { resident in
                            Toggle(resident.name, isOn: Binding(get: {
                                propertySelectedResidentIDs.contains(resident.id)
                            }, set: { isOn in
                                if isOn { propertySelectedResidentIDs.insert(resident.id) }
                                else { propertySelectedResidentIDs.remove(resident.id) }
                            }))
                            .padding(.horizontal, 14)
                        }
                    }
                    if propertyExpenseKind == .maintenance {
                        if !selectedPropertyPrograms.isEmpty {
                            panelDivider
                            row("Programa") {
                                Picker("Programa", selection: $propertyMaintenanceProgramID) {
                                    Text("Sin programa").tag(UUID?.none)
                                    ForEach(selectedPropertyPrograms) { program in
                                        Text("\(program.startsAt.formatted(.dateTime.month(.wide).year()))–\(program.endsAt.formatted(.dateTime.month(.wide).year()))")
                                            .tag(UUID?.some(program.id))
                                    }
                                }.labelsHidden().frame(width: 200)
                            }
                        }
                        Text("El mantenimiento se asigna al propietario por defecto. Puedes cambiar la responsabilidad arriba.")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.bottom, 8)
                    }
                }
            }
        } else if kind == .income || kind == .expense || kind == .charge {
            panelDivider
            Text("Las liquidaciones de propiedades requieren movimientos en MXN.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private func pairedRows(counterpartyLabel: String) -> some View {
        if kind == .payment {
            accountPickerRow(counterpartyLabel, selection: $counterpartyAccountID, filter: { !$0.type.isLiability })
            panelDivider
            if lockedAccountID == nil {
                row("Card / Loan") {
                    Text(selectedAccount?.displayName ?? "")
                        .foregroundStyle(.secondary)
                }
                panelDivider
            }
        } else {
            if lockedAccountID == nil {
                accountPickerRow("From", selection: $accountID)
                panelDivider
            }
            accountPickerRow(counterpartyLabel, selection: $counterpartyAccountID)
        }
        panelDivider
        row("Date") {
            DatePicker("", selection: Binding(get: { date }, set: { didEditDate = true; date = $0 }), displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.compact)
        }
        panelDivider
        row("Note") {
            TextField("Transfer", text: $description)
                .focused($focusedField, equals: .description)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
        }
        panelDivider
        amountRow
    }

    private var amountRow: some View {
        row("Amount") {
            TextField("0.00", value: $amount, format: .number)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
        }
    }

    private var categoryPickerRow: some View {
        row("Category") {
            Button {
                showingCategoryPicker = true
            } label: {
                HStack(spacing: 8) {
                    Text(selectedCategory?.localizedName ?? "Sin categoría")
                        .foregroundStyle(selectedCategory == nil ? .secondary : .primary)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .buttonStyle(.plain)
        }
    }

    private var expenseAssignmentRow: some View {
        row("Assignment") {
            Picker("Assignment", selection: $expenseAssignment) {
                ForEach(ExpenseAssignment.quickCases) { assignment in
                    Text(assignment == .user ? "Mine" : assignment.displayName).tag(assignment)
                }
            }
            .labelsHidden()
            .frame(width: 180)
        }
    }

    private var preferredActiveAccountID: UUID? {
        if let lockedAccountID {
            return activeAccounts.first(where: { $0.id == lockedAccountID })?.id
        }
        for preferredID in [defaultAccountID].compactMap({ $0 }) {
            if activeAccounts.contains(where: { $0.id == preferredID }) {
                return preferredID
            }
        }
        return activeAccounts.first?.id
    }

    private func accountPickerRow(_ label: String, selection: Binding<UUID?>, filter: @escaping (Account) -> Bool = { _ in true }) -> some View {
        row(label) {
            Picker(label, selection: selection) {
                ForEach(activeAccounts.filter(filter)) { account in
                    Text(account.displayName).tag(UUID?.some(account.id))
                }
            }
            .labelsHidden()
            .frame(width: 240)
        }
    }

    private var panelDivider: some View {
        Divider().padding(.leading, 132)
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label).frame(width: 116, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func updateCounterparty() {
        if kind == .payment {
            counterpartyAccountID = activeAccounts.first { !$0.type.isLiability && $0.id != accountID }?.id
        } else {
            counterpartyAccountID = activeAccounts.first { $0.id != accountID }?.id
        }
    }

    private func normalizeKindAndCategory() {
        if let account = selectedAccount {
            let kinds = ManualTransactionKind.availableKinds(for: account.type)
            if !kinds.contains(kind) {
                kind = kinds.first ?? .income
            }
        }

        if let category = selectedCategory, !allowedCategoryKinds.contains(category.kind) {
            categoryID = nil
        }
    }

    private func save() {
        if let pendingPropertyTransaction {
            do {
                try persistPropertyAttribution(for: pendingPropertyTransaction)
                self.pendingPropertyTransaction = nil
                propertySaveError = nil
                finishAfterSuccess()
            } catch { propertySaveError = "El movimiento se guardó, pero falló la asociación con la propiedad: \(error.localizedDescription)" }
            return
        }
        var createdTransaction: Transaction?
        do {
            switch kind {
            case .income:
                guard let account = selectedAccount else { throw ManualAccountError.missingAccount }
                createdTransaction = try ManualTransactionService.create(
                    account: account,
                    date: date,
                    description: description,
                    signedAmount: abs(amount),
                    category: selectedCategory,
                    flowKindRaw: TransactionFlowKind.income.rawValue,
                    context: modelContext
                )
            case .expense:
                guard let account = selectedAccount else { throw ManualAccountError.missingAccount }
                createdTransaction = try ManualTransactionService.create(
                    account: account,
                    date: date,
                    description: description,
                    signedAmount: -abs(amount),
                    category: selectedCategory,
                    flowKindRaw: TransactionFlowKind.expense.rawValue,
                    expenseAssignment: expenseAssignment,
                    householdScope: includeInHousehold ? .included : .excluded,
                    context: modelContext
                )
            case .charge:
                guard let account = selectedAccount else { throw ManualAccountError.missingAccount }
                createdTransaction = try ManualTransactionService.create(
                    account: account,
                    date: date,
                    description: description,
                    signedAmount: -abs(amount),
                    category: selectedCategory,
                    flowKindRaw: TransactionFlowKind.charge.rawValue,
                    expenseAssignment: expenseAssignment,
                    householdScope: includeInHousehold ? .included : .excluded,
                    context: modelContext
                )
            case .cardCredit:
                guard let account = selectedAccount else { throw ManualAccountError.missingAccount }
                createdTransaction = try ManualTransactionService.create(
                    account: account,
                    date: date,
                    description: description,
                    signedAmount: abs(amount),
                    category: selectedCategory,
                    flowKindRaw: TransactionFlowKind.cardCredit.rawValue,
                    context: modelContext
                )
            case .payment:
                guard let destination = selectedAccount,
                      let source = accounts.first(where: { $0.id == counterpartyAccountID }),
                      source.id != destination.id else {
                    throw ManualAccountError.missingAccount
                }
                _ = try ManualTransferService.create(
                    from: source,
                    to: destination,
                    date: date,
                    amount: abs(amount),
                    note: description,
                    context: modelContext
                )
            case .transfer:
                guard let source = selectedAccount,
                      let destination = accounts.first(where: { $0.id == counterpartyAccountID }),
                      source.id != destination.id else {
                    throw ManualAccountError.missingAccount
                }
                _ = try ManualTransferService.create(
                    from: source,
                    to: destination,
                    date: date,
                    amount: abs(amount),
                    note: description,
                    context: modelContext
                )
            }
            if let createdTransaction {
                if propertyID != nil {
                    do { try persistPropertyAttribution(for: createdTransaction) }
                    catch {
                        pendingPropertyTransaction = createdTransaction
                        propertySaveError = "El movimiento se guardó, pero falló la asociación con la propiedad: \(error.localizedDescription)"
                        return
                    }
                }
                applyAttributions(to: createdTransaction)
            }
            guard attributionFailure == nil else { return }
            finishAfterSuccess()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func persistPropertyAttribution(for transaction: Transaction) throws {
        guard let propertyID else { return }
        guard transaction.currency == "MXN" else {
            throw PropertyLedgerStore.StoreError.invalid("las liquidaciones de propiedades requieren importes en MXN")
        }
        var ledger = try PropertyLedgerStore.read()
        for index in ledger.attributions.indices where ledger.attributions[index].transactionID == transaction.id
            && ledger.attributions[index].deletedAt == nil {
            ledger.attributions[index].deletedAt = .now
            ledger.attributions[index].updatedAt = .now
        }
        let responsibility: PropertyResponsibility
        if transaction.amount > 0 || (propertyExpenseKind == .maintenance && propertyResponsibility == .shared) {
            responsibility = .owner
        } else {
            switch propertyResponsibility {
            case .shared: responsibility = .shared
            case .owner: responsibility = .owner
            case .individual:
                guard let propertyResidentID else { throw PropertyLedgerStore.StoreError.invalid("elige al residente responsable") }
                responsibility = .individual(residentID: propertyResidentID)
            case .selected:
                guard !propertySelectedResidentIDs.isEmpty else { throw PropertyLedgerStore.StoreError.invalid("elige al menos un residente") }
                responsibility = .selected(residentIDs: propertySelectedResidentIDs.sorted { $0.uuidString < $1.uuidString })
            }
        }
        let attributionKind: PropertyExpenseKind = transaction.amount > 0
            ? (propertyExpenseKind == .reimbursement ? .reimbursement : .operation)
            : propertyExpenseKind
        ledger.attributions.append(PropertyTransactionAttribution(propertyID: propertyID,
            transactionID: transaction.id, kind: attributionKind, responsibility: responsibility,
            maintenanceProgramID: propertyMaintenanceProgramID,
            sourceAmountSnapshot: transaction.amount, sourcePostedAtSnapshot: transaction.postedAt,
            sourceCurrencySnapshot: transaction.currency, sourceDescriptionSnapshot: transaction.descriptionRaw,
            notes: transaction.amount > 0 ? "Cobro registrado; aplica el importe desde Propiedades." : ""))
        try PropertyLedgerStore.replace(with: ledger)
    }
}

// MARK: - Flujo Guardar y nuevo (core puro, testeable)

/// Resuelve qué hace la hoja tras cada desenlace, honrando la intención del
/// botón pulsado (`.close` | `.addAnother`) AUN con fallo parcial de
/// adjudicación: «Reintentar» y «Más tarde» nunca la descartan.
enum SaveAndNewFlow {
    enum Intent: Equatable {
        case close
        case addAnother
    }

    enum Field: Hashable {
        case description
    }

    enum Resolution: Equatable {
        case dismiss
        case resetForm
    }

    /// Éxito completo (tx + adjudicaciones).
    static func resolve(intent: Intent) -> Resolution {
        intent == .addAnother ? .resetForm : .dismiss
    }

    /// Resolución del banner de fallo de adjudicación.
    /// - Reintento exitoso → intención original.
    /// - Reintento aún fallido → nil: seguir esperando (la hoja NO cierra ni
    ///   resetea con un fallo sin resolver).
    /// - «Más tarde» (deferred) → intención original; la adjudicación queda
    ///   recuperable desde el detalle.
    static func resolve(intent: Intent, attributionFailureResolved: Bool) -> Resolution? {
        guard attributionFailureResolved else { return nil }
        return resolve(intent: intent)
    }

}
