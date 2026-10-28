import Foundation
import Observation
import SwiftData
import os

enum PropertyDestination: Hashable, Sendable {
    case allHomes
    case household
    case property(UUID)

    static let householdName = "Paseo de los Parques"
}

enum PropertyWorkspaceSection: String, CaseIterable, Identifiable {
    case month = "Month"
    case configuration = "Configuration"

    var id: String { rawValue }
}

/// Shared presentation state. Navigation never writes financial data or loads transactions.
@MainActor @Observable
final class PropertyWorkspaceModel {
    var destination: PropertyDestination = .allHomes {
        didSet {
            if destination != oldValue { beginInteraction("Cambiar casa"); section = .month }
        }
    }
    var section: PropertyWorkspaceSection = .month {
        didSet { if section != oldValue { beginInteraction("Abrir sección") } }
    }
    private(set) var asOf: Date
    private(set) var selectedMonth: Date
    var ledger = PropertyLedger() {
        didSet { mutationGeneration &+= 1 }
    }
    private(set) var ledgerAvailable = false
    private(set) var isLoading = false
    private(set) var isLoadingPeriod = false
    var error: String?
    var showingNewProperty = false
    private(set) var transactionInputs: [PropertyTransactionInput] = []
    private(set) var householdTransactions: [Transaction] = []
    @ObservationIgnored private var periodTransactions: [Transaction] = []
    @ObservationIgnored private var periodDueDateOverrides: [SettlementDueDateOverride] = []
    @ObservationIgnored private var cachedHouseholdAssignments: [UUID: HouseholdAssignmentSnapshot] = [:]
    private(set) var householdDueDates: [UUID: Date] = [:]
    private(set) var householdSetup = HouseholdSettlementSetup.empty
    private(set) var persistedHouseholdSetup = HouseholdSettlementSetup.empty
    private var storedHouseholdReport: HouseholdSettlementReport?
    private var storedReports: [UUID: PropertyMonthlyReport] = [:]
    private(set) var transactionFetchCount = 0
    private(set) var inputRevision = 0

    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private var context: ModelContext?
    @ObservationIgnored private var hasAccounts = false
    @ObservationIgnored private var cachedMonth: Date?
    @ObservationIgnored private var queriedSourceIDs: Set<UUID> = []
    @ObservationIgnored private var savedLedger = PropertyLedger()
    @ObservationIgnored private var loadingTask: Task<PropertyLedger, Error>?
    @ObservationIgnored private var isSaving = false
    @ObservationIgnored private var periodTask: Task<Bool, Never>?
    @ObservationIgnored private var periodTaskID: UUID?
    @ObservationIgnored private var inputGeneration: UInt = 0
    @ObservationIgnored private var mutationGeneration: UInt = 0
    @ObservationIgnored private var loadingGeneration: UInt = 0
    @ObservationIgnored private var loadingID: UUID?
    @ObservationIgnored private let readLedger: @Sendable (URL?) async throws -> PropertyLedger
    @ObservationIgnored private let writeLedger: (PropertyLedger, URL?) throws -> Void
    @ObservationIgnored private let fetchTransactions: (ModelContext, FetchDescriptor<Transaction>) throws -> [Transaction]
    /// Test seam over the assignment-revision guard: the register between the
    /// income creation and the marker pin cannot race synchronously, so tests
    /// substitute the guard to model another window's write. Production uses
    /// the real disk comparison below.
    @ObservationIgnored private let revisionCheckOverride: (@MainActor () throws -> Void)?
    /// Test seam over the saved-payment lookup in `retirePendingLinks`: a
    /// failed fetch must keep every marker instead of retiring them all.
    /// Production leaves it nil and performs the real fresh-context fetch.
    @ObservationIgnored private let pendingLinkFetchOverride: (([UUID]) throws -> [Transaction])?
    @ObservationIgnored private var interactionStart: ContinuousClock.Instant?
    @ObservationIgnored private var interactionName = ""
    @ObservationIgnored private var interactionInterval: OSSignpostIntervalState?
    private static let signposter = OSSignposter(subsystem: "com.financeTracker.app", category: "PropertyWorkspace")
    private static let performanceLogger = Logger(subsystem: "com.financeTracker.app", category: "PropertyWorkspace")

    init(month: Date = .now, asOf: Date = .now, fileURL: URL? = nil,
         readLedger: @escaping @Sendable (URL?) async throws -> PropertyLedger = { url in
             try await Task.detached { try PropertyLedgerStore.read(fileURL: url) }.value
         }, fetchTransactions: @escaping (ModelContext, FetchDescriptor<Transaction>) throws -> [Transaction] = { try $0.fetch($1) },
         writeLedger: @escaping (PropertyLedger, URL?) throws -> Void = { try PropertyLedgerStore.replace(with: $0, at: $1) },
         revisionCheckOverride: (@MainActor () throws -> Void)? = nil,
         pendingLinkFetchOverride: (([UUID]) throws -> [Transaction])? = nil) {
        self.asOf = asOf
        selectedMonth = Calendar.current.propertyMonthStart(for: month)
        self.fileURL = fileURL
        self.readLedger = readLedger
        self.writeLedger = writeLedger
        self.fetchTransactions = fetchTransactions
        self.revisionCheckOverride = revisionCheckOverride
        self.pendingLinkFetchOverride = pendingLinkFetchOverride
    }

    var periodReady: Bool { cachedMonth == selectedMonth }
    var householdReport: HouseholdSettlementReport? { periodReady ? storedHouseholdReport : nil }
    var reports: [UUID: PropertyMonthlyReport] { periodReady ? storedReports : [:] }

    var householdMonthlyReport: PropertyMonthlyReport? {
        guard let source = householdReport else { return nil }
        return PropertyHouseholdAdapter.report(source, ledger: ledger, transactions: transactionInputs, asOf: asOf)
    }

    func settlementContext(propertyID: UUID, report: PropertyMonthlyReport) -> PropertyMemberSettlement.Context {
        let closed = ledger.closes.contains { $0.propertyID == propertyID && $0.monthStart == report.monthStart }
        let household = destination == .household
        let historical = household && householdMonth(report.monthStart) == nil && !closed
        let canCalculate = household ? householdReport?.splitAvailable == true
            : report.residents.reduce(Decimal.zero) { $0 + $1.income } > 0 && report.obligations.allSatisfy {
                if case .owner = $0.responsibility { return true }
                return $0.allocations.values.reduce(Decimal.zero, +) == $0.amount
            }
        return .init(canCalculate: canCalculate, isClosed: closed, historical: historical,
                     includeCurrent: !historical)
    }

    func memberSettlements(propertyID: UUID, report: PropertyMonthlyReport) -> [PropertyMemberSettlement] {
        let context = settlementContext(propertyID: propertyID, report: report)
        let visible = destination == .household && !context.isClosed ? householdActiveMemberIDs : nil
        let former = Set(ledger.residents.filter { $0.propertyID == propertyID }.map(\.id))
        return PropertyMemberSettlement.summarizeAll(propertyID: propertyID, report: report,
            ledger: ledger, inputs: transactionInputs, asOf: asOf, context: context,
            visibleIDs: visible, additionalResidentIDs: former)
    }

    /// The member account behind the collection sheet: the settlement facts
    /// decomposed into the components the sheet explains money with. Pure —
    /// same ledger, inputs, and context pieces as `memberSettlements`;
    /// nothing is written and the ledger is not rescanned twice.
    func memberAccount(propertyID: UUID, residentID: UUID, report: PropertyMonthlyReport) -> PropertyMemberAccount? {
        PropertyMemberAccount.account(propertyID: propertyID, residentID: residentID, report: report,
            ledger: ledger, inputs: transactionInputs, asOf: asOf,
            context: settlementContext(propertyID: propertyID, report: report))
    }

    var householdSummary: String? {
        guard let source = householdReport else { return nil }
        let roles = ledger.householdLink ?? PropertyHouseholdAdapter.link
        if let close = ledger.closes.first(where: { $0.propertyID == roles.propertyID && $0.monthStart == selectedMonth }) {
            return PropertyHouseholdAdapter.closedSummary(close)
        }
        return source.plainTextSummary
    }

    var householdActiveMemberIDs: Set<UUID> {
        PropertyHouseholdAdapter.activeMemberIDs(ledger: ledger, month: selectedMonth)
    }

    func member(id: UUID) -> PropertyResident? {
        if let resident = ledger.residents.first(where: { $0.id == id }) { return resident }
        let link = ledger.householdLink ?? PropertyHouseholdAdapter.link
        guard destination == .household, id == link.userID || id == link.partnerID else { return nil }
        return PropertyResident(id: id, propertyID: link.propertyID,
            name: id == link.userID ? String(localized: "You") : "Fer", activeFrom: .distantPast)
    }

    @discardableResult
    func renameMember(id: UUID, name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetID = destination == .household ? (ledger.householdLink ?? PropertyHouseholdAdapter.link).propertyID : propertyID
        guard ledgerAvailable, !name.isEmpty, let member = member(id: id), member.propertyID == targetID else { return false }
        do { try checkAssignmentRevision() } catch { self.error = error.localizedDescription; return false }
        if destination == .household { prepareHouseholdLink() }
        guard let index = ledger.residents.firstIndex(where: { $0.id == id }) else { return false }
        ledger.residents[index].name = name
        ledger.residents[index].updatedAt = PersistedMutationClock.next(after: ledger.residents[index].updatedAt)
        return save()
    }

    @discardableResult
    func removeMember(id: UUID, today: Date = .now) -> Bool {
        let targetID = destination == .household ? (ledger.householdLink ?? PropertyHouseholdAdapter.link).propertyID : propertyID
        guard ledgerAvailable, let member = member(id: id), member.propertyID == targetID else { return false }
        do { try checkAssignmentRevision() } catch { self.error = error.localizedDescription; return false }
        if destination == .household { prepareHouseholdLink() }
        guard let index = ledger.residents.firstIndex(where: { $0.id == id }) else { return false }
        let lastMonth = PropertyParticipation.lastActiveMonth(selected: selectedMonth, today: today)
        ledger.residents[index].activeThrough = min(ledger.residents[index].activeThrough ?? lastMonth, lastMonth)
        ledger.residents[index].updatedAt = PersistedMutationClock.next(after: ledger.residents[index].updatedAt)
        return save()
    }

    private func readHouseholdSetup(month: Date, container: ModelContainer) throws -> HouseholdSettlementSetup {
        if let record = householdMonth(month) {
            return HouseholdSettlementSetup(partnerIncomeEstimate: record.partnerIncome,
                useUserIncomeManualOverride: record.useUserOverride, userIncomeManualOverride: record.userIncome,
                splitMethod: record.splitMethodValue,
                customUserPercent: record.customUserPercent, customPartnerPercent: record.customPartnerPercent, notes: record.notes)
        }
        return try HouseholdWorkspacePersistence.read(month: month, container: container)
    }

    func householdMonth(_ month: Date) -> PropertyHouseholdMonth? {
        ledger.householdMonths?.filter { $0.monthStart == month && $0.deletedAt == nil }
            .max { $0.updatedAt < $1.updatedAt }
    }

    /// Only called by explicit edits, never by navigation or bootstrap.
    @discardableResult
    func prepareHouseholdLink() -> PropertyHouseholdLink {
        if let link = ledger.householdLink { return link }
        let link = PropertyHouseholdAdapter.link
        ledger.properties.append(PropertyRecord(id: link.propertyID, name: PropertyDestination.householdName))
        ledger.residents.append(PropertyResident(id: link.userID, propertyID: link.propertyID, name: String(localized: "You"), activeFrom: .distantPast))
        ledger.residents.append(PropertyResident(id: link.partnerID, propertyID: link.propertyID, name: "Fer", activeFrom: .distantPast))
        ledger.householdLink = link
        return link
    }

    @discardableResult
    func saveMonthlyIncome(residentID: UUID, amount: Decimal, confirmed: Bool, month: Date,
                           editedDestination: PropertyDestination? = nil) -> Bool {
        guard amount >= 0, editedDestination != nil || month == selectedMonth else { return false }
        let target = editedDestination ?? destination
        let houseID: UUID
        switch target {
        case .household: houseID = ledger.householdLink?.propertyID ?? PropertyHouseholdAdapter.link.propertyID
        case .property(let id): houseID = id
        case .allHomes: return false
        }
        guard !ledger.closes.contains(where: { $0.propertyID == houseID && $0.monthStart == month }) else { return false }
        if target == .household {
            guard PropertyHouseholdAdapter.activeMemberIDs(ledger: ledger, month: month).contains(residentID) else { return false }
            let setup: HouseholdSettlementSetup
            if let context {
                do { setup = try readHouseholdSetup(month: month, container: context.container) }
                catch { self.error = error.localizedDescription; return false }
            } else { setup = householdSetup }
            let link = prepareHouseholdLink()
            var record = householdMonth(month) ?? PropertyHouseholdMonth(
                id: .deterministic(link.propertyID, month, "household-setup"), monthStart: month,
                partnerIncome: setup.partnerIncomeEstimate, userIncome: setup.userIncomeManualOverride,
                useUserOverride: setup.useUserIncomeManualOverride, splitMethod: setup.splitMethod.rawValue,
                customUserPercent: setup.customUserPercent, customPartnerPercent: setup.customPartnerPercent,
                notes: setup.notes, updatedAt: .now)
            if residentID == link.userID {
                record.userIncome = amount; record.useUserOverride = true
                record.userConfirmedAt = confirmed ? .now : nil
            } else if residentID == link.partnerID {
                record.partnerIncome = amount; record.partnerConfirmedAt = confirmed ? .now : nil
            } else { return false }
            record.updatedAt = .now
            var records = ledger.householdMonths ?? []
            records.removeAll { $0.id == record.id }; records.append(record)
            ledger.householdMonths = records
        } else {
            let propertyID = houseID
            guard ledger.activeProperties.contains(where: { $0.id == propertyID }),
                  ledger.residents(for: propertyID, month: month).contains(where: { $0.id == residentID }) else { return false }
            let matching = ledger.incomes.indices.filter { ledger.incomes[$0].residentID == residentID && ledger.incomes[$0].monthStart == month && ledger.incomes[$0].deletedAt == nil }
            if let index = matching.first {
                ledger.incomes[index].amount = amount
                ledger.incomes[index].confirmedAt = confirmed ? .now : nil
                ledger.incomes[index].updatedAt = .now
                for duplicate in matching.dropFirst() { ledger.incomes[duplicate].deletedAt = .now; ledger.incomes[duplicate].updatedAt = .now }
            } else {
                ledger.incomes.append(PropertyIncome(propertyID: propertyID, residentID: residentID, monthStart: month,
                    amount: amount, confirmedAt: confirmed ? .now : nil))
            }
        }
        // All writes run synchronously on MainActor; a blur save cannot overtake Enter.
        guard save() else { return false }
        if target == .household, month == selectedMonth, let context {
            do {
                let setup = try readHouseholdSetup(month: month, container: context.container)
                persistedHouseholdSetup = setup; householdSetup = setup; recompute()
            } catch { self.error = error.localizedDescription; return false }
        }
        return true
    }

    var properties: [PropertyRecord] {
        ledger.activeProperties.filter { $0.id != ledger.householdLink?.propertyID }.sorted {
            let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
            return comparison == .orderedSame ? $0.id.uuidString < $1.id.uuidString : comparison == .orderedAscending
        }
    }

    var propertyID: UUID? {
        guard case .property(let id) = destination else { return nil }
        return id
    }

    var title: String {
        switch destination {
        case .allHomes: String(localized: "All homes")
        case .household: PropertyDestination.householdName
        case .property(let id): properties.first { $0.id == id }?.name ?? String(localized: "Properties")
        }
    }

    var sections: [PropertyWorkspaceSection] {
        if destination == .allHomes { return [] }
        // Household has nothing to configure: rent never enters its settlement
        // and it owns no maintenance program.
        if destination == .household { return [.month] }
        return PropertyWorkspaceSection.allCases
    }

    func configure(context: ModelContext, hasAccounts: Bool) {
        if self.hasAccounts != hasAccounts || self.context !== context {
            cachedMonth = nil
            inputGeneration &+= 1
        }
        self.context = context
        self.hasAccounts = hasAccounts
    }

    func shiftMonth(_ offset: Int) {
        selectMonth(Calendar.current.date(byAdding: .month, value: offset, to: selectedMonth) ?? selectedMonth)
    }

    func selectMonth(_ date: Date) {
        let month = Calendar.current.propertyMonthStart(for: date)
        guard month != selectedMonth else { return }
        beginInteraction("Cambiar mes")
        selectedMonth = month
        Task { await refreshPeriod() }
    }

    func loadLedger() async {
        guard !isSaving else { return }
        isLoading = true
        let task: Task<PropertyLedger, Error>
        let generation: UInt
        let id: UUID
        if let loadingTask { task = loadingTask }
        else {
            let url = fileURL
            let reader = readLedger
            task = Task { try await reader(url) }
            loadingTask = task
            loadingGeneration = mutationGeneration
            loadingID = UUID()
        }
        generation = loadingGeneration
        id = loadingID ?? UUID()
        defer {
            if loadingID == id { loadingTask = nil; loadingID = nil; isLoading = false }
        }
        do {
            let loaded = try await task.value
            guard generation == mutationGeneration else { return }
            applyLedger(loaded)
            error = nil
        } catch {
            guard generation == mutationGeneration else { return }
            self.error = error.localizedDescription
            ledgerAvailable = false
        }
    }

    func retry() async {
        await loadLedger()
        guard ledgerAvailable else { return }
        await refreshPeriod(force: true)
    }

    func applyLedger(_ loaded: PropertyLedger) {
        ledger = loaded
        savedLedger = loaded
        ledgerAvailable = true
        reconcileDestination()
        if let context, let setup = try? readHouseholdSetup(month: selectedMonth, container: context.container) {
            householdSetup = setup; persistedHouseholdSetup = setup
        }
        // A newly linked historical source must be included in the cached input.
        if !requiredSourceIDs.isSubset(of: queriedSourceIDs) { cachedMonth = nil }
        if cachedMonth != nil { recompute() }
    }

    func reconcileDestination() {
        if case .property(let id) = destination,
           !ledger.activeProperties.contains(where: { $0.id == id }) {
            destination = .allHomes
        }
    }

    func refreshPeriod(force: Bool = false) async {
        guard context != nil else { return }
        if force { inputGeneration &+= 1; cachedMonth = nil }
        while cachedMonth != selectedMonth {
            let task: Task<Bool, Never>
            let id: UUID
            if let existing = periodTask {
                task = existing
                id = periodTaskID ?? UUID()
            } else {
                id = UUID()
                isLoadingPeriod = true
                task = Task {
                    await Task.yield()
                    return await readPeriod()
                }
                periodTaskID = id
                periodTask = task
            }
            let succeeded = await task.value
            if periodTaskID == id { periodTask = nil; periodTaskID = nil; isLoadingPeriod = false }
            if !succeeded { return }
        }
    }

    private func readPeriod() async -> Bool {
        guard let context else { return false }
        let requestedMonth = selectedMonth
        let generation = inputGeneration
        let requiredIDs = requiredSourceIDs
        let interval = Self.signposter.beginInterval("Load property period")
        defer { Self.signposter.endInterval("Load property period", interval) }
        guard hasAccounts else {
            do {
                let setup = try readHouseholdSetup(month: requestedMonth, container: context.container)
                householdSetup = setup
                persistedHouseholdSetup = setup
            } catch {
                self.error = String(format: String(localized: "Could not read the monthly setup: %@"), error.localizedDescription)
                cachedMonth = nil
                return false
            }
            transactionInputs = []
            householdTransactions = []
            periodTransactions = []; periodDueDateOverrides = []; cachedHouseholdAssignments = [:]
            householdDueDates = [:]
            queriedSourceIDs = requiredIDs
            cachedMonth = requestedMonth
            inputRevision &+= 1
            if ledgerAvailable { error = nil }
            recompute()
            return true
        }
        do {
            let overrides = try context.fetch(FetchDescriptor<SettlementDueDateOverride>())
            let dueDates = SettlementDueDateService.resolveActiveDueDates(overrides)
            let month = requestedMonth
            let end = Calendar.current.date(byAdding: .month, value: 1, to: month) ?? month
            let dueIDs = dueDates.filter { $0.value >= month && $0.value < end }.map(\.key)
            let linkedIDs = Array(requiredIDs.union(dueIDs))
            let descriptor = FetchDescriptor<Transaction>(predicate: #Predicate<Transaction> { tx in
                (tx.postedAt >= month && tx.postedAt < end) || linkedIDs.contains(tx.id)
            }, sortBy: [SortDescriptor(\.postedAt, order: .reverse)])
            let transactions = try fetchTransactions(context, descriptor)
            transactionFetchCount += 1
            var inputs: [PropertyTransactionInput] = []
            inputs.reserveCapacity(transactions.count)
            for (index, tx) in transactions.enumerated() {
                inputs.append(PropertyTransactionInput(capturing: tx))
                if index % 64 == 63 {
                    await Task.yield()
                    if requestedMonth != selectedMonth || generation != inputGeneration { return true }
                }
            }
            guard requestedMonth == selectedMonth, generation == inputGeneration,
                  requiredIDs == requiredSourceIDs else { return true }
            let setup = try readHouseholdSetup(month: month, container: context.container)
            // Missing historical sources are cached too, so income edits do not refetch them.
            queriedSourceIDs = requiredIDs
            transactionInputs = inputs
            periodTransactions = transactions
            cachedHouseholdAssignments = Dictionary(transactions.map { ($0.id, HouseholdAssignmentSnapshot($0)) }, uniquingKeysWith: { first, _ in first })
            periodDueDateOverrides = overrides
            let dueSet = Set(dueIDs)
            householdTransactions = transactions.filter {
                $0.deletedAt == nil && $0.postedAt <= asOf && (($0.postedAt >= month && $0.postedAt < end) || dueSet.contains($0.id))
            }
            householdDueDates = dueDates
            householdSetup = setup
            persistedHouseholdSetup = setup
            cachedMonth = month
            inputRevision &+= 1
            if ledgerAvailable { error = nil }
            recompute()
            return true
        } catch {
            cachedMonth = nil
            self.error = String(format: String(localized: "Could not read transactions: %@"), error.localizedDescription)
            return false
        }
    }

    func updateHouseholdSetup(_ setup: HouseholdSettlementSetup) {
        householdSetup = setup
        recompute()
    }

    func commitHouseholdSetup(_ setup: HouseholdSettlementSetup, month: Date) {
        guard month == selectedMonth else { return }
        persistedHouseholdSetup = setup
        updateHouseholdSetup(setup)
    }

    func discardHouseholdDraft() { updateHouseholdSetup(persistedHouseholdSetup) }

    private func beginInteraction(_ name: String) {
        // A destination change can also reset its section in the same update.
        guard interactionStart == nil else { return }
        interactionStart = .now
        interactionName = name
        interactionInterval = Self.signposter.beginInterval("Property interaction to draw")
    }

    func didDraw() {
        guard let start = interactionStart, let interval = interactionInterval else { return }
        let duration = start.duration(to: .now)
        let milliseconds = Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
        Self.signposter.endInterval("Property interaction to draw", interval)
        Self.performanceLogger.notice("Property UI: \(self.interactionName, privacy: .public) — first AppKit draw \(milliseconds, privacy: .public) ms")
        interactionStart = nil
        interactionInterval = nil
    }

    func recompute() {
        let interval = Self.signposter.beginInterval("Recalculate property reports")
        defer { Self.signposter.endInterval("Recalculate property reports", interval) }
        storedHouseholdReport = HouseholdSettlementReportService.build(monthStart: selectedMonth,
            transactions: householdTransactions, dueDates: householdDueDates, setup: householdSetup,
            participatingUser: householdActiveMemberIDs.contains((ledger.householdLink ?? PropertyHouseholdAdapter.link).userID),
            participatingPartner: householdActiveMemberIDs.contains((ledger.householdLink ?? PropertyHouseholdAdapter.link).partnerID))
        storedReports = Dictionary(uniqueKeysWithValues: properties.map { property in
            let report: PropertyMonthlyReport
            if let close = ledger.closes.first(where: { $0.propertyID == property.id && $0.monthStart == selectedMonth }) {
                report = PropertySettlementCalculator.frozenReport(close, ledger: ledger, transactions: transactionInputs, asOf: asOf)
            } else {
                report = PropertySettlementCalculator.report(propertyID: property.id, month: selectedMonth,
                    ledger: ledger, transactions: transactionInputs, asOf: asOf)
            }
            return (property.id, report)
        })
    }

    func recoveryReceipts(propertyID: UUID) -> [PropertyTransactionInput] {
        guard let context, ((try? context.fetchCount(FetchDescriptor<Account>())) ?? 0) > 0 else { return [] }
        let descriptor = FetchDescriptor<Transaction>(predicate: #Predicate<Transaction> { $0.amount > 0 },
            sortBy: [SortDescriptor(\.postedAt, order: .reverse)])
        guard let transactions = try? context.fetch(descriptor) else { return [] }
        let active = ledger.paymentApplications.filter { $0.deletedAt == nil }
        let appliedBySource = Dictionary(grouping: active, by: \.paymentTransactionID).mapValues {
            $0.reduce(Decimal.zero) { $0 + $1.amount }
        }
        let advancedSources = Set(active.filter { $0.propertyID == propertyID && PropertyPaymentAdvance.isAdvance($0) }
            .map(\.paymentTransactionID))
        let attributedSources = Set(ledger.attributions.filter { $0.deletedAt == nil }.map(\.transactionID))
        let availability = PropertyAssignmentService.availability(propertyID: propertyID, ledger: ledger)
        return transactions.map(PropertyTransactionInput.init(capturing:)).filter { source in
            PropertySettlementCalculator.isValidCollectionPayment(source, asOf: max(asOf, .now))
                && availability.allows(source)
                && !attributedSources.contains(source.id)
                && ((appliedBySource[source.id] ?? 0) < source.amount || advancedSources.contains(source.id))
        }
    }

    /// Captures whose income is real but whose property link has not completed.
    /// The marker is workflow state keyed by UUID, so renames, description edits,
    /// and look-alike incomes never confuse it. Pure read for the render path:
    /// markers whose movement vanished or was soft-deleted are not live money,
    /// never surface, and are retired by `retirePendingLinks` — never here.
    func pendingLinks(propertyID: UUID) -> [(link: PropertyPaymentPendingLink, input: PropertyTransactionInput?)] {
        guard let context else { return [] }
        let markers = ledger.pendingLinks.filter { $0.propertyID == propertyID && $0.deletedAt == nil }
        guard !markers.isEmpty else { return [] }
        let ids = Array(Set(markers.map(\.paymentTransactionID)))
        let freshContext = ModelContext(context.container)
        freshContext.autosaveEnabled = false
        let fetched = (try? freshContext.fetch(FetchDescriptor<Transaction>(
            predicate: #Predicate<Transaction> { ids.contains($0.id) }))) ?? []
        let inputsByID = Dictionary(fetched.map { ($0.id, PropertyTransactionInput(capturing: $0)) },
                                    uniquingKeysWith: { first, _ in first })
        var result: [(link: PropertyPaymentPendingLink, input: PropertyTransactionInput?)] = []
        for marker in markers {
            guard let input = inputsByID[marker.paymentTransactionID], input.deletedAt == nil else { continue }
            if result.contains(where: { $0.link.paymentTransactionID == marker.paymentTransactionID }) { continue }
            result.append((marker, input))
        }
        return result
    }

    /// Orphan cleanup for the pending-link markers: a marker whose movement
    /// vanished or was soft-deleted is workflow state behind money that is no
    /// longer live, so it is removed and the register is saved. The view calls
    /// this from a task when the property or month changes — never from the
    /// render path. A failed lookup retires nothing: an unreadable store must
    /// never read as "the money vanished", so the markers are kept for the next
    /// task to retry. Returns false when nothing needed retirement, the lookup
    /// failed, or the save failed.
    @discardableResult
    func retirePendingLinks(propertyID: UUID) -> Bool {
        guard let context else { return false }
        let markers = ledger.pendingLinks.filter { $0.propertyID == propertyID && $0.deletedAt == nil }
        guard !markers.isEmpty else { return true }
        let ids = Array(Set(markers.map(\.paymentTransactionID)))
        let fetched: [Transaction]
        do {
            if let pendingLinkFetchOverride {
                fetched = try pendingLinkFetchOverride(ids)
            } else {
                let freshContext = ModelContext(context.container)
                freshContext.autosaveEnabled = false
                fetched = try freshContext.fetch(FetchDescriptor<Transaction>(
                    predicate: #Predicate<Transaction> { ids.contains($0.id) }))
            }
        } catch {
            self.error = String(localized: "The saved payment lookup failed; recovery markers were kept.")
            return false
        }
        let inputsByID = Dictionary(fetched.map { ($0.id, PropertyTransactionInput(capturing: $0)) },
                                    uniquingKeysWith: { first, _ in first })
        let vanished = Set(markers.filter { marker in
            guard let input = inputsByID[marker.paymentTransactionID] else { return true }
            return input.deletedAt != nil
        }.map(\.paymentTransactionID))
        guard !vanished.isEmpty else { return true }
        ledger.pendingLinks.removeAll { vanished.contains($0.paymentTransactionID) }
        return save()
    }

    enum CollectionOutcome {
        case saved
        case needsLink(UUID)
        case rejected(String)
    }

    static func eligibleCollectionAccount(_ account: Account, on date: Date) -> Bool {
        account.archivedAt == nil && account.closedAt == nil && account.currency == "MXN"
    }

    static func isMXNCollectionAmount(_ amount: Decimal) -> Bool {
        guard amount > 0, !amount.isNaN else { return false }
        var scaled = amount * 100
        var wholeCents = Decimal()
        NSDecimalRound(&wholeCents, &scaled, 0, .plain)
        return scaled == wholeCents
    }

    /// Re-read only previously linked advances at save time: another window may
    /// have edited their financial sources since the monthly cache was built.
    private func inputsWithFreshAdvanceSources(propertyID: UUID, residentID: UUID,
                                               context: ModelContext) throws -> [PropertyTransactionInput] {
        let ids = Set(ledger.paymentApplications.filter {
            $0.propertyID == propertyID && $0.residentID == residentID && $0.deletedAt == nil
                && PropertyPaymentAdvance.isAdvance($0)
        }.map(\.paymentTransactionID))
        guard !ids.isEmpty else { return transactionInputs }
        let sourceIDs = Array(ids)
        let freshContext = ModelContext(context.container)
        freshContext.autosaveEnabled = false
        let descriptor = FetchDescriptor<Transaction>(predicate: #Predicate<Transaction> { sourceIDs.contains($0.id) })
        let fresh = try freshContext.fetch(descriptor).map(PropertyTransactionInput.init(capturing:))
        return transactionInputs.filter { !ids.contains($0.id) } + fresh
    }

    /// Upserts the pending-link marker for a collection payment and saves the
    /// register. Pure workflow-state write: no financial row is touched, so
    /// callers run the assignment-revision guard first whenever money already
    /// exists behind the marker. Returns false when the save failed (`error`
    /// carries why, and the in-memory register was rolled back).
    private func upsertPendingMarker(propertyID: UUID, residentID: UUID, amount: Decimal,
                                     paymentTransactionID: UUID) -> Bool {
        var withMarker = ledger
        if destination == .household, withMarker.householdLink == nil {
            let link = PropertyHouseholdAdapter.link
            withMarker.householdLink = link
            withMarker.properties.append(PropertyRecord(id: link.propertyID, name: PropertyDestination.householdName))
            withMarker.residents.append(PropertyResident(id: link.userID, propertyID: link.propertyID,
                name: String(localized: "You"), activeFrom: .distantPast))
            withMarker.residents.append(PropertyResident(id: link.partnerID, propertyID: link.propertyID,
                name: "Fer", activeFrom: .distantPast))
        }
        if let index = withMarker.pendingLinks.firstIndex(where: {
            $0.paymentTransactionID == paymentTransactionID && $0.deletedAt == nil
        }) {
            withMarker.pendingLinks[index].propertyID = propertyID
            withMarker.pendingLinks[index].residentID = residentID
            withMarker.pendingLinks[index].amount = amount
        } else {
            withMarker.pendingLinks.append(PropertyPaymentPendingLink(
                propertyID: propertyID, residentID: residentID,
                paymentTransactionID: paymentTransactionID, amount: amount))
        }
        ledger = withMarker
        return save()
    }

    /// Marker-first commit: the recovery marker is pinned to a fresh payment
    /// UUID before the income exists, so a failed marker write rejects without
    /// creating money and a failed income save is a clean rejection whose
    /// orphan marker retires itself on the next task. Once the income is real,
    /// a failed property write leaves an identifiable receipt: retrying with
    /// its UUID never inserts another financial movement.
    func registerCollection(propertyID: UUID, residentID: UUID, account: Account?, amount: Decimal,
                            date: Date, pendingTransactionID: UUID? = nil) -> CollectionOutcome {
        guard ledgerAvailable, periodReady, let context else {
            return .rejected(String(localized: "Property report unavailable. Retry loading."))
        }
        guard amount > 0, !amount.isNaN, date <= .now,
              member(id: residentID)?.propertyID == propertyID,
              propertyID == (destination == .household ? (ledger.householdLink ?? PropertyHouseholdAdapter.link).propertyID : self.propertyID)
        else { return .rejected(String(localized: "Check the member, amount and payment date.")) }
        if pendingTransactionID == nil && !Self.isMXNCollectionAmount(amount) {
            return .rejected(String(localized: "Enter an MXN amount with at most two decimal places."))
        }
        let report: PropertyMonthlyReport?
        if destination == .household { report = householdMonthlyReport }
        else { report = reports[propertyID] }
        guard let report else { return .rejected(String(localized: "Property report unavailable. Retry loading.")) }
        let verifiedInputs: [PropertyTransactionInput]
        do {
            verifiedInputs = try inputsWithFreshAdvanceSources(propertyID: propertyID,
                                                               residentID: residentID, context: context)
        } catch { return .rejected(error.localizedDescription) }
        let transaction: Transaction
        if let pendingTransactionID {
            do {
                let descriptor = FetchDescriptor<Transaction>(predicate: #Predicate<Transaction> { $0.id == pendingTransactionID })
                guard let existing = try context.fetch(descriptor).first else {
                    return .rejected(String(localized: "The registered receipt could not be found."))
                }
                transaction = existing
            } catch { return .rejected(error.localizedDescription) }
            // The receipt is already real money. Refresh its marker durably
            // before the property write so an interrupted link survives reloads
            // and stays recoverable by UUID; the upsert reuses the same marker.
            do {
                try checkAssignmentRevision()
                guard upsertPendingMarker(propertyID: propertyID, residentID: residentID,
                                          amount: amount, paymentTransactionID: transaction.id) else {
                    return .needsLink(transaction.id)
                }
            } catch {
                // The income exists and is identified by UUID: a rejection here
                // strands nothing, and the retry reuses the same receipt.
                return .rejected(error.localizedDescription)
            }
        } else {
            guard let account else {
                return .rejected(String(localized: "Choose an active MXN account."))
            }
            do {
                // Same fresh-state truth as movements and transfers: the
                // received object may be stale if another window archived or
                // closed the account after this sheet loaded.
                try AccountCaptureValidation.ensureAvailable(account, context: context)
                guard account.currency == "MXN" else {
                    return .rejected(String(localized: "Choose an active MXN account."))
                }
                try checkAssignmentRevision()
            } catch { return .rejected(error.localizedDescription) }
            // Marker-first: pin the payment's UUID durably before the income
            // exists. A failed marker write is a clean rejection with no
            // receipt; a failed income write leaves only this marker, which the
            // next task retires once a successful lookup finds no row.
            let paymentID = UUID()
            guard upsertPendingMarker(propertyID: propertyID, residentID: residentID,
                                      amount: amount, paymentTransactionID: paymentID) else {
                return .rejected(self.error ?? String(localized: "The property register could not be saved. Try again."))
            }
            do {
                let name = member(id: residentID)?.name ?? String(localized: "Member")
                let houseName = ledger.properties.first { $0.id == propertyID }?.name ?? PropertyDestination.householdName
                transaction = try ManualTransactionService.create(account: account, date: date,
                    description: String(format: String(localized: "Payment from %@ · %@"), name, houseName),
                    signedAmount: amount, category: nil, flowKindRaw: TransactionFlowKind.income.rawValue,
                    treatmentKindRaw: TransactionTreatmentKind.regular.rawValue,
                    id: paymentID, context: context)
            } catch { return .rejected(error.localizedDescription) }
        }
        let source = PropertyTransactionInput(capturing: transaction)
        guard source.amount == amount,
              PropertySettlementCalculator.isValidCollectionPayment(source, asOf: max(asOf, .now)) else {
            let message = String(localized: "The registered receipt is not eligible for this property.")
            self.error = message
            return pendingTransactionID == nil ? .needsLink(source.id) : .rejected(message)
        }
        do {
            try checkAssignmentRevision()
            var updated = ledger
            if destination == .household, updated.householdLink == nil {
                let link = PropertyHouseholdAdapter.link
                updated.householdLink = link
                updated.properties.append(PropertyRecord(id: link.propertyID, name: PropertyDestination.householdName))
                updated.residents.append(PropertyResident(id: link.userID, propertyID: link.propertyID,
                    name: String(localized: "You"), activeFrom: .distantPast))
                updated.residents.append(PropertyResident(id: link.partnerID, propertyID: link.propertyID,
                    name: "Fer", activeFrom: .distantPast))
            }
            let includeCurrent = destination != .household
                || updated.closes.contains(where: { $0.propertyID == propertyID && $0.monthStart == selectedMonth })
                || householdMonth(selectedMonth) != nil
            let inputs = verifiedInputs.filter { $0.id != source.id } + [source]
            let existingApplications = updated.paymentApplications.filter {
                $0.paymentTransactionID == source.id && $0.deletedAt == nil
            }
            if existingApplications.contains(where: {
                PropertySettlementCalculator.hasSourceChanged(amount: $0.sourceAmountSnapshot,
                    postedAt: $0.sourcePostedAtSnapshot, currencyCode: $0.sourceCurrencySnapshot,
                    description: $0.sourceDescriptionSnapshot, versus: source)
            }) {
                return .rejected(String(localized: "This linked receipt changed. Review or remove its existing applications first."))
            }
            let placeholder = PropertyPaymentAdvance.placeholderResidentID(propertyID: propertyID)
            guard existingApplications.allSatisfy({ $0.propertyID == propertyID
                && ($0.residentID == residentID || (PropertyPaymentAdvance.isAdvance($0) && $0.residentID == placeholder)) }),
                  PropertyAssignmentService.isAvailable(source, propertyID: propertyID, ledger: updated) else {
                let message = String(localized: "This receipt is already linked to another member or property.")
                self.error = message
                return pendingTransactionID == nil ? .needsLink(source.id) : .rejected(message)
            }
            guard let proposal = PropertyCollectionPosting.plan(propertyID: propertyID, residentID: residentID,
                report: report, ledger: updated, inputs: inputs, receipt: source, asOf: max(asOf, .now),
                includeCurrent: includeCurrent) else {
                return .needsLink(source.id)
            }
            // A lost save response can be retried safely: a fully used receipt has
            // no new applications unless an existing advance now covers a due month.
            if proposal.applications.isEmpty && proposal.updatedAdvances.isEmpty {
                if ledger.pendingLinks.contains(where: {
                    $0.paymentTransactionID == source.id && $0.deletedAt == nil
                }) {
                    ledger.pendingLinks.removeAll { $0.paymentTransactionID == source.id }
                    guard save() else { return .needsLink(source.id) }
                }
                Task { await refreshPeriod(force: true) }
                return .saved
            }
            for changed in proposal.updatedAdvances {
                guard let index = updated.paymentApplications.firstIndex(where: { $0.id == changed.id }) else { continue }
                updated.paymentApplications[index] = changed
            }
            updated.paymentApplications.append(contentsOf: proposal.applications)
            // The link completed: the marker leaves in the same final write.
            updated.pendingLinks.removeAll { $0.paymentTransactionID == source.id }
            ledger = updated
            guard save() else { return .needsLink(source.id) }
            asOf = max(asOf, .now)
            Task { await refreshPeriod(force: true) }
            return .saved
        } catch {
            self.error = error.localizedDescription
            return .needsLink(source.id)
        }
    }

    /// Explicit "apply advance": spends the member's available advances against
    /// their outstanding months through the movements that already back them.
    /// No financial transaction is created, so there is no `.needsLink`
    /// recovery path: the outcome is either saved or rejected.
    func applyMemberAdvance(propertyID: UUID, residentID: UUID) -> CollectionOutcome {
        guard ledgerAvailable, periodReady, let context else {
            return .rejected(String(localized: "Property report unavailable. Retry loading."))
        }
        guard member(id: residentID)?.propertyID == propertyID,
              propertyID == (destination == .household ? (ledger.householdLink ?? PropertyHouseholdAdapter.link).propertyID : self.propertyID)
        else { return .rejected(String(localized: "Choose a member of this property.")) }
        let report: PropertyMonthlyReport?
        if destination == .household { report = householdMonthlyReport }
        else { report = reports[propertyID] }
        guard let report else { return .rejected(String(localized: "Property report unavailable. Retry loading.")) }
        let verifiedInputs: [PropertyTransactionInput]
        do {
            verifiedInputs = try inputsWithFreshAdvanceSources(propertyID: propertyID,
                                                               residentID: residentID, context: context)
        } catch { return .rejected(error.localizedDescription) }
        if PropertyCollectionPosting.hasChangedAdvanceSource(propertyID: propertyID, residentID: residentID,
                                                            ledger: ledger, inputs: verifiedInputs) {
            return .rejected(String(localized: "A previous advance changed. Review its receipt and applications before applying it."))
        }
        do {
            try checkAssignmentRevision()
            var updated = ledger
            if destination == .household, updated.householdLink == nil {
                let link = PropertyHouseholdAdapter.link
                updated.householdLink = link
                updated.properties.append(PropertyRecord(id: link.propertyID, name: PropertyDestination.householdName))
                updated.residents.append(PropertyResident(id: link.userID, propertyID: link.propertyID,
                    name: String(localized: "You"), activeFrom: .distantPast))
                updated.residents.append(PropertyResident(id: link.partnerID, propertyID: link.propertyID,
                    name: "Fer", activeFrom: .distantPast))
            }
            let includeCurrent = destination != .household
                || updated.closes.contains(where: { $0.propertyID == propertyID && $0.monthStart == selectedMonth })
                || householdMonth(selectedMonth) != nil
            guard let proposal = PropertyCollectionPosting.applyAdvances(propertyID: propertyID,
                residentID: residentID, report: report, ledger: updated, inputs: verifiedInputs,
                asOf: max(asOf, .now), includeCurrent: includeCurrent) else {
                // nil can come from any guard inside the walk, not only a stale
                // advance source, so the fallback stays generic and honest.
                return .rejected(String(localized: "The advance could not be applied. Try again."))
            }
            // Nothing to change: either no advance is pending or no due debt is
            // left for it to cover; an apply must save visibly or fail visibly.
            if proposal.applications.isEmpty && proposal.updatedAdvances.isEmpty {
                return .rejected(String(localized: "No pending balance is available for this advance."))
            }
            for changed in proposal.updatedAdvances {
                guard let index = updated.paymentApplications.firstIndex(where: { $0.id == changed.id }) else { continue }
                updated.paymentApplications[index] = changed
            }
            updated.paymentApplications.append(contentsOf: proposal.applications)
            ledger = updated
            guard save() else {
                return .rejected(self.error ?? String(localized: "The advance could not be applied. Try again."))
            }
            asOf = max(asOf, .now)
            Task { await refreshPeriod(force: true) }
            return .saved
        } catch {
            self.error = error.localizedDescription
            return .rejected(error.localizedDescription)
        }
    }

    @discardableResult
    func removeCollectionApplication(id: UUID) -> Bool {
        guard ledgerAvailable, let index = ledger.paymentApplications.firstIndex(where: { $0.id == id && $0.deletedAt == nil }) else { return false }
        do { try checkAssignmentRevision() }
        catch { self.error = error.localizedDescription; return false }
        ledger.paymentApplications[index].deletedAt = .now
        ledger.paymentApplications[index].updatedAt = PersistedMutationClock.next(after: ledger.paymentApplications[index].updatedAt)
        return save()
    }

    @discardableResult
    func save() -> Bool {
        guard ledgerAvailable else {
            ledger = savedLedger
            reconcileDestination()
            recompute()
            error = String(localized: "Changes were not saved because the property register could not be read. Retry loading.")
            return false
        }
        isSaving = true
        defer { isSaving = false }
        do {
            try writeLedger(ledger, fileURL)
            savedLedger = ledger
            error = nil
            reconcileDestination()
            recompute()
            return true
        } catch {
            ledger = savedLedger
            reconcileDestination()
            recompute()
            self.error = error.localizedDescription
            return false
        }
    }

    func activityRows(filter: PropertyActivityFilter) -> [PropertyActivityRow] {
        guard periodReady else { return [] }
        let report: PropertyMonthlyReport?
        if destination == .household { report = householdMonthlyReport }
        else { report = propertyID.flatMap { reports[$0] } }
        guard let report else { return [] }
        let assignments = destination == .household
            ? Dictionary(periodTransactions.map { ($0.id, $0.resolvedHouseholdAllocation) }, uniquingKeysWith: { first, _ in first }) : nil
        // Fer rows whose due date falls in a future month are visible here but
        // belong to that month's charges: no account scope can claim them.
        let deferredHouseholdIDs = destination == .household
            ? Set(householdReport?.deferredFerRows.map(\.id) ?? []) : []
        return PropertyActivityPresenter.rows(propertyID: report.propertyID, month: selectedMonth, asOf: asOf,
            filter: filter, ledger: ledger, report: report, inputs: transactionInputs, household: assignments,
            deferredHouseholdIDs: deferredHouseholdIDs)
    }

    @discardableResult
    func linkAttribution(_ proposal: PropertyTransactionAttribution) -> Bool {
        guard ledgerAvailable, periodReady, propertyID == proposal.propertyID, let context,
              let source = transactionInputs.first(where: { $0.id == proposal.transactionID }) else { return false }
        do {
            try checkAssignmentRevision()
            try PropertyAssignmentService.validateRentalSources(ids: [source.id], inputs: transactionInputs, container: context.container)
            var updated = ledger
            try PropertyAssignmentService.upsert(proposal, source: source, ledger: &updated)
            ledger = updated
            return save()
        } catch { self.error = error.localizedDescription; return false }
    }

    func householdAllocation(for id: UUID) -> HouseholdExpenseAllocation? {
        periodTransactions.first { $0.id == id }?.resolvedHouseholdAllocation
    }

    private func checkAssignmentRevision() throws {
        if let revisionCheckOverride { try revisionCheckOverride(); return }
        var disk = try PropertyLedgerStore.read(fileURL: fileURL)
        var expected = savedLedger
        disk.updatedAt = .distantPast; expected.updatedAt = .distantPast
        disk.schemaVersion = 2; expected.schemaVersion = 2
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard try encoder.encode(disk) == encoder.encode(expected) else {
            throw PropertyAssignmentService.AssignmentError.invalid("The property register changed. Reload before assigning transactions.")
        }
    }

    @discardableResult
    func assign(ids: Set<UUID>, choice: PropertyAssignmentChoice, group: Set<UUID> = [], customAmount: Decimal? = nil) -> Bool {
        guard periodReady, ledgerAvailable, let context else { return false }
        do {
            try checkAssignmentRevision()
            let eligibleIDs = Set(activityRows(filter: .linked).filter(\.canAssign).map(\.id)
                + activityRows(filter: .unassigned).filter(\.canAssign).map(\.id))
            guard !ids.isEmpty, ids.isSubset(of: eligibleIDs) else {
                throw PropertyAssignmentService.AssignmentError.invalid("Choose eligible expenses to assign.")
            }
            if destination == .household {
                let roles = ledger.householdLink ?? PropertyHouseholdAdapter.link
                let active = householdActiveMemberIDs
                let allocation: HouseholdExpenseAllocation
                switch choice {
                case .owner:
                    guard active.contains(roles.userID) else { return false }
                    allocation = .user
                case .shared:
                    guard !active.isEmpty else { return false }
                    allocation = .shared
                case .partner:
                    guard active.contains(roles.partnerID) else { return false }
                    allocation = .partner
                case .custom:
                    guard let customAmount, active.contains(roles.userID), active.contains(roles.partnerID) else { return false }
                    allocation = .custom(ferAmount: customAmount)
                case .member, .group: return false
                }
                let expected = cachedHouseholdAssignments
                guard periodTransactions.filter({ ids.contains($0.id) }).allSatisfy({ expected[$0.id] == HouseholdAssignmentSnapshot($0) }) else {
                    throw PropertyAssignmentService.AssignmentError.invalid("The transactions changed. Reload the period and try again.")
                }
                let edited = try PropertyAssignmentService.assignHousehold(allocation, ids: ids, expected: expected,
                    inputs: transactionInputs, ledger: ledger, container: context.container,
                    editingContext: context, registered: periodTransactions)
                for tx in edited.transactions { cachedHouseholdAssignments[tx.id] = HouseholdAssignmentSnapshot(tx) }
                for index in transactionInputs.indices where ids.contains(transactionInputs[index].id) {
                    transactionInputs[index].isHouseholdAssigned = true
                }
                for id in edited.clearedDueDates { householdDueDates[id] = nil }
                let end = Calendar.current.date(byAdding: .month, value: 1, to: selectedMonth) ?? selectedMonth
                householdTransactions = periodTransactions.filter { tx in
                    let effective = householdDueDates[tx.id] ?? tx.postedAt
                    return tx.deletedAt == nil && tx.postedAt <= asOf
                        && ((tx.postedAt >= selectedMonth && tx.postedAt < end) || (effective >= selectedMonth && effective < end))
                }
                inputRevision &+= 1; error = nil; recompute()
                return true
            } else {
                guard let propertyID else { return false }
                let responsibility: PropertyResponsibility
                switch choice {
                case .owner: responsibility = .owner
                case .shared: responsibility = .shared
                case .member(let id): responsibility = .individual(residentID: id)
                case .group: responsibility = .selected(residentIDs: group.sorted { $0.uuidString < $1.uuidString })
                case .partner, .custom: return false
                }
                try PropertyAssignmentService.validateRentalSources(ids: ids, inputs: transactionInputs, container: context.container)
                ledger = try PropertyAssignmentService.assigning(responsibility, to: ids, propertyID: propertyID,
                    ledger: ledger, inputs: transactionInputs)
                return save()
            }
        } catch { self.error = error.localizedDescription; return false }
    }

    private var requiredSourceIDs: Set<UUID> {
        Set(ledger.attributions.map(\.transactionID) + ledger.paymentApplications.map(\.paymentTransactionID)
            + ledger.closes.flatMap { $0.obligations.compactMap(\.transactionID) })
    }
}

/// A failed setup save cannot leave rejected edits in the shared context for autosave.
@MainActor
enum HouseholdWorkspacePersistence {
    static func read(month: Date, container: ModelContainer) throws -> HouseholdSettlementSetup {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let month = HouseholdMonth.monthStart(for: month)
        var descriptor = FetchDescriptor<HouseholdPartnerIncomeEstimate>(
            predicate: #Predicate { $0.monthStart == month }, sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 1
        return HouseholdSettlementSetup(try context.fetch(descriptor).first)
    }

    static func save(_ setup: HouseholdSettlementSetup, month: Date, container: ModelContainer,
                     commit: (ModelContext) throws -> Void = { try $0.save() }) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        do {
            _ = try HouseholdPartnerIncomeService.upsert(month: month, amount: setup.partnerIncomeEstimate,
                notes: setup.notes, useUserIncomeManualOverride: setup.useUserIncomeManualOverride,
                userIncomeManualOverride: setup.userIncomeManualOverride, splitMethod: setup.splitMethod,
                customUserPercent: setup.customUserPercent, customPartnerPercent: setup.customPartnerPercent,
                context: context, commit: commit)
        } catch {
            context.rollback()
            throw error
        }
    }
}
