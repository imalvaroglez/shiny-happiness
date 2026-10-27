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
    @ObservationIgnored private var interactionStart: ContinuousClock.Instant?
    @ObservationIgnored private var interactionName = ""
    @ObservationIgnored private var interactionInterval: OSSignpostIntervalState?
    private static let signposter = OSSignposter(subsystem: "com.financeTracker.app", category: "PropertyWorkspace")
    private static let performanceLogger = Logger(subsystem: "com.financeTracker.app", category: "PropertyWorkspace")

    init(month: Date = .now, asOf: Date = .now, fileURL: URL? = nil,
         readLedger: @escaping @Sendable (URL?) async throws -> PropertyLedger = { url in
             try await Task.detached { try PropertyLedgerStore.read(fileURL: url) }.value
         }, fetchTransactions: @escaping (ModelContext, FetchDescriptor<Transaction>) throws -> [Transaction] = { try $0.fetch($1) },
         writeLedger: @escaping (PropertyLedger, URL?) throws -> Void = { try PropertyLedgerStore.replace(with: $0, at: $1) }) {
        self.asOf = asOf
        selectedMonth = Calendar.current.propertyMonthStart(for: month)
        self.fileURL = fileURL
        self.readLedger = readLedger
        self.writeLedger = writeLedger
        self.fetchTransactions = fetchTransactions
    }

    var periodReady: Bool { cachedMonth == selectedMonth }
    var householdReport: HouseholdSettlementReport? { periodReady ? storedHouseholdReport : nil }
    var reports: [UUID: PropertyMonthlyReport] { periodReady ? storedReports : [:] }

    var householdMonthlyReport: PropertyMonthlyReport? {
        guard let source = householdReport else { return nil }
        return PropertyHouseholdAdapter.report(source, ledger: ledger, transactions: transactionInputs, asOf: asOf)
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

    /// Transaction-first commit: a failed sidecar write leaves an identifiable real receipt.
    /// Retrying with its UUID never inserts another financial movement.
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
        if PropertyCollectionPosting.hasChangedAdvanceSource(propertyID: propertyID, residentID: residentID,
                                                            ledger: ledger, inputs: verifiedInputs) {
            return .rejected(String(localized: "A previous advance changed. Review its receipt and applications before registering another collection."))
        }
        let transaction: Transaction
        if let pendingTransactionID {
            do {
                let descriptor = FetchDescriptor<Transaction>(predicate: #Predicate<Transaction> { $0.id == pendingTransactionID })
                guard let existing = try context.fetch(descriptor).first else {
                    return .rejected(String(localized: "The registered receipt could not be found."))
                }
                transaction = existing
            } catch { return .rejected(error.localizedDescription) }
        } else {
            guard let account, Self.eligibleCollectionAccount(account, on: date) else {
                return .rejected(String(localized: "Choose an active MXN account."))
            }
            do {
                try checkAssignmentRevision()
                let name = member(id: residentID)?.name ?? String(localized: "Member")
                let houseName = ledger.properties.first { $0.id == propertyID }?.name ?? PropertyDestination.householdName
                transaction = try ManualTransactionService.create(account: account, date: date,
                    description: String(format: String(localized: "Payment from %@ · %@"), name, houseName),
                    signedAmount: amount, category: nil, flowKindRaw: TransactionFlowKind.income.rawValue,
                    treatmentKindRaw: TransactionTreatmentKind.regular.rawValue,
                    context: context)
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
                Task { await refreshPeriod(force: true) }
                return .saved
            }
            for changed in proposal.updatedAdvances {
                guard let index = updated.paymentApplications.firstIndex(where: { $0.id == changed.id }) else { continue }
                updated.paymentApplications[index] = changed
            }
            updated.paymentApplications.append(contentsOf: proposal.applications)
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
        return PropertyActivityPresenter.rows(propertyID: report.propertyID, month: selectedMonth, asOf: asOf,
            filter: filter, ledger: ledger, report: report, inputs: transactionInputs, household: assignments)
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
