import AppKit
import SwiftData
import SwiftUI

func propertyMonthText(_ date: Date) -> String {
    let locale = Locale(identifier: "es-MX")
    return date.formatted(.dateTime.month(.wide).year().locale(locale)).lowercased(with: locale)
}

func propertyMoneyText(_ amount: Decimal, code: String = "MXN") -> String {
    var rounded = Decimal()
    var value = amount
    NSDecimalRound(&rounded, &value, 0, .plain)
    let fractionDigits = amount == rounded ? 0 : 2
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.locale = Locale(identifier: "es-MX")
    formatter.currencyCode = code
    formatter.minimumFractionDigits = fractionDigits
    formatter.maximumFractionDigits = fractionDigits
    return formatter.string(from: amount as NSDecimalNumber) ?? "\(amount)"
}

func propertyPercentText(_ share: Decimal) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .percent
    formatter.locale = Locale(identifier: "es-MX")
    formatter.minimumFractionDigits = 0
    formatter.maximumFractionDigits = 2
    return formatter.string(from: share as NSDecimalNumber) ?? "—"
}

struct PropertyPortfolioTotals: Equatable, Sendable {
    var householdExpenses: Decimal
    var amountToRecoverFromFer: Decimal
    var propertyRent: Decimal
    var propertyExpenses: Decimal
    var propertyCollected: Decimal

    var accumulatedExpenses: Decimal { householdExpenses + propertyExpenses }

    static func combine(householdExpenses: Decimal, amountToRecoverFromFer: Decimal,
                        propertyReports: [PropertyMonthlyReport]) -> PropertyPortfolioTotals {
        PropertyPortfolioTotals(
            householdExpenses: householdExpenses,
            amountToRecoverFromFer: amountToRecoverFromFer,
            propertyRent: propertyReports.reduce(Decimal.zero) { $0 + $1.rent },
            propertyExpenses: propertyReports.reduce(Decimal.zero) { $0 + $1.expenses },
            propertyCollected: propertyReports.reduce(Decimal.zero) { $0 + $1.cashCollected }
        )
    }
}

struct PropertiesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var accounts: [Account]
    private let onReviewHouseholdTransactions: ((YearMonth) -> Void)?
    @Bindable var workspace: PropertyWorkspaceModel
    @State private var activeSheet: PropertySheet?
    @State private var showingMonthPicker = false
    private var ledger: PropertyLedger {
        get { workspace.ledger }
        nonmutating set { workspace.ledger = newValue }
    }
    private var selectedPropertyID: UUID? {
        get { workspace.propertyID }
        nonmutating set { workspace.destination = newValue.map(PropertyDestination.property) ?? .allHomes }
    }
    private var selectedMonth: Date { workspace.selectedMonth }
    private var transactionInputs: [PropertyTransactionInput] { workspace.transactionInputs }
    private var householdReport: HouseholdSettlementReport? { workspace.householdReport }
    private var ledgerAvailable: Bool { workspace.ledgerAvailable }
    private var loadError: String? {
        get { workspace.error }
        nonmutating set { workspace.error = newValue }
    }

    private var activeProperties: [PropertyRecord] { workspace.properties }
    private var selectedProperty: PropertyRecord? {
        if workspace.destination == .household {
            return PropertyRecord(id: ledger.householdLink?.propertyID ?? PropertyHouseholdAdapter.link.propertyID, name: PropertyDestination.householdName)
        }
        return activeProperties.first { $0.id == selectedPropertyID }
    }
    private var report: PropertyMonthlyReport? {
        if workspace.destination == .household { return workspace.householdMonthlyReport }
        guard let selectedPropertyID else { return nil }
        return workspace.reports[selectedPropertyID]
    }

    init(workspace: PropertyWorkspaceModel, onReviewHouseholdTransactions: ((YearMonth) -> Void)? = nil) {
        self.workspace = workspace
        self.onReviewHouseholdTransactions = onReviewHouseholdTransactions
    }

    @State private var participationEndID: UUID?
    @State private var activityFilter = PropertyActivityFilter.linked
    @State private var activitySelection: Set<UUID> = []
    @State private var activityAccountFilters: Set<String> = []
    @State private var activityResponsibilityFilters: Set<String> = []
    @State private var assignmentDraft: PropertyAssignmentDraft?
    @State private var memberCollection: PropertyMemberCollectionSelection?
    @State private var recoverySources: [PropertyTransactionInput] = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DashboardCardTokens.topStackSpacing) {
                monthHeader
                if let loadError {
                    HStack(alignment: .top) {
                        Label(loadError, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                        Spacer()
                        Button("Retry") { Task { await workspace.retry() } }
                    }
                    .accessibilityIdentifier("properties.error")
                }
                if workspace.isLoading && !ledgerAvailable { ProgressView("Cargando propiedades…") }
                sectionPicker
                if workspace.isLoadingPeriod || (!workspace.periodReady && loadError == nil) {
                    ProgressView("Actualizando el reporte…").frame(maxWidth: .infinity, alignment: .leading)
                } else if !workspace.periodReady {
                    ContentUnavailableView("Reporte no disponible", systemImage: "calendar.badge.exclamationmark",
                        description: Text("Retry the read to show the selected month's data."))
                } else { detail }
            }
            .padding(28)
            .frame(maxWidth: 1120, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background {
            PropertyWorkspaceRenderProbe(workspace: workspace, destination: workspace.destination,
                section: workspace.section, month: selectedMonth).allowsHitTesting(false)
        }
        .navigationTitle(workspace.title)
        .accessibilityIdentifier("properties.workspace")
        .toolbar { workspaceToolbar }
        .task { await load() }
        .onChange(of: workspace.showingNewProperty) {
            if workspace.showingNewProperty { activeSheet = .property; workspace.showingNewProperty = false }
        }
        .confirmationDialog("Remove member", isPresented: Binding(get: { participationEndID != nil }, set: { if !$0 { participationEndID = nil } }), titleVisibility: .visible) {
            Button("Remove from \(propertyMonthText(PropertyParticipation.firstInactiveMonth(selected: selectedMonth, today: .now)))", role: .destructive) {
                guard let id = participationEndID else { return }
                if workspace.removeMember(id: id) { participationEndID = nil }
            }
            Button("Cancel", role: .cancel) { participationEndID = nil }
        } message: {
            let name = participationEndID.flatMap { workspace.member(id: $0)?.name } ?? String(localized: "Member")
            Text("\(name) stops participating from the indicated month. Open periods recalculate; history and previous closes are preserved.")
        }
        .onChange(of: workspace.destination) {
            activitySelection = []; activityFilter = .linked
            activityAccountFilters = []; activityResponsibilityFilters = []
        }
        .onChange(of: selectedMonth) {
            activitySelection = []; activityFilter = .linked
            activityAccountFilters = []; activityResponsibilityFilters = []
        }
        .sheet(item: $memberCollection) { selection in
            if let property = selectedProperty {
                PropertyMemberCollectionsSheet(workspace: workspace, propertyID: property.id,
                    residentID: selection.id)
            }
        }
        .sheet(item: $assignmentDraft) { draft in
            PropertyAssignmentEditor(workspace: workspace, draft: draft,
                residents: selectedProperty.map { ledger.residents(for: $0.id, month: selectedMonth) } ?? []) {
                    activitySelection = []
                }
        }
        .sheet(item: $activeSheet) { sheet in
            VStack(spacing: 0) {
            switch sheet {
            case .property:
                PropertyNameSheet { name in
                    var property = PropertyRecord(name: name)
                    property.updatedAt = .now
                    ledger.properties.append(property)
                    selectedPropertyID = property.id
                    return persist()
                }
            case .resident:
                if let property = selectedProperty {
                    PropertyResidentSheet(property: property, defaultMonth: nextMonth) { resident in
                        ledger.residents.append(resident)
                        return persist()
                    }
                }
            case .residentEdit(let residentID):
                if let member = workspace.member(id: residentID) {
                    PropertyResidentRenameSheet(name: member.name, errorMessage: { workspace.error }) { name in
                        workspace.renameMember(id: residentID, name: name)
                    }
                }
            case .rent:
                if let property = selectedProperty {
                    PropertyRentSheet(propertyID: property.id, month: selectedMonth,
                                      currentAmount: ledger.rent(for: property.id, month: selectedMonth)) { agreement in
                        for index in ledger.rents.indices where ledger.rents[index].propertyID == agreement.propertyID
                            && ledger.rents[index].effectiveMonth == agreement.effectiveMonth
                            && ledger.rents[index].deletedAt == nil {
                            ledger.rents[index].deletedAt = .now
                            ledger.rents[index].updatedAt = .now
                        }
                        ledger.rents.append(agreement)
                        return persist()
                    }
                }
            case .service:
                if let property = selectedProperty {
                    PropertyServiceSheet(propertyID: property.id) { budget in
                        ledger.serviceBudgets.append(budget)
                        return persist()
                    }
                }
            case .serviceEdit(let budgetID):
                if let property = selectedProperty,
                   let budget = ledger.serviceBudgets.first(where: { $0.id == budgetID && $0.deletedAt == nil }) {
                    PropertyServiceSheet(propertyID: property.id, budget: budget) { updated in
                        guard let index = ledger.serviceBudgets.firstIndex(where: { $0.id == updated.id }) else { return false }
                        ledger.serviceBudgets[index] = updated
                        return persist()
                    }
                }
            case .attribution:
                if let property = selectedProperty {
                    PropertyAttributionSheet(property: property, month: selectedMonth,
                        residents: ledger.residents(for: property.id, month: selectedMonth),
                        programs: ledger.maintenancePrograms.filter { $0.propertyID == property.id && $0.deletedAt == nil },
                        transactions: transactionInputs.filter {
                            $0.deletedAt == nil && !$0.isDuplicate && !$0.isTransfer && $0.amount < 0
                                && $0.currencyCode == "MXN"
                                && isAvailableForProperty($0, propertyID: property.id)
                        }) { proposedAttribution in
                            workspace.linkAttribution(proposedAttribution)
                        }
                }
            case .payment(let memberID):
                if let property = selectedProperty, let report {
                    PropertyCollectionCaptureSheet(workspace: workspace, property: property, report: report,
                        accounts: accounts, initialResidentID: memberID)
                }
            case .existingPayment:
                if let property = selectedProperty, let report {
                    PropertyCollectionCaptureSheet(workspace: workspace, property: property, report: report,
                        accounts: accounts, existingSources: recoverySources)
                }
            case .adjustment:
                if let property = selectedProperty, let report {
                    PropertyAdjustmentSheet(propertyID: property.id, month: selectedMonth,
                        residents: report.residents) { adjustment in
                            ledger.adjustments.append(adjustment)
                            return persist()
                        }
                }
            case .maintenance:
                if let property = selectedProperty {
                    PropertyMaintenanceSheet(propertyID: property.id) { program in
                        ledger.maintenancePrograms.append(program)
                        return persist()
                    }
                }
            case .reserve:
                if let property = selectedProperty {
                    PropertyReserveSheet(propertyID: property.id) { movement in
                        ledger.reserveMovements.append(movement)
                        return persist()
                    }
                }
            }
            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange).padding()
            }
            }
        }
    }

    private var nextMonth: Date {
        Calendar.current.date(byAdding: .month, value: 1, to: max(selectedMonth, Calendar.current.propertyMonthStart(for: .now))) ?? selectedMonth
    }

    @ToolbarContentBuilder
    private var workspaceToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { activeSheet = .property } label: {
                Label("Add property", systemImage: "plus")
            }
            .help("Add property")
            .disabled(!ledgerAvailable)
            Menu {
                if workspace.destination != .household, let property = selectedProperty {
                    Button("Add member…") { activeSheet = .resident }
                    Button("Set up rent…") { activeSheet = .rent }
                    Button("Add service reference…") { activeSheet = .service }
                    Divider()
                    Button("Link transaction…") { activeSheet = .attribution }
                    Button("Register collection…") { activeSheet = .payment(nil) }
                    Button("Add adjustment…") { activeSheet = .adjustment }
                        .disabled(ledger.closes.contains { $0.propertyID == property.id && $0.monthStart == selectedMonth })
                    Divider()
                    Button("Maintenance program…") { activeSheet = .maintenance }
                    Button("Set aside reserve…") { activeSheet = .reserve }
                } else if workspace.destination == .household, let summary = workspace.householdSummary {
                    if let onReviewHouseholdTransactions {
                        Button("Review transactions…") { onReviewHouseholdTransactions(YearMonth(date: selectedMonth)) }
                    }
                    Button("Copy summary") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(summary, forType: .string)
                    }
                    ShareLink(item: summary) { Text("Share summary") }
                }
            } label: {
                Label("Home actions", systemImage: "ellipsis")
            }
            .help("Home actions")
            .disabled(!ledgerAvailable || !workspace.periodReady || workspace.destination == .allHomes)
        }
    }

    private var monthHeader: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Button { showingMonthPicker.toggle() } label: {
                    Text(propertyMonthText(selectedMonth).prefix(1).uppercased() + propertyMonthText(selectedMonth).dropFirst())
                        .font(.title2.weight(.semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Choose month: \(propertyMonthText(selectedMonth))"))
                .popover(isPresented: $showingMonthPicker) {
                    DatePicker("Report month", selection: Binding(get: { selectedMonth }, set: { workspace.selectMonth($0) }),
                               displayedComponents: .date)
                        .datePickerStyle(.graphical).padding(16)
                }
                Text(periodSubtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            ControlGroup {
                Button { workspace.shiftMonth(-1) } label: {
                    Image(systemName: "chevron.left").accessibilityLabel("Previous month")
                }.help("Previous month")
                Button { workspace.shiftMonth(1) } label: {
                    Image(systemName: "chevron.right").accessibilityLabel("Next month")
                }.help("Next month")
            }
            .controlGroupStyle(.automatic)
        }
    }

    private var periodSubtitle: String {
        if selectedMonth > Calendar.current.propertyMonthStart(for: .now) { return String(localized: "Projection · MXN") }
        switch workspace.destination {
        case .allHomes: return String(localized: "Overview of your homes · MXN")
        case .household:
            let count = ledger.closes.first { $0.propertyID == (ledger.householdLink ?? PropertyHouseholdAdapter.link).propertyID && $0.monthStart == selectedMonth }?.residents.count
                ?? workspace.householdActiveMemberIDs.count
            return String(format: String(localized: "%lld members · MXN"), count)
        case .property(let id):
            let state = ledger.closes.contains { $0.propertyID == id && $0.monthStart == selectedMonth }
                ? String(localized: "Closed month") : String(localized: "Open month")
            return String(format: String(localized: "%@ · %lld members · MXN"), state, report?.residents.count ?? 0)
        }
    }

    @ViewBuilder
    private var sectionPicker: some View {
        if !workspace.sections.isEmpty {
            VStack(spacing: 0) {
                HStack(spacing: 20) {
                    ForEach(workspace.sections) { section in
                        Button { workspace.section = section } label: {
                            Text(LocalizedStringKey(section.rawValue))
                                .font(.callout.weight(workspace.section == section ? .semibold : .regular))
                                .foregroundStyle(workspace.section == section ? Color.primary : .secondary)
                                .padding(.bottom, 10)
                                .overlay(alignment: .bottom) {
                                    if workspace.section == section { Rectangle().fill(Color.accentColor).frame(height: 2) }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(workspace.section == section ? .isSelected : [])
                        .accessibilityIdentifier("properties.section.\(section.id)")
                    }
                    Spacer(minLength: 0)
                }
                Divider()
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Home sections")
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch workspace.destination {
        case .allHomes:
            consolidatedDetail
        case .household, .property:
            if let property = selectedProperty, let report {
                if workspace.section == .month {
                    monthlyDetail(property, report)
                } else {
                    PropertyFacts(title: "Rent agreements", values: ledger.rents.filter {
                        $0.propertyID == property.id && $0.deletedAt == nil
                    }.sorted { $0.effectiveMonth > $1.effectiveMonth }.map {
                        PropertyFactValue(title: String(format: String(localized: "Since %@"), propertyMonthText($0.effectiveMonth)), value: propertyMoneyText($0.monthlyAmount))
                    }, actionTitle: "Set up rent…", action: { activeSheet = .rent })
                    servicesSection(property)
                    PropertySectionHeading(title: "Maintenance program", actionTitle: "Set up program") { activeSheet = .maintenance }
                }
            }
        }
    }

    private func monthlyDetail(_ property: PropertyRecord, _ report: PropertyMonthlyReport) -> some View {
        let editingDestination = workspace.destination
        let editingMonth = report.monthStart
        let context = workspace.settlementContext(propertyID: property.id, report: report)
        let closed = context.isClosed
        let historical = context.historical
        let canCalculate = context.canCalculate
        let settlements = workspace.memberSettlements(propertyID: property.id, report: report)
        var rows = PropertyMonthlyMemberRow.rows(report: report,
            visibleIDs: workspace.destination == .household && !closed ? workspace.householdActiveMemberIDs : nil,
            canCalculate: canCalculate, isClosed: closed, historical: historical)
        for index in rows.indices {
            rows[index].settlement = settlements.first { $0.residentID == rows[index].memberID }
            rows[index].advance = rows[index].settlement?.advanceAvailable ?? 0
        }
        let currentIDs = Set(rows.map(\.memberID))
        for settlement in settlements where !currentIDs.contains(settlement.residentID) {
            guard let member = workspace.member(id: settlement.residentID) else { continue }
            rows.append(PropertyMonthlyMemberRow(memberID: member.id, month: report.monthStart,
                name: member.name, income: 0, confirmed: true, pending: settlement.due,
                historical: false, priorDebt: settlement.priorDebt, advance: settlement.advanceAvailable,
                settlement: settlement, former: true))
        }
        let legacyAdvance = PropertyCollectionPosting.legacyAdvances(propertyID: property.id,
            ledger: ledger, inputs: transactionInputs, asOf: workspace.asOf)
        let legacyID = PropertyPaymentAdvance.placeholderResidentID(propertyID: property.id)
        let legacyPresent = ledger.paymentApplications.contains {
            $0.propertyID == property.id && $0.residentID == legacyID && $0.deletedAt == nil && PropertyPaymentAdvance.isAdvance($0)
        }
        let legacyNeedsReview = PropertyCollectionPosting.hasChangedAdvanceSource(propertyID: property.id,
            residentID: legacyID, ledger: ledger, inputs: transactionInputs)
        let linkedActivity = PropertyActivitySummary.linkedExpensesAndReimbursements(workspace.activityRows(filter: .linked))
        return VStack(alignment: .leading, spacing: DashboardCardTokens.sectionSpacing) {
            PropertyMetricGrid(values: historical
                ? Array(PropertyPresentationAdapter.property(report).metrics.prefix(2)) + [
                    .init(title: "Historical pending reconciliation", amount: report.residents.reduce(0) { $0 + max(0, $1.balance) }, note: "Estimated split, no confirmed debt")]
                : PropertyPresentationAdapter.property(report).metrics)
            PropertySectionHeading(title: "Members and contributions", actionTitle: workspace.destination == .household ? nil : "Add member") { activeSheet = .resident }
            PropertyMonthlyTable(rows: rows, isClosed: closed, legacyAdvance: legacyAdvance,
                legacyAdvancePresent: legacyPresent, legacyAdvanceNeedsReview: legacyNeedsReview,
                save: { id, amount, confirmed in workspace.saveMonthlyIncome(residentID: id, amount: amount, confirmed: confirmed,
                    month: editingMonth, editedDestination: editingDestination) },
                edit: { id in
                    activeSheet = .residentEdit(id)
                }, end: { id in participationEndID = id },
                openPayments: { memberCollection = .init(id: $0) },
                collect: { activeSheet = .payment($0) },
                applyAdvance: { id in
                    if case .rejected(let message) = workspace.applyMemberAdvance(propertyID: property.id, residentID: id) {
                        loadError = message
                    }
                }, openLegacyAdvance: { memberCollection = .init(id: legacyID) })
            if historical { Text("Historical split pending reconciliation. It is not automatically added to prior debt.").font(.caption).foregroundStyle(.secondary) }
            Button("Reconcile existing receipt…") {
                recoverySources = workspace.recoveryReceipts(propertyID: property.id)
                activeSheet = .existingPayment
            }.buttonStyle(.link).font(.caption)
            PropertySpendingChart(rows: linkedActivity, contributors: rows.map(PropertyExpenseFlow.Contributor.init))
            PropertyActivityTable(rows: activityFilter == .linked ? linkedActivity : PropertyActivitySummary.linkedExpensesAndReimbursements(workspace.activityRows(filter: activityFilter)),
                household: workspace.destination == .household,
                residents: ledger.residents(for: property.id, month: selectedMonth),
                filter: $activityFilter, selection: $activitySelection,
                accountFilters: $activityAccountFilters, responsibilityFilters: $activityResponsibilityFilters,
                assign: applyActivityAssignment, adjustment: { activeSheet = .adjustment },
                allowsUserAssignment: workspace.householdActiveMemberIDs.contains((ledger.householdLink ?? PropertyHouseholdAdapter.link).userID),
                allowsPartnerAssignment: workspace.householdActiveMemberIDs.contains((ledger.householdLink ?? PropertyHouseholdAdapter.link).partnerID))
            maintenanceSection(property)
            let issues = report.warnings.filter { !$0.hasPrefix("Confirma el ingreso de ") && $0 != "Hay ingresos por confirmar en la tabla." }
            ForEach(issues, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
            if closed { Label("Calculation closed. Later collections update the balance.", systemImage: "lock").font(.caption) }
            else { Button("Close month") { close(report) }.disabled(!report.canClose || !ledgerAvailable || !canCalculate || historical) }
        }
    }

    private func applyActivityAssignment(_ ids: Set<UUID>, _ choice: PropertyAssignmentChoice) {
        switch choice {
        case .group, .custom:
            let custom: Bool
            if case .custom = choice { custom = true } else { custom = false }
            var draft = PropertyAssignmentDraft(ids: ids, destination: workspace.destination, month: selectedMonth, isCustom: custom)
            if ids.count == 1, let id = ids.first {
                if let original = ledger.attributions.first(where: { $0.transactionID == id && $0.deletedAt == nil }),
                   case .selected(let members) = original.responsibility { draft.members = Set(members) }
                if case .custom(let amount) = workspace.householdAllocation(for: id) { draft.amount = amount }
            }
            assignmentDraft = draft
        default:
            if workspace.assign(ids: ids, choice: choice) { activitySelection = [] }
        }
    }

    private var consolidatedDetail: some View {
        let reports = activeProperties.compactMap { workspace.reports[$0.id] }
        let totals = PropertyPortfolioTotals.combine(householdExpenses: householdReport?.totalPaidByUser ?? 0,
            amountToRecoverFromFer: householdReport?.amountToRecoverFromPartner ?? 0, propertyReports: reports)
        return VStack(alignment: .leading, spacing: DashboardCardTokens.sectionSpacing) {
            PropertyMetricGrid(values: [
                .init(title: "Accumulated expenses", amount: totals.accumulatedExpenses, note: "Real transactions from your homes"),
                .init(title: "Rent generated", amount: totals.propertyRent, note: "Monthly obligations"),
                .init(title: "Collected", amount: totals.propertyCollected, note: "Applied collections received in the month"),
                .init(title: "To recover from Fer", amount: totals.amountToRecoverFromFer, note: PropertyDestination.householdName),
            ])
            PropertySectionHeading(title: "Properties")
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 14) {
                GridRow {
                    Text("Home")
                    Text("Actual expenses").gridColumnAlignment(.trailing)
                    Text("Pending").gridColumnAlignment(.trailing)
                }.font(.caption).foregroundStyle(.secondary)
                Divider().gridCellUnsizedAxes(.horizontal)
                portfolioRow(name: PropertyDestination.householdName, destination: .household,
                    expenses: totals.householdExpenses, pending: totals.amountToRecoverFromFer, note: "Fer's contribution")
                ForEach(activeProperties) { property in
                    if let report = workspace.reports[property.id] {
                        Divider().gridCellUnsizedAxes(.horizontal)
                        portfolioRow(name: property.name, destination: .property(property.id), expenses: report.expenses,
                            pending: report.residents.reduce(0) { $0 + max(0, $1.balance) }, note: "Rent, expenses and adjustments")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if activeProperties.isEmpty {
                Button("Add another property…") { activeSheet = .property }
                    .buttonStyle(.borderless).disabled(!ledgerAvailable)
            }
        }
    }

    private func portfolioRow(name: String, destination: PropertyDestination, expenses: Decimal,
                              pending: Decimal, note: String) -> some View {
        GridRow {
            Button { workspace.destination = destination } label: {
                Label(name, systemImage: "house").multilineTextAlignment(.leading)
            }.buttonStyle(.borderless)
            Text(propertyMoneyText(expenses)).monospacedDigit()
            VStack(alignment: .trailing, spacing: 3) {
                Text(propertyMoneyText(pending)).monospacedDigit()
                Text(LocalizedStringKey(note)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func servicesSection(_ property: PropertyRecord) -> some View {
        VStack(alignment: .leading, spacing: DashboardCardTokens.sectionSpacing) {
            PropertySectionHeading(title: "Service references", actionTitle: "Add service reference…") { activeSheet = .service }
            PropertyTableCard {
            VStack(alignment: .leading, spacing: 8) {
            Text("References help with planning; only real transactions create obligations.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(ledger.serviceBudgets.filter { $0.propertyID == property.id && $0.deletedAt == nil }) { budget in
                HStack {
                    Text(budget.name)
                    Text(LocalizedStringKey(budget.frequency.localizedTitle)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(propertyMoneyText(budget.monthlyReference))
                        .foregroundStyle(.secondary)
                    Menu {
                        Button("Edit reference") { activeSheet = .serviceEdit(budget.id) }
                    } label: {
                        Image(systemName: "ellipsis.circle").accessibilityLabel(Text("Options for \(budget.name)"))
                    }
                    .menuStyle(.borderlessButton)
                }
            }
            }
            }
        }
    }

    private func maintenanceSection(_ property: PropertyRecord) -> some View {
        let programs = ledger.maintenancePrograms.filter { $0.propertyID == property.id && $0.deletedAt == nil }
        return VStack(alignment: .leading, spacing: DashboardCardTokens.sectionSpacing) {
            PropertySectionHeading(title: "Maintenance and recovery")
            PropertyTableCard {
            VStack(alignment: .leading, spacing: 8) {
            if programs.isEmpty {
                Text("No recovery program configured.").foregroundStyle(.secondary)
                Button("Set up program") { workspace.section = .configuration }
            } else {
                ForEach(programs) { program in
                    let summary = PropertyMaintenanceCalculator.summary(program: program, ledger: ledger,
                        transactions: transactionInputs)
                    PropertyMetricGrid(values: [
                        .init(title: "Budget", amount: program.budget, note: "Program limit"),
                        .init(title: "Investment", amount: summary.invested, note: "Registered disbursements"),
                        .init(title: "Unexercised", amount: summary.budgetAvailable, note: "Remaining budget"),
                        .init(title: "Recovered", amount: summary.recovered, note: "From rent actually collected"),
                        .init(title: "Pending capital", amount: summary.capitalPending, note: "To recover"),
                    ])
                    let progress = program.budget > 0
                        ? min(1, NSDecimalNumber(decimal: summary.invested / program.budget).doubleValue) : 0
                    ProgressView(value: progress)
                    if summary.invested > program.budget {
                        Label("Investment exceeds the budget by \(propertyMoneyText(summary.invested - program.budget)).", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    ForEach(summary.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Text("\(propertyMonthText(program.startsAt))–\(propertyMonthText(program.endsAt)) · max \(propertyMoneyText(program.monthlyRecoveryLimit)) per month")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text("Future reserve available")
                    Spacer()
                    let reserve = ledger.reserveMovements.filter { $0.propertyID == property.id && $0.deletedAt == nil }
                        .reduce(Decimal.zero) { $0 + $1.amount }
                    Text(propertyMoneyText(reserve)).monospacedDigit()
                }
                .padding(.top, 6)
            }
        }
            }
        }
    }

    private func close(_ report: PropertyMonthlyReport) {
        guard let close = PropertySettlementCalculator.close(report),
              !ledger.closes.contains(where: { $0.propertyID == close.propertyID && $0.monthStart == close.monthStart }) else { return }
        ledger.closes.append(close)
        persist()
    }

    private func load() async {
        workspace.configure(context: modelContext, hasAccounts: !accounts.isEmpty)
        if !ledgerAvailable { await workspace.loadLedger() }
        await workspace.refreshPeriod()
    }

    private func isAvailableForProperty(_ input: PropertyTransactionInput, propertyID: UUID) -> Bool {
        PropertyAssignmentService.isAvailable(input, propertyID: propertyID, ledger: ledger)
            && !ledger.attributions.contains { $0.transactionID == input.id && $0.deletedAt == nil && $0.kind == .reimbursement }
    }

    @discardableResult
    private func persist() -> Bool {
        if workspace.destination == .household { workspace.prepareHouseholdLink() }
        return workspace.save()
    }

}

private enum PropertySheet: Identifiable {
    case property, resident, rent, service, attribution, existingPayment, adjustment, maintenance, reserve
    case payment(UUID?)
    case residentEdit(UUID)
    case serviceEdit(UUID)
    var id: String {
        switch self {
        case .residentEdit(let id): "resident-edit-\(id.uuidString)"
        case .serviceEdit(let id): "service-edit-\(id.uuidString)"
        case .property: "property"
        case .resident: "resident"
        case .rent: "rent"
        case .service: "service"
        case .attribution: "attribution"
        case .payment(let id): "payment-\(id?.uuidString ?? "choose")"
        case .existingPayment: "existing-payment"
        case .adjustment: "adjustment"
        case .maintenance: "maintenance"
        case .reserve: "reserve"
        }
    }
}

extension PropertyServiceFrequency {
    var localizedTitle: String {
        switch self {
        case .monthly: "Monthly"
        case .bimonthly: "Bimonthly"
        case .annual: "Annual"
        case .irregular: "Irregular"
        }
    }
}

#Preview {
    PropertiesView(workspace: PropertyWorkspaceModel(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("PropertyPreview-\(UUID().uuidString).json")))
        .modelContainer(HouseholdSettlementFixture.makePreviewContainer())
}
