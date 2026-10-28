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
    @State private var activityIdentityFilters: Set<PropertyActivityIdentity> = []
    @State private var assignmentDraft: PropertyAssignmentDraft?
    @State private var memberCollection: PropertyMemberCollectionSelection?
    @State private var pendingLinkSources: [PropertyTransactionInput] = []
    @State private var pendingLinkResidentID: UUID?
    @State private var rentDraft: PropertyRentDraft?
    @State private var maintenanceDraft: PropertyMaintenanceDraft?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DashboardCardTokens.topStackSpacing) {
                    Color.clear.frame(height: 0).accessibilityHidden(true).id("properties-top")
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
                activityAccountFilters = []; activityResponsibilityFilters = []; activityIdentityFilters = []
                rentDraft = nil; maintenanceDraft = nil
                proxy.scrollTo("properties-top", anchor: .top)
            }
            .onChange(of: selectedMonth) {
                activitySelection = []; activityFilter = .linked
                activityAccountFilters = []; activityResponsibilityFilters = []; activityIdentityFilters = []
                proxy.scrollTo("properties-top", anchor: .top)
            }
            .onChange(of: workspace.section) {
                proxy.scrollTo("properties-top", anchor: .top)
            }
            .sheet(item: $memberCollection) { selection in
                if let property = selectedProperty {
                    PropertyMemberCollectionsSheet(workspace: workspace, propertyID: property.id,
                        residentID: selection.id,
                        onShowDetail: { scope in
                            openAccountDetail(scope, residentID: selection.id, proxy: proxy)
                        },
                        registerPayment: {
                            // The sheet dismisses itself first; presenting the capture
                            // immediately would race the dismissal animation.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                activeSheet = .payment(selection.id)
                            }
                        })
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
                case .linkPendingPayment:
                    if let property = selectedProperty, let report {
                        PropertyCollectionCaptureSheet(workspace: workspace, property: property, report: report,
                            accounts: accounts, existingSources: pendingLinkSources,
                            initialResidentID: pendingLinkResidentID)
                    }
                case .adjustment:
                    if let property = selectedProperty, let report {
                        PropertyAdjustmentSheet(propertyID: property.id, month: selectedMonth,
                            residents: report.residents) { adjustment in
                                ledger.adjustments.append(adjustment)
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
                    Button("Set up rent…") {
                        rentDraft = PropertyRentDraft(propertyID: property.id, editingID: nil,
                            month: selectedMonth, amount: ledger.rent(for: property.id, month: selectedMonth))
                    }
                    Divider()
                    Button("Link transaction…") { activeSheet = .attribution }
                    Button("Register payment…") { activeSheet = .payment(nil) }
                    Button("Add adjustment…") { activeSheet = .adjustment }
                        .disabled(ledger.closes.contains { $0.propertyID == property.id && $0.monthStart == selectedMonth })
                    Divider()
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
                    rentAgreementsSection(property)
                    maintenanceConfigurationSection(property)
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
            // One «deuda anterior» only: the table caption carries the same
            // settlement figure the member sheet and the capture suggestion
            // already publish, not the report's looser reading.
            rows[index].priorDebt = rows[index].settlement?.priorDebt ?? rows[index].priorDebt
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
        let pendingLinks = workspace.pendingLinks(propertyID: property.id)
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
                end: { id in participationEndID = id },
                openPayments: { memberCollection = .init(id: $0) },
                collect: { activeSheet = .payment($0) },
                applyAdvance: { id in
                    if case .rejected(let message) = workspace.applyMemberAdvance(propertyID: property.id, residentID: id) {
                        loadError = message
                    }
                }, openLegacyAdvance: { memberCollection = .init(id: legacyID) },
                rename: { id, name in
                    workspace.renameMember(id: id, name: name)
                })
            if historical { Text("Historical split pending reconciliation. It is not automatically added to prior debt.").font(.caption).foregroundStyle(.secondary) }
            if !pendingLinks.isEmpty {
                HStack {
                    Label("A payment income is waiting to be linked to this home.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button("Link it now") {
                        pendingLinkSources = pendingLinks.compactMap { $0.input }
                        pendingLinkResidentID = pendingLinks.count == 1 ? pendingLinks.first?.link.residentID : nil
                        activeSheet = .linkPendingPayment
                    }.buttonStyle(.link).font(.caption)
                }
            }
            PropertySpendingChart(rows: linkedActivity, contributors: rows.map(PropertyExpenseFlow.Contributor.init))
            PropertyActivityTable(rows: activityFilter == .linked ? linkedActivity : PropertyActivitySummary.linkedExpensesAndReimbursements(workspace.activityRows(filter: activityFilter)),
                household: workspace.destination == .household,
                residents: ledger.residents(for: property.id, month: selectedMonth),
                filter: $activityFilter, selection: $activitySelection,
                accountFilters: $activityAccountFilters, responsibilityFilters: $activityResponsibilityFilters,
                identityFilters: $activityIdentityFilters,
                assign: applyActivityAssignment, adjustment: { activeSheet = .adjustment },
                allowsUserAssignment: workspace.householdActiveMemberIDs.contains((ledger.householdLink ?? PropertyHouseholdAdapter.link).userID),
                allowsPartnerAssignment: workspace.householdActiveMemberIDs.contains((ledger.householdLink ?? PropertyHouseholdAdapter.link).partnerID))
                .id("property-activity-table")
            maintenanceSection(property)
            let issues = report.warnings.filter { !$0.hasPrefix("Confirma el ingreso de ") && $0 != "Hay ingresos por confirmar en la tabla." }
            ForEach(issues, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
            if closed { Label("Calculation closed. Later collections update the balance.", systemImage: "lock").font(.caption) }
            else { Button("Close month") { close(report) }.disabled(!report.canClose || !ledgerAvailable || !canCalculate || historical) }
        }
        // Orphan pending-link markers (their movement vanished or was deleted)
        // retire when the property or month changes — a write, so it lives in a
        // task, never in the render path above.
        .task(id: "\(property.id.uuidString)-\(report.monthStart.timeIntervalSince1970)") {
            workspace.retirePendingLinks(propertyID: property.id)
        }
    }

    /// Deep link from the member account sheet: swaps the activity filters for
    /// the attribution identities behind one breakdown row and scrolls to the
    /// table, so its subtotal can verify the sheet's figure. Identity, never
    /// label text: closed months render concatenated split labels and
    /// `.selected` groups render member names, but the identity still matches
    /// exactly the obligations `houseSharedTotal` / `individualCharges` summed.
    private func openAccountDetail(_ scope: PropertyAccountDetailScope, residentID: UUID,
                                   proxy: ScrollViewProxy) {
        activityFilter = .linked
        activitySelection = []
        activityAccountFilters = []
        activityResponsibilityFilters = []
        switch scope {
        case .sharedCharges:
            activityIdentityFilters = [.shared]
        case .memberCharges:
            activityIdentityFilters = [.individual(residentID)]
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            proxy.scrollTo("property-activity-table", anchor: .top)
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

    /// Rent agreements never enter the household settlement, so the section is
    /// property-only. Values stay in read mode; the explicit edit action opens
    /// the editor inline on this same surface.
    @ViewBuilder
    private func rentAgreementsSection(_ property: PropertyRecord) -> some View {
        if workspace.destination != .household {
            let agreements = ledger.rents.filter { $0.propertyID == property.id && $0.deletedAt == nil }
                .sorted { $0.effectiveMonth > $1.effectiveMonth }
            VStack(alignment: .leading, spacing: DashboardCardTokens.sectionSpacing) {
                PropertySectionHeading(title: "Rent agreements", actionTitle: "Set up rent…") {
                    rentDraft = PropertyRentDraft(propertyID: property.id, editingID: nil,
                        month: selectedMonth, amount: ledger.rent(for: property.id, month: selectedMonth))
                }
                PropertyTableCard {
                    if let draft = rentDraft, draft.propertyID == property.id {
                        PropertyRentAgreementEditor(month: draft.month, amount: draft.amount,
                            errorMessage: { loadError },
                            onSave: { amount, month in
                                saveRentAgreement(propertyID: property.id, amount: amount, effectiveMonth: month)
                            },
                            onCancel: { rentDraft = nil })
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            if agreements.isEmpty {
                                Text("No rent agreements yet.").foregroundStyle(.secondary)
                            }
                            ForEach(agreements) { agreement in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(String(format: String(localized: "Since %@"), propertyMonthText(agreement.effectiveMonth)))
                                        .foregroundStyle(.secondary)
                                    Spacer(minLength: 8)
                                    Text(propertyMoneyText(agreement.monthlyAmount)).monospacedDigit()
                                    Button("Edit") {
                                        rentDraft = PropertyRentDraft(propertyID: property.id, editingID: agreement.id,
                                            month: agreement.effectiveMonth, amount: agreement.monthlyAmount)
                                    }.buttonStyle(.link).font(.caption)
                                }.font(.callout)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Saving keeps the historical versioning: superseding the active agreement
    /// with the same effective month tombstones it and appends the new row.
    private func saveRentAgreement(propertyID: UUID, amount: Decimal, effectiveMonth: Date) -> Bool {
        let agreement = PropertyRentAgreement(propertyID: propertyID, monthlyAmount: amount, effectiveMonth: effectiveMonth)
        for index in ledger.rents.indices where ledger.rents[index].propertyID == agreement.propertyID
            && ledger.rents[index].effectiveMonth == agreement.effectiveMonth
            && ledger.rents[index].deletedAt == nil {
            ledger.rents[index].deletedAt = .now
            ledger.rents[index].updatedAt = .now
        }
        ledger.rents.append(agreement)
        let saved = persist()
        if saved { rentDraft = nil }
        return saved
    }

    /// The month tab shows recovery only for properties that actually have a
    /// program; the household never has one, and with no program the whole
    /// section (including its empty state) is omitted.
    @ViewBuilder
    private func maintenanceSection(_ property: PropertyRecord) -> some View {
        if workspace.destination != .household {
            let programs = ledger.maintenancePrograms.filter { $0.propertyID == property.id && $0.deletedAt == nil }
            if !programs.isEmpty {
                VStack(alignment: .leading, spacing: DashboardCardTokens.sectionSpacing) {
                    PropertySectionHeading(title: "Maintenance and recovery")
                    PropertyTableCard {
                        VStack(alignment: .leading, spacing: 8) {
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
    }

    /// Configuration owns the maintenance program: read values plus inline
    /// editing on the same surface. The household never has a program.
    @ViewBuilder
    private func maintenanceConfigurationSection(_ property: PropertyRecord) -> some View {
        if workspace.destination != .household {
            VStack(alignment: .leading, spacing: DashboardCardTokens.sectionSpacing) {
                if let draft = maintenanceDraft, draft.propertyID == property.id {
                    PropertyMaintenanceProgramEditor(draft: draft,
                        errorMessage: { loadError },
                        onSave: { startsAt, endsAt, budget, monthlyLimit in
                            saveMaintenanceProgram(propertyID: property.id, existingID: draft.editingID,
                                startsAt: startsAt, endsAt: endsAt, budget: budget, monthlyLimit: monthlyLimit)
                        },
                        onCancel: { maintenanceDraft = nil })
                } else if let program = activeMaintenanceProgram(for: property.id) {
                    PropertySectionHeading(title: "Maintenance program", actionTitle: "Edit") {
                        maintenanceDraft = PropertyMaintenanceDraft(propertyID: property.id, editingID: program.id,
                            startsAt: program.startsAt, endsAt: program.endsAt,
                            budget: program.budget, monthlyLimit: program.monthlyRecoveryLimit)
                    }
                    PropertyTableCard {
                        VStack(alignment: .leading, spacing: 8) {
                            maintenanceFactRow("Start", propertyMonthText(program.startsAt))
                            maintenanceFactRow("End", propertyMonthText(program.endsAt))
                            maintenanceFactRow("Budget", propertyMoneyText(program.budget))
                            maintenanceFactRow("Maximum recovery per month", propertyMoneyText(program.monthlyRecoveryLimit))
                            Text("The budget helps planning. Only linked expenses count as actual investment.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    PropertySectionHeading(title: "Maintenance program", actionTitle: "Set up program") {
                        maintenanceDraft = PropertyMaintenanceDraft(propertyID: property.id, editingID: nil,
                            startsAt: Calendar.current.propertyMonthStart(for: .now),
                            endsAt: Calendar.current.date(byAdding: .month, value: 11,
                                to: Calendar.current.propertyMonthStart(for: .now)) ?? .now,
                            budget: 24_000, monthlyLimit: 2_000)
                    }
                    PropertyTableCard {
                        Text("No recovery program configured.").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func maintenanceFactRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(LocalizedStringKey(title)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).monospacedDigit()
        }.font(.callout)
    }

    /// Active program: not deleted, covering the selected month when possible,
    /// otherwise the most recently updated one.
    private func activeMaintenanceProgram(for propertyID: UUID) -> PropertyMaintenanceProgram? {
        let programs = ledger.maintenancePrograms.filter { $0.propertyID == propertyID && $0.deletedAt == nil }
        let byMostRecent: (PropertyMaintenanceProgram, PropertyMaintenanceProgram) -> Bool = {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt < $1.updatedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        let month = Calendar.current.propertyMonthStart(for: selectedMonth)
        return programs.filter { $0.startsAt <= month && month <= $0.endsAt }.max(by: byMostRecent)
            ?? programs.max(by: byMostRecent)
    }

    /// Saving replaces the program by identity — same id, fresh updatedAt —
    /// and only a genuinely new program appends. Cancel never writes.
    private func saveMaintenanceProgram(propertyID: UUID, existingID: UUID?, startsAt: Date, endsAt: Date,
                                        budget: Decimal, monthlyLimit: Decimal) -> Bool {
        if let existingID, let index = ledger.maintenancePrograms.firstIndex(where: { $0.id == existingID }) {
            ledger.maintenancePrograms[index] = PropertyMaintenanceProgram(id: existingID, propertyID: propertyID,
                startsAt: startsAt, endsAt: endsAt, budget: budget, monthlyRecoveryLimit: monthlyLimit, updatedAt: .now)
        } else if existingID == nil {
            ledger.maintenancePrograms.append(PropertyMaintenanceProgram(propertyID: propertyID,
                startsAt: startsAt, endsAt: endsAt, budget: budget, monthlyRecoveryLimit: monthlyLimit, updatedAt: .now))
        } else {
            return false
        }
        let saved = persist()
        if saved { maintenanceDraft = nil }
        return saved
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
    case property, resident, attribution, linkPendingPayment, adjustment, reserve
    case payment(UUID?)
    var id: String {
        switch self {
        case .property: "property"
        case .resident: "resident"
        case .attribution: "attribution"
        case .payment(let id): "payment-\(id?.uuidString ?? "choose")"
        case .linkPendingPayment: "link-pending-payment"
        case .adjustment: "adjustment"
        case .reserve: "reserve"
        }
    }
}

/// Draft for the inline rent editor. `editingID` points at the agreement being
/// edited; `nil` means a new agreement seeded from the selected month.
private struct PropertyRentDraft {
    var propertyID: UUID
    var editingID: UUID?
    var month: Date
    var amount: Decimal
}

/// Draft for the inline maintenance editor. `editingID` points at the program
/// being edited; `nil` means a new program seeded with the creation defaults.
private struct PropertyMaintenanceDraft {
    var propertyID: UUID
    var editingID: UUID?
    var startsAt: Date
    var endsAt: Date
    var budget: Decimal
    var monthlyLimit: Decimal
}

/// Inline maintenance program editor seeded from the existing program: money
/// fields parse with MoneyEntry (two decimals), a failed save keeps the draft
/// with its message, and Cancel never writes.
private struct PropertyMaintenanceProgramEditor: View {
    @State private var startsAt: Date
    @State private var endsAt: Date
    @State private var budgetText: String
    @State private var limitText: String
    @State private var saveError: String?
    var errorMessage: () -> String?
    var onSave: (_ startsAt: Date, _ endsAt: Date, _ budget: Decimal, _ monthlyLimit: Decimal) -> Bool
    var onCancel: () -> Void

    init(draft: PropertyMaintenanceDraft, errorMessage: @escaping () -> String? = { nil },
         onSave: @escaping (Date, Date, Decimal, Decimal) -> Bool, onCancel: @escaping () -> Void) {
        _startsAt = State(initialValue: draft.startsAt)
        _endsAt = State(initialValue: draft.endsAt)
        _budgetText = State(initialValue: MoneyEntry.suggestedEntryText(draft.budget))
        _limitText = State(initialValue: MoneyEntry.suggestedEntryText(draft.monthlyLimit))
        self.errorMessage = errorMessage
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var budget: Decimal? { MoneyEntry.parseEntryAmount(budgetText) }
    private var monthlyLimit: Decimal? { MoneyEntry.parseEntryAmount(limitText) }

    var body: some View {
        StandardEditorForm(title: "Maintenance program",
            isValid: budget != nil && monthlyLimit != nil && startsAt <= endsAt,
            onCancel: onCancel, onSave: {
                guard let budget, let monthlyLimit else { return }
                if !onSave(startsAt, endsAt, budget, monthlyLimit) {
                    saveError = errorMessage() ?? String(localized: "Could not save the maintenance program. Try again.")
                }
            }) {
            DatePicker("Start", selection: $startsAt, displayedComponents: .date)
            DatePicker("End", selection: $endsAt, displayedComponents: .date)
            LabeledContent("Investment budget") {
                TextField("MXN", text: $budgetText)
                    .frame(width: 170)
                    .monospacedDigit()
            }
            LabeledContent {
                TextField("MXN", text: $limitText)
                    .frame(width: 170)
                    .monospacedDigit()
            } label: {
                Text("Maximum recovery per month").fixedSize(horizontal: false, vertical: true)
            }
            Text("The budget helps planning. Only linked expenses count as actual investment.")
                .font(.caption).foregroundStyle(.secondary)
            if let saveError { Text(saveError).font(.callout).foregroundStyle(.red) }
        }
    }
}

/// Inline rent agreement editor: seeded draft, Cancel/Save, and a failed save
/// keeps the draft with its message.
private struct PropertyRentAgreementEditor: View {
    @State private var amountText: String
    @State private var effectiveMonth: Date
    @State private var saveError: String?
    var errorMessage: () -> String?
    var onSave: (_ amount: Decimal, _ effectiveMonth: Date) -> Bool
    var onCancel: () -> Void

    init(month: Date, amount: Decimal, errorMessage: @escaping () -> String? = { nil },
         onSave: @escaping (Decimal, Date) -> Bool, onCancel: @escaping () -> Void) {
        _amountText = State(initialValue: MoneyEntry.suggestedEntryText(amount))
        _effectiveMonth = State(initialValue: month)
        self.errorMessage = errorMessage
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var amount: Decimal? { MoneyEntry.parseEntryAmount(amountText) }

    var body: some View {
        StandardEditorForm(title: "Rent agreement", isValid: amount != nil,
            onCancel: onCancel, onSave: {
                guard let amount else { return }
                if !onSave(amount, effectiveMonth) {
                    saveError = errorMessage() ?? String(localized: "Could not save the rent agreement. Try again.")
                }
            }) {
            LabeledContent("Monthly rent") {
                TextField("MXN", text: $amountText)
                    .frame(width: 170)
                    .monospacedDigit()
            }
            DatePicker("Effective from", selection: $effectiveMonth, displayedComponents: .date)
            Text("Changes do not modify already-closed months.").font(.caption).foregroundStyle(.secondary)
            if let saveError { Text(saveError).font(.callout).foregroundStyle(.red) }
        }
    }
}

#Preview {
    PropertiesView(workspace: PropertyWorkspaceModel(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("PropertyPreview-\(UUID().uuidString).json")))
        .modelContainer(HouseholdSettlementFixture.makePreviewContainer())
}
