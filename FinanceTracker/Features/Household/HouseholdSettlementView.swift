import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct HouseholdSettlementView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var standaloneMonth: YearMonth
    private let workspace: PropertyWorkspaceModel?
    private let workspaceSection: PropertyWorkspaceSection?
    @State private var loadedSetup = HouseholdSettlementSetup.empty
    @State private var loadedDraft: HouseholdSetupDraft?
    @State private var editingMonth = Date.distantPast
    private var selectedMonth: YearMonth {
        get { workspace.map { YearMonth(date: $0.selectedMonth) } ?? standaloneMonth }
        nonmutating set {
            if let workspace { workspace.selectMonth(newValue.startDate) }
            else { standaloneMonth = newValue }
        }
    }
    @State private var monthPickerYear: Int
    @State private var monthPickerMonth: Int
    @State private var showingMonthPicker = false

    @State private var partnerIncome: Decimal = 0
    @State private var useManualSalary = false
    @State private var manualSalary: Decimal = 0
    @State private var splitMethod: HouseholdSplitMethod = .monthlyDefault
    @State private var customUserPercent: Decimal = 50
    @State private var customPartnerPercent: Decimal = 50
    @State private var notes = ""

    @State private var standaloneReport: HouseholdSettlementReport?
    private var report: HouseholdSettlementReport? {
        if let workspace { return workspace.householdReport }
        return standaloneReport
    }
    @State private var standaloneTransactions: [Transaction] = []
    private var monthTransactions: [Transaction] { workspace?.householdTransactions ?? standaloneTransactions }
    @State private var standaloneDueDates: [UUID: Date] = [:]
    private var monthDueDates: [UUID: Date] { workspace?.householdDueDates ?? standaloneDueDates }
    @State private var expandedSections: Set<HouseholdTransactionSectionState.ID> = []
    @State private var selectionMode = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var saveError: String?
    @State private var dueDatePickerTxID: UUID?
    @State private var showingExporter = false
    @State private var saveStatus = "Guardado"
    @State private var showingClearConfirmation = false
    @State private var isLoadingSetup = false
    @State private var pendingSaveTask: Task<Void, Never>?

    private let presenter = HouseholdSettlementPresenter()
    private let onReviewTransactions: ((YearMonth) -> Void)?
    private let onSelectedMonthChange: ((YearMonth) -> Void)?

    init(initialSelectedMonth: YearMonth? = nil, onReviewTransactions: ((YearMonth) -> Void)? = nil,
         onSelectedMonthChange: ((YearMonth) -> Void)? = nil) {
        let month = initialSelectedMonth ?? YearMonth(date: .now)
        _standaloneMonth = State(initialValue: month)
        _monthPickerYear = State(initialValue: month.year)
        _monthPickerMonth = State(initialValue: month.month)
        self.onReviewTransactions = onReviewTransactions
        self.onSelectedMonthChange = onSelectedMonthChange
        self.workspace = nil
        self.workspaceSection = nil
    }

    init(workspace: PropertyWorkspaceModel, section: PropertyWorkspaceSection,
         onReviewTransactions: ((YearMonth) -> Void)? = nil) {
        let month = YearMonth(date: workspace.selectedMonth)
        _standaloneMonth = State(initialValue: month)
        _monthPickerYear = State(initialValue: month.year)
        _monthPickerMonth = State(initialValue: month.month)
        self.workspace = workspace
        self.workspaceSection = section
        self.onReviewTransactions = onReviewTransactions
        self.onSelectedMonthChange = nil
    }

    private var setup: HouseholdSettlementSetup {
        HouseholdSettlementSetup(
            partnerIncomeEstimate: partnerIncome,
            useUserIncomeManualOverride: useManualSalary,
            userIncomeManualOverride: useManualSalary ? manualSalary : nil,
            splitMethod: splitMethod,
            customUserPercent: splitMethod == .customPercent ? customUserPercent : nil,
            customPartnerPercent: splitMethod == .customPercent ? customPartnerPercent : nil,
            notes: notes.isEmpty ? nil : notes
        )
    }

    private var draftSnapshot: HouseholdSetupDraft {
        HouseholdSetupDraft(partnerIncome: partnerIncome, useManualSalary: useManualSalary,
            manualSalary: manualSalary, splitMethod: splitMethod, userPercent: customUserPercent,
            partnerPercent: customPartnerPercent, notes: notes)
    }

    private var setupIsValid: Bool {
        partnerIncome >= 0
            && (!useManualSalary || manualSalary >= 0)
            && (splitMethod != .customPercent || (customUserPercent >= 0 && customPartnerPercent >= 0 && customUserPercent + customPartnerPercent == 100))
    }

    var body: some View {
        Group {
            if workspace != nil { embeddedContent }
            else { standaloneContent }
        }
        .toolbar {
            if workspace == nil {
            ToolbarItemGroup(placement: .primaryAction) {
                if onReviewTransactions != nil {
                    Button { onReviewTransactions?(selectedMonth) } label: {
                        Label("Review transactions", systemImage: "list.bullet.rectangle.portrait")
                    }
                    .accessibilityIdentifier("household.reviewTransactions.button")
                }
                if let report {
                    Button { copy(report) } label: {
                        Label("Copy Summary", systemImage: "doc.on.doc")
                    }
                    .accessibilityIdentifier("household.copySummary.button")
                    ShareLink(item: report.plainTextSummary) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    Button { showingExporter = true } label: {
                        Label("Export", systemImage: "square.and.arrow.down")
                    }
                    .accessibilityIdentifier("household.export.button")
                }
            }
            }
        }
        .fileExporter(
            isPresented: $showingExporter,
            document: SettlementTextFile(text: report?.plainTextSummary ?? ""),
            contentType: .plainText,
            defaultFilename: "Household Settlement \(selectedMonth.fileNameComponent).txt"
        ) { _ in }
        .alert("Couldn’t save", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
        .onAppear { loadSetupAndReport() }
        .onDisappear {
            flushPendingSetup()
            if !setupIsValid { workspace?.discardHouseholdDraft() }
        }
        .onChange(of: workspace?.inputRevision) {
            if loadedDraft == draftSnapshot { loadSetupAndReport() }
            else { recomputeReport() }
        }
        .onChange(of: selectedMonth) {
            flushPendingSetup()
            // Avoid assigning across months: leave selection mode before reloading.
            selectionMode = false
            selectedIDs.removeAll()
            onSelectedMonthChange?(selectedMonth)
            loadSetupAndReport()
        }
        .onChange(of: partnerIncome) { setupChanged() }
        .onChange(of: useManualSalary) { setupChanged() }
        .onChange(of: manualSalary) { setupChanged() }
        .onChange(of: splitMethod) { setupChanged() }
        .onChange(of: customUserPercent) { setupChanged() }
        .onChange(of: customPartnerPercent) { setupChanged() }
        .onChange(of: notes) { setupChanged() }
    }

    private var standaloneContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let report {
                    header(screenState(for: report))
                    monthlySetup(screenState(for: report).monthlySetup)
                    if report.hasIncludedTransactions {
                        let state = screenState(for: report)
                        warnings(state.warning)
                        resultCard(state.summary)
                        breakdown(state.summary)
                        transactionsHeader(state)
                        ForEach(state.transactionSections) { section in
                            transactionSection(section)
                        }
                    } else {
                        emptyState
                    }
                } else {
                    header(nil)
                }
            }
            .frame(maxWidth: 1120, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.horizontal)
            .padding(.top, 10)
            .padding(.bottom)
        }
        .navigationTitle(HouseholdSettlementPresenter.navigationTitle)
        .accessibilityIdentifier("household.screen")
    }

    @ViewBuilder
    private var embeddedContent: some View {
        if let report {
            let state = screenState(for: report)
            VStack(alignment: .leading, spacing: 20) {
                switch workspaceSection {
                case .configuration:
                    PropertySectionHeading(title: "Integrantes e ingresos")
                    PropertyPeopleList(people: PropertyPresentationAdapter.household(report).people)
                    monthlySetup(state.monthlySetup)
                default:
                    PropertySummaryPanel(presentation: PropertyPresentationAdapter.household(report)) {
                        workspace?.section = .month
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("properties.household.detail")
        } else {
            ProgressView("Cargando el reporte de la casa…")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func screenState(for report: HouseholdSettlementReport) -> HouseholdSettlementScreenState {
        presenter.state(
            selectedMonth: selectedMonth,
            setup: setup,
            report: report,
            validation: validationState(for: report),
            saveStatus: saveStatus
        )
    }

    private func validationState(for report: HouseholdSettlementReport) -> HouseholdSettlementValidationState {
        HouseholdSettlementValidationState.make(
            setup: setup,
            report: report,
            customSplitIsValid: splitMethod != .customPercent
                || (customUserPercent >= 0 && customPartnerPercent >= 0 && customUserPercent + customPartnerPercent == 100),
            canSave: setupIsValid
        )
    }

    private func header(_ state: HouseholdSettlementScreenState?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                    Button { shiftMonth(-1) } label: {
                        Image(systemName: "chevron.left")
                    }
                    .controlSize(.large)
                    .help("Previous month")
                    .accessibilityIdentifier("household.month.previous")
                    Button {
                        monthPickerYear = selectedMonth.year
                        monthPickerMonth = selectedMonth.month
                        showingMonthPicker = true
                    } label: {
                        Text(state?.reportMonthTitle ?? selectedMonth.displayName)
                            .font(.largeTitle.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("household.month.heading")
                    .popover(isPresented: $showingMonthPicker) {
                        monthPicker
                    }
                    Button { shiftMonth(1) } label: {
                        Image(systemName: "chevron.right")
                    }
                    .controlSize(.large)
                    .help("Next month")
                    .accessibilityIdentifier("household.month.next")
                    if selectedMonth.isCurrentMonth {
                        Text("Current Month")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.blue.opacity(0.12), in: Capsule())
                    }
                Spacer(minLength: 8)
                Text(saveStatus)
                    .font(.caption)
                    .foregroundStyle(saveStatus == "Guardado" ? Color.secondary : Color.orange)
                    .fixedSize()
            }
            Text(state?.subtitle ?? String(localized: "Review Household expenses you explicitly included — Mine, Shared, and Fer."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("household.subtitle")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var monthPicker: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Month", selection: $monthPickerMonth) {
                ForEach(1...12, id: \.self) { month in
                    Text(monthName(month)).tag(month)
                }
            }
            Picker("Year", selection: $monthPickerYear) {
                ForEach((selectedMonth.year - 6)...(selectedMonth.year + 6), id: \.self) { year in
                    Text(String(year)).tag(year)
                }
            }
            HStack {
                Button("Cancel") { showingMonthPicker = false }
                Spacer()
                Button("Apply") {
                    selectedMonth = YearMonth(year: monthPickerYear, month: monthPickerMonth)
                    showingMonthPicker = false
                }
                .buttonStyle(.glassProminent)
            }
        }
        .padding(16)
        .frame(width: 260)
    }

    private func monthlySetup(_ state: HouseholdMonthlySetupState) -> some View {
        PropertyFormSection(title: state.title) {
            VStack(spacing: 0) {
                setupRow(state.userSalaryLabel) {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(state.userSalaryValue)
                            .font(.callout.weight(.medium))
                            .monospacedDigit()
                            .accessibilityIdentifier("household.userSalary.value")
                        Text(state.userSalaryHelper)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if state.showsManualSalaryOverrideButton {
                    // Misma geometría que setupRow (label 200 + valor ≤320):
                    // el botón ancla a la guía de la columna de valores.
                    HStack(spacing: 12) {
                        Color.clear.frame(width: workspace == nil ? 200 : 120)
                        HStack {
                            Spacer(minLength: 0)
                            Button("Use Manual Override") {
                                useManualSalary = true
                            }
                            .accessibilityIdentifier("household.userSalary.overrideButton")
                        }
                        .frame(maxWidth: 320, alignment: .trailing)
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                }
                if state.showsManualSalaryInput {
                    divider
                    setupRow(state.manualSalaryLabel) {
                        VStack(alignment: .trailing, spacing: 3) {
                            TextField("$0.00", value: $manualSalary, format: .currency(code: "MXN"))
                                .textFieldStyle(.plain)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                            Text(state.manualSalaryHelper)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                divider
                setupRow(state.partnerIncomeLabel) {
                    VStack(alignment: .trailing, spacing: 3) {
                        TextField("$0.00", value: $partnerIncome, format: .currency(code: "MXN"))
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .accessibilityIdentifier("household.partnerIncome.input")
                        Text(state.partnerIncomeHelper)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                divider
                setupRow(state.splitLabel) {
                    Picker("Split", selection: $splitMethod) {
                        Text("Proportional by income")
                            .tag(HouseholdSplitMethod.monthlyDefault)
                            .accessibilityIdentifier("household.split.proportional")
                        Text("50/50")
                            .tag(HouseholdSplitMethod.fiftyFifty)
                            .accessibilityIdentifier("household.split.fiftyFifty")
                        Text("Custom")
                            .tag(HouseholdSplitMethod.customPercent)
                            .accessibilityIdentifier("household.split.custom")
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 460, alignment: .trailing)
                    .accessibilityIdentifier("household.split.picker")
                }
                if splitMethod == .customPercent {
                    divider
                    setupRow(state.customSplitLabel) {
                        HStack(spacing: 12) {
                            percentField("Your share", value: $customUserPercent)
                            percentField("Fer share", value: $customPartnerPercent)
                        }
                    }
                    if let error = state.customSplitError {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 8)
                    }
                }
                divider
                setupRow(state.notesLabel) {
                    TextField("Optional", text: $notes)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("household.notes.input")
                }
                divider
                HStack {
                    Button(state.copyPreviousTitle) { copyPreviousMonth() }
                        .accessibilityIdentifier("household.partnerIncome.copyPrevious")
                    Button(state.clearTitle, role: .destructive) { showingClearConfirmation = true }
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("household.partnerIncome.clear")
                    Spacer()
                    if let setupError = state.setupStatusText {
                        Text(setupError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(14)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("household.setup.card")
        .confirmationDialog(state.clearTitle, isPresented: $showingClearConfirmation, titleVisibility: .visible) {
            Button(state.clearTitle, role: .destructive) { clearSetup() }
        } message: {
            Text("Se borrará la configuración de este mes; los movimientos no se tocan.")
        }
    }

    @ViewBuilder
    private func warnings(_ warning: HouseholdWarningState?) -> some View {
        if let warning {
            VStack(alignment: .leading, spacing: 8) {
                Text(warning.title)
                    .font(.headline)
                ForEach(warning.messages, id: \.self) { message in
                    Text(message)
                        .font(.callout)
                }
            }
            .foregroundStyle(.orange)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No household expenses included for this month.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button {
                onReviewTransactions?(selectedMonth)
            } label: {
                Label("Review transactions", systemImage: "list.bullet.rectangle.portrait")
            }
            .buttonStyle(.glassProminent)
            .accessibilityIdentifier("household.empty.reviewTransactions")
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("household.empty.state")
    }

    private func resultCard(_ state: HouseholdSettlementSummaryState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(state.resultLabel)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(state.recoverAmount)
                .font(.system(size: 42, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.orange)
                .accessibilityIdentifier("household.summary.recoverFromFer")
            Text(state.resultDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(state.recoveryComposition)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("household.summary.recoveryComposition")
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private func breakdown(_ state: HouseholdSettlementSummaryState) -> some View {
        PropertyFormSection(title: state.breakdownTitle) {
            VStack(spacing: 0) {
                ForEach(Array(state.breakdownLines.enumerated()), id: \.element.id) { index, line in
                    if index == 1 || index == 5 { divider }
                    labelLine(line.label, line.value, accessibilityIdentifier: line.id.rawValue)
                }
            }
        }
    }

    private func transactionSection(_ state: HouseholdTransactionSectionState) -> some View {
        let isExpanded = expandedSections.contains(state.id)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                toggleSection(state.id)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "chevron.right")
                        .font(.title3.weight(.semibold))
                        .frame(width: 20)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.snappy, value: isExpanded)
                    Text(state.title)
                        .font(.headline)
                        .accessibilityIdentifier("\(state.id.rawValue).header")
                    Text(state.countText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(state.subtotal)
                        .font(.callout.weight(.semibold))
                        .monospacedDigit()
                }
                .contentShape(Rectangle())
                .padding(16)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("\(state.id.rawValue).disclosure")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            if isExpanded && !state.rows.isEmpty {
                transactionRows(state.rows)
            }
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier(state.id.rawValue)
    }

    private func toggleSection(_ id: HouseholdTransactionSectionState.ID) {
        if expandedSections.contains(id) {
            expandedSections.remove(id)
        } else {
            expandedSections.insert(id)
        }
    }

    private func transactionRows(_ rows: [HouseholdTransactionRowState]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(rows) { row in
                householdTransactionRow(row)
                if row.id != rows.last?.id { divider }
            }
        }
    }

    private func householdTransactionRow(_ state: HouseholdTransactionRowState) -> some View {
        let tx = state.row.transaction
        return HStack(alignment: .center, spacing: 12) {
            if selectionMode {
                Toggle("", isOn: Binding(
                    get: { selectedIDs.contains(tx.id) },
                    set: { isSelected in
                        if isSelected { selectedIDs.insert(tx.id) } else { selectedIDs.remove(tx.id) }
                    }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityIdentifier("household.row.checkbox")
            }
            Text(tx.postedAt, format: .dateTime.day().month(.abbreviated))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(tx.merchantNormalized.isEmpty ? tx.descriptionRaw : tx.merchantNormalized)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(state.metadata)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(state.amount)
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                if !selectionMode && state.showsDueDatePicker {
                    // Fer rows: status is a clickable chip that opens a popover to
                    // edit the due date. The chip itself always states the current
                    // settlement month, so the row reads clearly without an editor.
                    Button {
                        dueDatePickerTxID = dueDatePickerTxID == tx.id ? nil : tx.id
                    } label: {
                        HStack(spacing: 3) {
                            Text(state.status)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                        }
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(state.deferredToMonth == nil ? Color.secondary : Color.orange)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("household.row.dueDate.toggle")
                    .popover(isPresented: Binding(
                        get: { dueDatePickerTxID == tx.id },
                        set: { if !$0 { dueDatePickerTxID = nil } }
                    )) {
                        dueDatePopover(for: tx, current: state.dueDate)
                    }
                } else {
                    Text(state.status)
                        .font(.caption2)
                        .foregroundStyle(state.deferredToMonth == nil ? Color.secondary : Color.orange)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func dueDatePopover(for tx: Transaction, current: Date?) -> some View {
        // Min date is the purchase calendar day — a due date can't precede the charge.
        let postedDay = Calendar(identifier: .gregorian).startOfDay(for: tx.postedAt)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Fecha de cobro")
                .font(.headline)
            Text("Cuándo le cobras esta compra a Fer. Si cae en otro mes, se suma a ese mes en vez de este.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DatePicker(
                "Cobra en",
                selection: Binding(
                    get: { current ?? postedDay },
                    set: { newDate in setDueDate(tx, newDate) }
                ),
                in: postedDay...,
                displayedComponents: .date
            )
            .datePickerStyle(.field)
            .labelsHidden()
            .accessibilityIdentifier("household.row.dueDate")
            if current != nil {
                Button {
                    setDueDate(tx, nil)
                    dueDatePickerTxID = nil
                } label: {
                    Label("Mismo mes de compra", systemImage: "arrow.uturn.backward")
                        .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("household.row.dueDate.reset")
            }
        }
        .padding(16)
        .frame(width: 280)
    }

    private func transactionsHeader(_ state: HouseholdSettlementScreenState) -> some View {
        HStack(spacing: 12) {
            Text("Transactions")
                .font(.headline)
                .accessibilityIdentifier("household.transactionsHeader.title")
            if selectionMode {
                Text("\(selectedIDs.count) seleccionados")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                ControlGroup {
                    Button("Mine") { applyAssignment(.user) }
                        .disabled(selectedIDs.isEmpty)
                    Button("Shared") { applyAssignment(.shared) }
                        .disabled(selectedIDs.isEmpty)
                    Button("Fer") { applyAssignment(.partner) }
                        .disabled(selectedIDs.isEmpty)
                }
                .accessibilityIdentifier("household.bulkAssign")
            } else {
                Spacer()
            }
            Button(selectionMode ? "Done" : "Select") {
                selectionMode.toggle()
                if !selectionMode { selectedIDs.removeAll() }
            }
            .accessibilityIdentifier("household.selectToggle")
        }
        .padding(.horizontal, 4)
    }

    private func setupRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        // Columnas compartidas: la etiqueta ancla a la izquierda y el valor a
        // la MISMA guía vertical derecha en todas las filas; el fallback
        // vertical cubre ventanas angostas.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                Text(label)
                    .frame(width: workspace == nil ? 200 : 120, alignment: .leading)
                content()
                    .frame(maxWidth: 320, alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(label).foregroundStyle(.secondary)
                content().frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func percentField(_ label: String, value: Binding<Decimal>) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("50", value: value, format: .number)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .frame(width: 54)
            Text("%")
                .foregroundStyle(.secondary)
        }
    }

    private func labelLine(_ label: String, _ value: String, accessibilityIdentifier: String? = nil) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.callout.weight(.medium))
                .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .accessibilityIdentifier(accessibilityIdentifier ?? "")
    }

    private var divider: some View {
        Divider().padding(.leading, 14)
    }

    private func shiftMonth(_ offset: Int) {
        selectedMonth = selectedMonth.addingMonths(offset)
    }

    private func monthName(_ month: Int) -> String {
        Calendar(identifier: .gregorian).monthSymbols[month - 1]
    }

    private func loadSetupAndReport() {
        isLoadingSetup = true
        let monthStart = selectedMonth.startDate
        var savedSetup: HouseholdSettlementSetup
        if let workspace { savedSetup = workspace.persistedHouseholdSetup }
        else { savedSetup = HouseholdSettlementSetup(HouseholdPartnerIncomeService.estimate(for: monthStart, context: modelContext)) }
        if savedSetup.notes?.isEmpty == true { savedSetup.notes = nil }
        loadedSetup = savedSetup
        editingMonth = monthStart
        partnerIncome = savedSetup.partnerIncomeEstimate
        useManualSalary = savedSetup.useUserIncomeManualOverride
        manualSalary = savedSetup.userIncomeManualOverride ?? 0
        splitMethod = savedSetup.splitMethod
        customUserPercent = savedSetup.customUserPercent ?? 50
        customPartnerPercent = savedSetup.customPartnerPercent ?? 50
        notes = savedSetup.notes ?? ""
        loadedDraft = draftSnapshot
        // Seed the editable list AND the due-date cache from the full report input
        // (posted-in-month + older Fer tx whose due date lands here). Seeding
        // monthTransactions from the full set keeps subsequent recomputeReport()
        // rebuilds from dropping the older pulled-in rows.
        if let workspace {
            standaloneTransactions = workspace.householdTransactions
            standaloneDueDates = workspace.householdDueDates
            standaloneReport = workspace.householdReport
        } else {
            let input = HouseholdSettlementReportService.reportInput(for: monthStart, context: modelContext)
            standaloneTransactions = input.transactions
            standaloneDueDates = input.dueDates
            standaloneReport = HouseholdSettlementReportService.build(monthStart: monthStart, transactions: input.transactions, dueDates: input.dueDates, setup: savedSetup)
        }
        saveStatus = "Guardado"
        isLoadingSetup = false
    }

    private func setupChanged() {
        pendingSaveTask?.cancel()
        guard !isLoadingSetup, editingMonth == selectedMonth.startDate else { return }
        guard draftSnapshot != loadedDraft else {
            saveStatus = "Guardado"
            if let workspace {
                if workspace.selectedMonth == editingMonth { workspace.updateHouseholdSetup(loadedSetup) }
            } else {
                standaloneReport = HouseholdSettlementReportService.build(monthStart: editingMonth,
                    transactions: monthTransactions, dueDates: monthDueDates, setup: loadedSetup)
            }
            return
        }
        recomputeReport()
        scheduleSave()
    }

    private func recomputeReport() {
        if let workspace {
            guard workspace.selectedMonth == editingMonth else { return }
            workspace.updateHouseholdSetup(setup)
        } else {
            standaloneReport = HouseholdSettlementReportService.build(monthStart: selectedMonth.startDate,
                transactions: monthTransactions, dueDates: monthDueDates, setup: setup)
        }
    }

    private func scheduleSave() {
        pendingSaveTask?.cancel()
        saveStatus = "Cambios sin guardar"
        guard setupIsValid else { return }
        let month = editingMonth
        let setupToSave = setup
        let snapshot = draftSnapshot
        pendingSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, editingMonth == month, draftSnapshot == snapshot else { return }
            saveSetup(month: month, setup: setupToSave)
        }
    }

    private func flushPendingSetup() {
        pendingSaveTask?.cancel()
        guard editingMonth != .distantPast, draftSnapshot != loadedDraft, setupIsValid else { return }
        saveSetup(month: editingMonth, setup: setup)
    }

    private func saveSetup(month: Date? = nil, setup setupToSave: HouseholdSettlementSetup? = nil) {
        let value = setupToSave ?? setup
        let month = month ?? editingMonth
        guard value.partnerIncomeEstimate >= 0,
              value.splitMethod != .customPercent || ((value.customUserPercent ?? 0) >= 0
                && (value.customPartnerPercent ?? 0) >= 0
                && (value.customUserPercent ?? 0) + (value.customPartnerPercent ?? 0) == 100) else { return }
        do {
            try HouseholdWorkspacePersistence.save(value, month: month, container: modelContext.container)
            loadedSetup = value
            loadedDraft = draftSnapshot
            workspace?.commitHouseholdSetup(value, month: month)
            saveStatus = "Guardado"
        } catch {
            saveStatus = "No se guardaron los cambios"
            saveError = error.localizedDescription
            workspace?.error = error.localizedDescription
            workspace?.updateHouseholdSetup(loadedSetup)
        }
    }

    private func copyPreviousMonth() {
        guard let previous = HouseholdPartnerIncomeService.estimate(for: selectedMonth.addingMonths(-1).startDate, context: modelContext) else {
            return
        }
        let previousSetup = HouseholdSettlementSetup(previous)
        partnerIncome = previousSetup.partnerIncomeEstimate
        splitMethod = previousSetup.splitMethod
        customUserPercent = previousSetup.customUserPercent ?? 50
        customPartnerPercent = previousSetup.customPartnerPercent ?? 50
        if notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            notes = previousSetup.notes ?? ""
        }
        recomputeReport()
        scheduleSave()
    }

    private func clearSetup() {
        partnerIncome = 0
        useManualSalary = false
        manualSalary = 0
        splitMethod = .monthlyDefault
        customUserPercent = 50
        customPartnerPercent = 50
        notes = ""
    }

    private func applyAssignment(_ assignment: ExpenseAssignment) {
        guard !selectedIDs.isEmpty else { return }
        var purgedDueDateIDs: Set<UUID> = []
        for tx in monthTransactions where selectedIDs.contains(tx.id) {
            // Reassigning away from Fer clears any due-date override (no value keeping
            // one for a non-Fer row). Exclusion alone preserves a latent override.
            if assignment != .partner, tx.resolvedHouseholdAllocation == .partner {
                purgedDueDateIDs.insert(tx.id)
            }
            tx.setExpenseAssignment(assignment)
            tx.touch()
        }
        do {
            try modelContext.save()
            if !purgedDueDateIDs.isEmpty {
                try SettlementDueDateService.purge(for: purgedDueDateIDs, context: modelContext)
            }
        } catch {
            modelContext.rollback()
            saveError = "Couldn’t save assignment. Reverting."
            return
        }
        selectedIDs.removeAll()
        selectionMode = false
        reloadReportInput()
    }

    private func setDueDate(_ tx: Transaction, _ date: Date?) {
        do {
            try SettlementDueDateService.setDueDate(date, for: tx.id, context: modelContext)
        } catch {
            modelContext.rollback()
            saveError = "Couldn’t save due date. Reverting."
            return
        }
        // Reload from the full input — a due-date change can move a Fer row between
        // the posted-in-month and deferred-into-month fetch sets. Uses a transaction-
        // only reload so unsaved monthly-setup fields are not overwritten.
        reloadReportInput()
    }

    /// Rebuilds the report from the full input (with due dates) without disturbing
    /// the editable monthly-setup @State fields.
    private func reloadReportInput() {
        if let workspace {
            let month = editingMonth
            let editedSetup = setup
            Task {
                await workspace.refreshPeriod(force: true)
                if workspace.selectedMonth == month { workspace.updateHouseholdSetup(editedSetup) }
            }
        } else {
            let input = HouseholdSettlementReportService.reportInput(for: selectedMonth.startDate, context: modelContext)
            standaloneTransactions = input.transactions
            standaloneDueDates = input.dueDates
            recomputeReport()
        }
    }

    private func copy(_ report: HouseholdSettlementReport) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.plainTextSummary, forType: .string)
    }
}

struct SettlementTextFile: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        text = ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

#Preview("Household Settlement Fixture") {
    NavigationStack {
        HouseholdSettlementView(initialSelectedMonth: HouseholdSettlementFixture.month)
    }
    .modelContainer(HouseholdSettlementFixture.makePreviewContainer())
}
