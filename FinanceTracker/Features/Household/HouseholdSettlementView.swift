import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct HouseholdSettlementView: View {
    @Environment(\.modelContext) private var modelContext

    var onReviewTransactions: () -> Void = {}

    @State private var selectedMonth = YearMonth(date: .now)
    @State private var monthPickerYear = YearMonth(date: .now).year
    @State private var monthPickerMonth = YearMonth(date: .now).month
    @State private var showingMonthPicker = false

    @State private var partnerIncome: Decimal = 0
    @State private var useManualSalary = false
    @State private var manualSalary: Decimal = 0
    @State private var splitMethod: HouseholdSplitMethod = .monthlyDefault
    @State private var customUserPercent: Decimal = 50
    @State private var customPartnerPercent: Decimal = 50
    @State private var notes = ""

    @State private var report: HouseholdSettlementReport?
    @State private var monthTransactions: [Transaction] = []
    @State private var selectedTransactionIDs: Set<UUID> = []
    @State private var showingPersonalExpenses = false
    @State private var showingExporter = false
    @State private var saveStatus = "Saved"
    @State private var isLoadingSetup = false
    @State private var pendingSaveTask: Task<Void, Never>?

    private var setup: HouseholdSettlementSetup {
        HouseholdSettlementSetup(
            partnerIncomeEstimate: partnerIncome,
            useUserIncomeManualOverride: useManualSalary,
            userIncomeManualOverride: useManualSalary ? manualSalary : nil,
            splitMethod: splitMethod,
            customUserPercent: splitMethod == .customPercent ? customUserPercent : nil,
            customPartnerPercent: splitMethod == .customPercent ? customPartnerPercent : nil,
            notes: notes
        )
    }

    private var setupIsValid: Bool {
        partnerIncome >= 0
            && (!useManualSalary || manualSalary >= 0)
            && (splitMethod != .customPercent || (customUserPercent >= 0 && customPartnerPercent >= 0 && customUserPercent + customPartnerPercent == 100))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                if let report {
                    monthlySetup(report)
                    warnings(report)
                    resultCard(report)
                    breakdown(report)
                    unassignedSection(report)
                    transactionSection(
                        title: "Shared expenses",
                        emptyTitle: "No shared expenses marked for \(selectedMonth.displayName).",
                        emptyDescription: "Mark transactions as Shared to include them in this report.",
                        rows: report.sharedRows
                    )
                    transactionSection(
                        title: "Fer-only expenses",
                        emptyTitle: "No Fer-only expenses marked for \(selectedMonth.displayName).",
                        emptyDescription: "Use this section for expenses you paid that belong fully to Fer.",
                        rows: report.partnerRows
                    )
                    DisclosureGroup("Personal expenses excluded from settlement", isExpanded: $showingPersonalExpenses) {
                        transactionRows(report.excludedPersonalRows, mode: .personal)
                    }
                    .padding(16)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.horizontal)
            .padding(.top, 10)
            .padding(.bottom)
        }
        .navigationTitle("Household Settlement")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let report {
                    Button { copy(report) } label: {
                        Label("Copy Summary", systemImage: "doc.on.doc")
                    }
                    ShareLink(item: report.plainTextSummary) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    Button { showingExporter = true } label: {
                        Label("Export", systemImage: "square.and.arrow.down")
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
        .onAppear { loadSetupAndReport() }
        .onChange(of: selectedMonth) { loadSetupAndReport() }
        .onChange(of: partnerIncome) { setupChanged() }
        .onChange(of: useManualSalary) { setupChanged() }
        .onChange(of: manualSalary) { setupChanged() }
        .onChange(of: splitMethod) { setupChanged() }
        .onChange(of: customUserPercent) { setupChanged() }
        .onChange(of: customPartnerPercent) { setupChanged() }
        .onChange(of: notes) { setupChanged() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Button { shiftMonth(-1) } label: {
                        Image(systemName: "chevron.left")
                    }
                    .controlSize(.large)
                    .help("Previous month")
                    Button {
                        monthPickerYear = selectedMonth.year
                        monthPickerMonth = selectedMonth.month
                        showingMonthPicker = true
                    } label: {
                        Text(selectedMonth.displayName)
                            .font(.largeTitle.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("household-settlement-month-heading")
                    .popover(isPresented: $showingMonthPicker) {
                        monthPicker
                    }
                    Button { shiftMonth(1) } label: {
                        Image(systemName: "chevron.right")
                    }
                    .controlSize(.large)
                    .help("Next month")
                    if selectedMonth.isCurrentMonth {
                        Text("Current Month")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.blue.opacity(0.12), in: Capsule())
                    }
                }
                Text("Review shared and Fer-only expenses paid from your accounts.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(saveStatus)
                .font(.caption)
                .foregroundStyle(saveStatus == "Saved" ? Color.secondary : Color.orange)
        }
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

    private func monthlySetup(_ report: HouseholdSettlementReport) -> some View {
        SectionCard(title: "Monthly Setup") {
            VStack(spacing: 0) {
                setupRow("Your salary income") {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(HouseholdSettlementReport.money(report.detectedUserSalaryIncome))
                            .font(.callout.weight(.medium))
                            .monospacedDigit()
                        Text(report.detectedUserSalaryIncome == 0 ? "No salary income detected for this month." : "Detected from salary/compensation transactions only.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if report.detectedUserSalaryIncome == 0 && !useManualSalary {
                    Button("Use Manual Override") {
                        useManualSalary = true
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                }
                if useManualSalary {
                    divider
                    setupRow("Manual salary override") {
                        VStack(alignment: .trailing, spacing: 3) {
                            TextField("0.00", value: $manualSalary, format: .number)
                                .textFieldStyle(.plain)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                            Text("Used only for this settlement report.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                divider
                setupRow("Fer income estimate") {
                    VStack(alignment: .trailing, spacing: 3) {
                        TextField("0.00", value: $partnerIncome, format: .number)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                        Text("Manual monthly estimate. Used only for this report.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                divider
                setupRow("Split") {
                    Picker("Split", selection: $splitMethod) {
                        Text("Proportional by income").tag(HouseholdSplitMethod.monthlyDefault)
                        Text("50/50").tag(HouseholdSplitMethod.fiftyFifty)
                        Text("Custom").tag(HouseholdSplitMethod.customPercent)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 420)
                }
                if splitMethod == .customPercent {
                    divider
                    setupRow("Custom split") {
                        HStack(spacing: 12) {
                            percentField("Your share", value: $customUserPercent)
                            percentField("Fer share", value: $customPartnerPercent)
                        }
                    }
                    if customUserPercent + customPartnerPercent != 100 {
                        Text("Custom split must add to 100%.")
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 8)
                    }
                }
                divider
                setupRow("Notes") {
                    TextField("Optional", text: $notes)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                }
                divider
                HStack {
                    Button("Copy Previous Month") { copyPreviousMonth() }
                    Button("Clear") { clearSetup() }
                    Spacer()
                    Text(setupIsValid ? saveStatus : "Fix setup to save")
                        .font(.caption)
                        .foregroundStyle(setupIsValid ? Color.secondary : Color.red)
                }
                .padding(14)
            }
        }
    }

    @ViewBuilder
    private func warnings(_ report: HouseholdSettlementReport) -> some View {
        if !report.warnings.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Income assumptions need attention")
                    .font(.headline)
                ForEach(report.warnings, id: \.self) { warning in
                    Text(warning)
                        .font(.callout)
                }
            }
            .foregroundStyle(.orange)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func resultCard(_ report: HouseholdSettlementReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("To recover from Fer")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(HouseholdSettlementReport.money(report.amountToRecoverFromPartner))
                .font(.system(size: 42, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.orange)
            Text("Based on shared expenses and Fer-only expenses paid by you.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func breakdown(_ report: HouseholdSettlementReport) -> some View {
        SectionCard(title: "Breakdown") {
            VStack(spacing: 0) {
                amountLine("Total paid by you", report.totalPaidByUser)
                divider
                amountLine("Shared expenses", report.totalSharedExpenses)
                amountLine("Fer shared portion", report.partnerFairShare)
                amountLine("Fer-only paid by you", report.partnerOnlyTotal)
                amountLine("Your final cost", report.userFinalCost)
                divider
                amountLine("Your salary income", report.userSalaryIncome)
                amountLine("Fer income estimate", report.partnerIncomeEstimate)
                labelLine("Split", report.splitLabel)
            }
        }
    }

    private func unassignedSection(_ report: HouseholdSettlementReport) -> some View {
        SectionCard(title: "Unassigned expenses this month") {
            if report.unassignedRows.isEmpty {
                emptyState(
                    title: "No unassigned expenses for \(selectedMonth.displayName).",
                    description: "New expenses that need household classification will appear here.",
                    actionTitle: "Review \(selectedMonth.displayName) Transactions"
                )
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Text("\(report.unassignedRows.count) expense\(report.unassignedRows.count == 1 ? "" : "s") to classify")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        ControlGroup {
                            Button("Mine") { bulkAssign(.user) }
                            Button("Shared") { bulkAssign(.shared) }
                            Button("Fer") { bulkAssign(.partner) }
                        }
                        .controlSize(.small)
                        .disabled(selectedTransactionIDs.isEmpty)
                    }
                    .padding(14)
                    divider
                    transactionRows(report.unassignedRows, mode: .unassigned)
                }
            }
        }
    }

    private func transactionSection(title: String, emptyTitle: String, emptyDescription: String, rows: [HouseholdSettlementRow]) -> some View {
        SectionCard(title: title) {
            if rows.isEmpty {
                emptyState(title: emptyTitle, description: emptyDescription, actionTitle: title == "Shared expenses" ? "Review \(selectedMonth.displayName) Transactions" : nil)
            } else {
                transactionRows(rows, mode: title == "Shared expenses" ? .shared : .partner)
            }
        }
    }

    @ViewBuilder
    private func transactionRows(_ rows: [HouseholdSettlementRow], mode: HouseholdRowMode) -> some View {
        if rows.isEmpty {
            Text("No personal expenses excluded.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(14)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(rows) { row in
                    householdTransactionRow(row, mode: mode)
                    if row.id != rows.last?.id { divider }
                }
            }
        }
    }

    private func householdTransactionRow(_ row: HouseholdSettlementRow, mode: HouseholdRowMode) -> some View {
        let tx = row.transaction
        return HStack(alignment: .center, spacing: 12) {
            if mode == .unassigned {
                Toggle("", isOn: Binding(
                    get: { selectedTransactionIDs.contains(tx.id) },
                    set: { isOn in toggleSelection(tx, selected: isOn) }
                ))
                .labelsHidden()
                .frame(width: 24)
            }
            Text(tx.postedAt, format: .dateTime.day().month(.abbreviated))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(tx.merchantNormalized.isEmpty ? tx.descriptionRaw : tx.merchantNormalized)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(rowMetadata(row, mode: mode))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(HouseholdSettlementReport.money(row.amount, code: tx.currency))
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                statusLabel(row, mode: mode)
            }
            if mode == .unassigned {
                assignmentControl(for: tx)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func assignmentControl(for tx: Transaction) -> some View {
        ControlGroup {
            Button("Mine") { assign(tx, .user) }
                .help("Mark as yours")
            Button("Shared") { assign(tx, .shared) }
                .help("Mark as shared")
            Button("Fer") { assign(tx, .partner) }
                .help("Mark as Fer's")
        }
        .controlSize(.small)
        .fixedSize()
    }

    private func statusLabel(_ row: HouseholdSettlementRow, mode: HouseholdRowMode) -> some View {
        let text: String
        switch mode {
        case .unassigned:
            text = "Needs review"
        case .shared:
            text = "Fer \(HouseholdSettlementReport.money(row.partnerShare, code: row.transaction.currency)) / You \(HouseholdSettlementReport.money(row.userShare, code: row.transaction.currency))"
        case .partner:
            text = "Recoverable: 100%"
        case .personal:
            text = "Excluded"
        }
        return Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    private func rowMetadata(_ row: HouseholdSettlementRow, mode: HouseholdRowMode) -> String {
        let tx = row.transaction
        var parts = [
            tx.account?.displayName ?? "No account",
            tx.category?.name ?? "Uncategorized",
            tx.expenseAssignment.displayName
        ]
        if mode == .shared {
            parts.append(tx.splitMethodOverride.displayName)
        }
        if let notes = tx.settlementNotes, !notes.isEmpty {
            parts.append(notes)
        }
        return parts.joined(separator: " · ")
    }

    private func emptyState(title: String, description: String, actionTitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.callout.weight(.medium))
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let actionTitle {
                Button(actionTitle) { onReviewTransactions() }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func setupRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label)
                .frame(width: 160, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
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

    private func amountLine(_ label: String, _ amount: Decimal) -> some View {
        labelLine(label, HouseholdSettlementReport.money(amount))
    }

    private func labelLine(_ label: String, _ value: String) -> some View {
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
        selectedTransactionIDs.removeAll()
        let monthStart = selectedMonth.startDate
        let estimate = HouseholdPartnerIncomeService.estimate(for: monthStart, context: modelContext)
        let savedSetup = HouseholdSettlementSetup(estimate)
        partnerIncome = savedSetup.partnerIncomeEstimate
        useManualSalary = savedSetup.useUserIncomeManualOverride
        manualSalary = savedSetup.userIncomeManualOverride ?? 0
        splitMethod = savedSetup.splitMethod
        customUserPercent = savedSetup.customUserPercent ?? 50
        customPartnerPercent = savedSetup.customPartnerPercent ?? 50
        notes = savedSetup.notes ?? ""
        monthTransactions = HouseholdSettlementReportService.transactions(for: monthStart, context: modelContext)
        report = HouseholdSettlementReportService.build(monthStart: monthStart, transactions: monthTransactions, setup: savedSetup)
        saveStatus = "Saved"
        isLoadingSetup = false
    }

    private func setupChanged() {
        guard !isLoadingSetup else { return }
        recomputeReport()
        scheduleSave()
    }

    private func recomputeReport() {
        report = HouseholdSettlementReportService.build(monthStart: selectedMonth.startDate, transactions: monthTransactions, setup: setup)
    }

    private func scheduleSave() {
        pendingSaveTask?.cancel()
        saveStatus = "Unsaved changes"
        guard setupIsValid else { return }
        let month = selectedMonth.startDate
        let setupToSave = setup
        pendingSaveTask = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                saveSetup(month: month, setup: setupToSave)
            }
        }
    }

    private func saveSetup(month: Date? = nil, setup setupToSave: HouseholdSettlementSetup? = nil) {
        let setupToSave = setupToSave ?? setup
        guard setupIsValid || setupToSave.splitMethod != .customPercent else { return }
        _ = try? HouseholdPartnerIncomeService.upsert(
            month: month ?? selectedMonth.startDate,
            amount: setupToSave.partnerIncomeEstimate,
            notes: setupToSave.notes,
            useUserIncomeManualOverride: setupToSave.useUserIncomeManualOverride,
            userIncomeManualOverride: setupToSave.userIncomeManualOverride,
            splitMethod: setupToSave.splitMethod,
            customUserPercent: setupToSave.customUserPercent,
            customPartnerPercent: setupToSave.customPartnerPercent,
            context: modelContext
        )
        saveStatus = "Saved"
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

    private func toggleSelection(_ tx: Transaction, selected: Bool) {
        if selected {
            selectedTransactionIDs.insert(tx.id)
        } else {
            selectedTransactionIDs.remove(tx.id)
        }
    }

    private func bulkAssign(_ assignment: ExpenseAssignment) {
        guard !selectedTransactionIDs.isEmpty else { return }
        let ids = selectedTransactionIDs
        for row in report?.unassignedRows ?? [] where ids.contains(row.id) {
            row.transaction.setExpenseAssignment(assignment)
            row.transaction.touch()
        }
        try? modelContext.save()
        selectedTransactionIDs.removeAll()
        recomputeReport()
    }

    private func assign(_ tx: Transaction, _ assignment: ExpenseAssignment) {
        tx.setExpenseAssignment(assignment)
        tx.touch()
        try? modelContext.save()
        selectedTransactionIDs.remove(tx.id)
        recomputeReport()
    }

    private func copy(_ report: HouseholdSettlementReport) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.plainTextSummary, forType: .string)
    }
}

private enum HouseholdRowMode {
    case unassigned
    case shared
    case partner
    case personal
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
