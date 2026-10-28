import Foundation
import CryptoKit

enum PropertyExpenseKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case operation
    case maintenance
    case other
    case reimbursement

    var id: String { rawValue }
}

enum PropertyResponsibility: Codable, Equatable, Sendable {
    case shared
    case individual(residentID: UUID)
    case selected(residentIDs: [UUID])
    case owner
}

enum PropertyCaptureResponsibility: String, CaseIterable, Identifiable {
    case shared
    case individual
    case selected
    case owner
    var id: String { rawValue }
}

enum PropertyServiceFrequency: String, Codable, CaseIterable, Identifiable, Sendable {
    case monthly
    case bimonthly
    case annual
    case irregular

    var id: String { rawValue }
}

struct PropertyRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var notes: String
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(id: UUID = UUID(), name: String, notes: String = "", createdAt: Date = .now,
         updatedAt: Date = .now, deletedAt: Date? = nil) {
        self.id = id; self.name = name; self.notes = notes
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.deletedAt = deletedAt
    }
}

struct PropertyResident: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var propertyID: UUID
    var name: String
    var activeFrom: Date
    var activeThrough: Date?
    var referenceMonthlyIncome: Decimal
    var notes: String
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(id: UUID = UUID(), propertyID: UUID, name: String, activeFrom: Date,
         activeThrough: Date? = nil, referenceMonthlyIncome: Decimal = 0, notes: String = "",
         createdAt: Date = .now, updatedAt: Date = .now, deletedAt: Date? = nil) {
        self.id = id; self.propertyID = propertyID; self.name = name
        self.activeFrom = activeFrom; self.activeThrough = activeThrough
        self.referenceMonthlyIncome = referenceMonthlyIncome; self.notes = notes
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.deletedAt = deletedAt
    }
}

struct PropertyIncome: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var propertyID: UUID
    var residentID: UUID
    var monthStart: Date
    var amount: Decimal
    var confirmedAt: Date?
    var updatedAt: Date
    var deletedAt: Date?

    init(id: UUID = UUID(), propertyID: UUID, residentID: UUID, monthStart: Date,
         amount: Decimal, confirmedAt: Date? = nil, updatedAt: Date = .now, deletedAt: Date? = nil) {
        self.id = id; self.propertyID = propertyID; self.residentID = residentID
        self.monthStart = Calendar.current.propertyMonthStart(for: monthStart)
        self.amount = amount; self.confirmedAt = confirmedAt; self.updatedAt = updatedAt; self.deletedAt = deletedAt
    }
}

struct PropertyRentAgreement: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var propertyID: UUID
    var monthlyAmount: Decimal
    var effectiveMonth: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(id: UUID = UUID(), propertyID: UUID, monthlyAmount: Decimal, effectiveMonth: Date,
         updatedAt: Date = .now, deletedAt: Date? = nil) {
        self.id = id; self.propertyID = propertyID; self.monthlyAmount = monthlyAmount
        self.effectiveMonth = Calendar.current.propertyMonthStart(for: effectiveMonth); self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

struct PropertyServiceBudget: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var propertyID: UUID
    var name: String
    var frequency: PropertyServiceFrequency
    var monthlyReference: Decimal
    var updatedAt: Date
    var deletedAt: Date?

    init(id: UUID = UUID(), propertyID: UUID, name: String, frequency: PropertyServiceFrequency,
         monthlyReference: Decimal, updatedAt: Date = .now, deletedAt: Date? = nil) {
        self.id = id; self.propertyID = propertyID; self.name = name
        self.frequency = frequency; self.monthlyReference = monthlyReference; self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

struct PropertyTransactionAttribution: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var propertyID: UUID
    var transactionID: UUID
    var kind: PropertyExpenseKind
    var responsibility: PropertyResponsibility
    var coverageStart: Date?
    var coverageEnd: Date?
    var maintenanceProgramID: UUID?
    var sourceAmountSnapshot: Decimal?
    var sourcePostedAtSnapshot: Date?
    var sourceCurrencySnapshot: String?
    var sourceDescriptionSnapshot: String?
    var notes: String
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(id: UUID = UUID(), propertyID: UUID, transactionID: UUID, kind: PropertyExpenseKind,
         responsibility: PropertyResponsibility, coverageStart: Date? = nil, coverageEnd: Date? = nil,
         maintenanceProgramID: UUID? = nil, sourceAmountSnapshot: Decimal? = nil,
         sourcePostedAtSnapshot: Date? = nil, sourceCurrencySnapshot: String? = nil,
         sourceDescriptionSnapshot: String? = nil, notes: String = "", createdAt: Date = .now,
         updatedAt: Date = .now, deletedAt: Date? = nil) {
        self.id = id; self.propertyID = propertyID; self.transactionID = transactionID
        self.kind = kind; self.responsibility = responsibility
        self.coverageStart = coverageStart; self.coverageEnd = coverageEnd
        self.maintenanceProgramID = maintenanceProgramID; self.notes = notes
        self.sourceAmountSnapshot = sourceAmountSnapshot; self.sourcePostedAtSnapshot = sourcePostedAtSnapshot
        self.sourceCurrencySnapshot = sourceCurrencySnapshot; self.sourceDescriptionSnapshot = sourceDescriptionSnapshot
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.deletedAt = deletedAt
    }
}

struct PropertyPaymentApplication: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var propertyID: UUID
    var paymentTransactionID: UUID
    var obligationID: UUID
    var residentID: UUID
    var amount: Decimal
    var sourceAmountSnapshot: Decimal?
    var sourcePostedAtSnapshot: Date?
    var sourceCurrencySnapshot: String?
    var sourceDescriptionSnapshot: String?
    var updatedAt: Date
    var deletedAt: Date?

    init(id: UUID = UUID(), propertyID: UUID, paymentTransactionID: UUID,
         obligationID: UUID, residentID: UUID, amount: Decimal,
         sourceAmountSnapshot: Decimal? = nil, sourcePostedAtSnapshot: Date? = nil,
         sourceCurrencySnapshot: String? = nil, sourceDescriptionSnapshot: String? = nil,
         updatedAt: Date = .now, deletedAt: Date? = nil) {
        self.id = id; self.propertyID = propertyID; self.paymentTransactionID = paymentTransactionID
        self.obligationID = obligationID; self.residentID = residentID
        self.amount = amount; self.sourceAmountSnapshot = sourceAmountSnapshot
        self.sourcePostedAtSnapshot = sourcePostedAtSnapshot
        self.sourceCurrencySnapshot = sourceCurrencySnapshot
        self.sourceDescriptionSnapshot = sourceDescriptionSnapshot
        self.updatedAt = updatedAt; self.deletedAt = deletedAt
    }
}

/// The four source-captured snapshots that travel together whenever an attribution
/// or payment application is created from (or reconciled against) a live transaction.
struct PropertySourceSnapshots: Equatable, Sendable {
    var amount: Decimal?
    var postedAt: Date?
    var currencyCode: String?
    var description: String?

    init(amount: Decimal? = nil, postedAt: Date? = nil, currencyCode: String? = nil, description: String? = nil) {
        self.amount = amount
        self.postedAt = postedAt
        self.currencyCode = currencyCode
        self.description = description
    }

    init(capturing input: PropertyTransactionInput) {
        amount = input.amount
        postedAt = input.postedAt
        currencyCode = input.currencyCode
        description = input.description
    }
}

extension PropertyTransactionAttribution {
    var sourceSnapshots: PropertySourceSnapshots {
        get { PropertySourceSnapshots(amount: sourceAmountSnapshot, postedAt: sourcePostedAtSnapshot,
                                      currencyCode: sourceCurrencySnapshot, description: sourceDescriptionSnapshot) }
        set {
            sourceAmountSnapshot = newValue.amount
            sourcePostedAtSnapshot = newValue.postedAt
            sourceCurrencySnapshot = newValue.currencyCode
            sourceDescriptionSnapshot = newValue.description
        }
    }
}

extension PropertyPaymentApplication {
    var sourceSnapshots: PropertySourceSnapshots {
        get { PropertySourceSnapshots(amount: sourceAmountSnapshot, postedAt: sourcePostedAtSnapshot,
                                      currencyCode: sourceCurrencySnapshot, description: sourceDescriptionSnapshot) }
        set {
            sourceAmountSnapshot = newValue.amount
            sourcePostedAtSnapshot = newValue.postedAt
            sourceCurrencySnapshot = newValue.currencyCode
            sourceDescriptionSnapshot = newValue.description
        }
    }

    init(id: UUID = UUID(), propertyID: UUID, paymentTransactionID: UUID, obligationID: UUID,
         residentID: UUID, amount: Decimal, snapshots: PropertySourceSnapshots) {
        self.init(id: id, propertyID: propertyID, paymentTransactionID: paymentTransactionID,
                  obligationID: obligationID, residentID: residentID, amount: amount,
                  sourceAmountSnapshot: snapshots.amount, sourcePostedAtSnapshot: snapshots.postedAt,
                  sourceCurrencySnapshot: snapshots.currencyCode, sourceDescriptionSnapshot: snapshots.description)
    }
}

/// A capture in flight: the income is real but its property applications were
/// not written yet. The marker is workflow state, not financial data — it pins
/// the receipt by UUID so the link survives reloads, renames, and edits.
struct PropertyPaymentPendingLink: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var propertyID: UUID
    var residentID: UUID
    var paymentTransactionID: UUID
    var amount: Decimal
    var createdAt: Date
    var deletedAt: Date?

    init(id: UUID = UUID(), propertyID: UUID, residentID: UUID, paymentTransactionID: UUID,
         amount: Decimal, createdAt: Date = .now, deletedAt: Date? = nil) {
        self.id = id; self.propertyID = propertyID; self.residentID = residentID
        self.paymentTransactionID = paymentTransactionID; self.amount = amount
        self.createdAt = createdAt; self.deletedAt = deletedAt
    }
}

/// An unapplied receipt is stored as a payment-application row with a stable
/// synthetic obligation id. This keeps the cash transaction as the source of
/// truth while allowing the remaining amount to survive month changes.
enum PropertyPaymentAdvance {
    static func obligationID(propertyID: UUID, paymentTransactionID: UUID) -> UUID {
        UUID.deterministic(propertyID, Date(timeIntervalSince1970: 0), "advance-\(paymentTransactionID.uuidString)")
    }

    static func isAdvance(_ application: PropertyPaymentApplication) -> Bool {
        application.obligationID == obligationID(propertyID: application.propertyID,
                                                  paymentTransactionID: application.paymentTransactionID)
    }

    static func placeholderResidentID(propertyID: UUID) -> UUID {
        UUID.deterministic(propertyID, Date(timeIntervalSince1970: 0), "unassigned-advance-resident")
    }
}

struct PropertyAdjustment: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var propertyID: UUID
    var monthStart: Date
    var residentID: UUID?
    var amount: Decimal
    var reason: String
    var createdAt: Date
    var deletedAt: Date?
    var mergeUpdatedAt: Date { max(createdAt, deletedAt ?? createdAt) }

    init(id: UUID = UUID(), propertyID: UUID, monthStart: Date, residentID: UUID? = nil,
         amount: Decimal, reason: String, createdAt: Date = .now, deletedAt: Date? = nil) {
        self.id = id; self.propertyID = propertyID
        self.monthStart = Calendar.current.propertyMonthStart(for: monthStart)
        self.residentID = residentID; self.amount = amount; self.reason = reason
        self.createdAt = createdAt; self.deletedAt = deletedAt
    }
}

struct PropertyMaintenanceProgram: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var propertyID: UUID
    var startsAt: Date
    var endsAt: Date
    var budget: Decimal
    var monthlyRecoveryLimit: Decimal
    var updatedAt: Date
    var deletedAt: Date?

    init(id: UUID = UUID(), propertyID: UUID, startsAt: Date, endsAt: Date,
         budget: Decimal = 24_000, monthlyRecoveryLimit: Decimal = 2_000,
         updatedAt: Date = .now, deletedAt: Date? = nil) {
        self.id = id; self.propertyID = propertyID
        self.startsAt = Calendar.current.propertyMonthStart(for: startsAt)
        self.endsAt = Calendar.current.propertyMonthStart(for: endsAt)
        self.budget = budget; self.monthlyRecoveryLimit = monthlyRecoveryLimit
        self.updatedAt = updatedAt; self.deletedAt = deletedAt
    }
}

struct PropertyMaintenanceRecovery: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var propertyID: UUID
    var programID: UUID
    var rentMonth: Date
    var paymentTransactionID: UUID
    var amount: Decimal
    var updatedAt: Date
    var deletedAt: Date?

    init(id: UUID = UUID(), propertyID: UUID, programID: UUID, rentMonth: Date,
         paymentTransactionID: UUID, amount: Decimal, updatedAt: Date = .now,
         deletedAt: Date? = nil) {
        self.id = id; self.propertyID = propertyID; self.programID = programID
        self.rentMonth = Calendar.current.propertyMonthStart(for: rentMonth)
        self.paymentTransactionID = paymentTransactionID; self.amount = amount
        self.updatedAt = updatedAt; self.deletedAt = deletedAt
    }
}

struct PropertyReserveMovement: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var propertyID: UUID
    var amount: Decimal
    var reason: String
    var createdAt: Date
    var deletedAt: Date?
    var mergeUpdatedAt: Date { max(createdAt, deletedAt ?? createdAt) }
}

struct PropertyResidentSnapshot: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var income: Decimal
    var share: Decimal
    var obligation: Decimal
    var paid: Decimal
    var directContribution: Decimal?
}

struct PropertyObligationSnapshot: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var title: String
    var kind: PropertyExpenseKind
    var amount: Decimal
    var allocations: [UUID: Decimal]
    var transactionID: UUID?
    var sourcePostedAt: Date?
    var sourceCurrencyCode: String?
    var coverageStart: Date?
    var coverageEnd: Date?
    var responsibility: PropertyResponsibility
    var isRent: Bool

    init(id: UUID, title: String, kind: PropertyExpenseKind, amount: Decimal,
         allocations: [UUID: Decimal], transactionID: UUID?, responsibility: PropertyResponsibility,
         isRent: Bool = false, sourcePostedAt: Date? = nil, sourceCurrencyCode: String? = nil,
         coverageStart: Date? = nil, coverageEnd: Date? = nil) {
        self.id = id; self.title = title; self.kind = kind; self.amount = amount
        self.allocations = allocations; self.transactionID = transactionID; self.sourcePostedAt = sourcePostedAt
        self.sourceCurrencyCode = sourceCurrencyCode
        self.coverageStart = coverageStart; self.coverageEnd = coverageEnd
        self.responsibility = responsibility; self.isRent = isRent
    }
}

struct PropertySettlementClose: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var propertyID: UUID
    var monthStart: Date
    var closedAt: Date
    var residents: [PropertyResidentSnapshot]
    var obligations: [PropertyObligationSnapshot]
    var totalObligations: Decimal
    var warnings: [String]
}

struct PropertyLedger: Codable, Equatable, Sendable {
    var schemaVersion: Int = 2
    var updatedAt = Date.distantPast
    var properties: [PropertyRecord] = []
    var residents: [PropertyResident] = []
    var incomes: [PropertyIncome] = []
    var rents: [PropertyRentAgreement] = []
    var serviceBudgets: [PropertyServiceBudget] = []
    var attributions: [PropertyTransactionAttribution] = []
    var paymentApplications: [PropertyPaymentApplication] = []
    var pendingLinks: [PropertyPaymentPendingLink] = []
    var adjustments: [PropertyAdjustment] = []
    var maintenancePrograms: [PropertyMaintenanceProgram] = []
    var maintenanceRecoveries: [PropertyMaintenanceRecovery] = []
    var reserveMovements: [PropertyReserveMovement] = []
    var closes: [PropertySettlementClose] = []
    var householdLink: PropertyHouseholdLink?
    var householdMonths: [PropertyHouseholdMonth]?

    var activeProperties: [PropertyRecord] { properties.filter { $0.deletedAt == nil } }

    func residents(for propertyID: UUID, month: Date, calendar: Calendar = .current) -> [PropertyResident] {
        let monthStart = calendar.propertyMonthStart(for: month)
        return residents.filter {
            $0.propertyID == propertyID && $0.deletedAt == nil
                && calendar.propertyMonthStart(for: $0.activeFrom) <= monthStart
                && ($0.activeThrough == nil || calendar.propertyMonthStart(for: $0.activeThrough!) >= monthStart)
        }.sorted {
            let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
            return comparison == .orderedSame ? $0.id.uuidString < $1.id.uuidString : comparison == .orderedAscending
        }
    }

    func income(for resident: PropertyResident, month: Date, calendar: Calendar = .current) -> (amount: Decimal, confirmed: Bool) {
        let start = calendar.propertyMonthStart(for: month)
        guard let income = incomes.filter({ $0.residentID == resident.id && $0.monthStart == start && $0.deletedAt == nil })
            .max(by: {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt < $1.updatedAt }
                return $0.id.uuidString < $1.id.uuidString
            }) else {
            return (resident.referenceMonthlyIncome, false)
        }
        return (income.amount, income.confirmedAt != nil)
    }

    func rent(for propertyID: UUID, month: Date, calendar: Calendar = .current) -> Decimal {
        let start = calendar.propertyMonthStart(for: month)
        return rents.filter { $0.propertyID == propertyID && $0.deletedAt == nil && $0.effectiveMonth <= start }
            .max {
                if $0.effectiveMonth != $1.effectiveMonth { return $0.effectiveMonth < $1.effectiveMonth }
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt < $1.updatedAt }
                return $0.id.uuidString < $1.id.uuidString
            }?.monthlyAmount ?? 0
    }
}

/// Backwards-compatible decoding: synthesized Codable does NOT fall back to a
/// property's default when a key is absent, so ledgers written before a field
/// existed would throw `keyNotFound`. Decoding every field with its default
/// keeps old files readable without a schemaVersion bump.
extension PropertyLedger {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, updatedAt, properties, residents, incomes, rents, serviceBudgets
        case attributions, paymentApplications, pendingLinks, adjustments
        case maintenancePrograms, maintenanceRecoveries, reserveMovements, closes
        case householdLink, householdMonths
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 2
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
        properties = try container.decodeIfPresent([PropertyRecord].self, forKey: .properties) ?? []
        residents = try container.decodeIfPresent([PropertyResident].self, forKey: .residents) ?? []
        incomes = try container.decodeIfPresent([PropertyIncome].self, forKey: .incomes) ?? []
        rents = try container.decodeIfPresent([PropertyRentAgreement].self, forKey: .rents) ?? []
        serviceBudgets = try container.decodeIfPresent([PropertyServiceBudget].self, forKey: .serviceBudgets) ?? []
        attributions = try container.decodeIfPresent([PropertyTransactionAttribution].self, forKey: .attributions) ?? []
        paymentApplications = try container.decodeIfPresent([PropertyPaymentApplication].self, forKey: .paymentApplications) ?? []
        pendingLinks = try container.decodeIfPresent([PropertyPaymentPendingLink].self, forKey: .pendingLinks) ?? []
        adjustments = try container.decodeIfPresent([PropertyAdjustment].self, forKey: .adjustments) ?? []
        maintenancePrograms = try container.decodeIfPresent([PropertyMaintenanceProgram].self, forKey: .maintenancePrograms) ?? []
        maintenanceRecoveries = try container.decodeIfPresent([PropertyMaintenanceRecovery].self, forKey: .maintenanceRecoveries) ?? []
        reserveMovements = try container.decodeIfPresent([PropertyReserveMovement].self, forKey: .reserveMovements) ?? []
        closes = try container.decodeIfPresent([PropertySettlementClose].self, forKey: .closes) ?? []
        householdLink = try container.decodeIfPresent(PropertyHouseholdLink.self, forKey: .householdLink)
        householdMonths = try container.decodeIfPresent([PropertyHouseholdMonth].self, forKey: .householdMonths)
    }
}

/// Transient presentation metadata, never persisted in the property ledger.
struct PropertyCategoryComponent: Equatable, Sendable {
    var id: UUID
    var name: String
}

enum PropertyCategoryHierarchy: Equatable, Sendable {
    case path([PropertyCategoryComponent])
    case uncategorized
    case unavailable
}

struct PropertyTransactionInput: Equatable, Identifiable, Sendable {
    var id: UUID
    var amount: Decimal
    var postedAt: Date
    var description: String
    var currencyCode: String
    var deletedAt: Date?
    var isDuplicate: Bool
    var isTransfer: Bool
    var isCashAccount: Bool
    /// Presentation-only source fact; no Transaction or sidecar schema change.
    var hasAccount: Bool
    var isHouseholdAssigned: Bool
    var accountName: String?
    var isHouseholdEligible: Bool
    var categoryID: UUID?
    var categoryName: String?
    var categoryHierarchy: PropertyCategoryHierarchy?

    init(id: UUID, amount: Decimal, postedAt: Date, description: String, deletedAt: Date? = nil,
         isDuplicate: Bool = false, isTransfer: Bool = false, isCashAccount: Bool = false,
         hasAccount: Bool? = nil,
         isHouseholdAssigned: Bool = false, currencyCode: String = "MXN", accountName: String? = nil, isHouseholdEligible: Bool = true,
         categoryID: UUID? = nil, categoryName: String? = nil, categoryHierarchy: PropertyCategoryHierarchy? = nil) {
        self.id = id; self.amount = amount; self.postedAt = postedAt; self.description = description
        self.currencyCode = currencyCode; self.accountName = accountName; self.isHouseholdEligible = isHouseholdEligible
        self.categoryID = categoryID; self.categoryName = categoryName; self.categoryHierarchy = categoryHierarchy
        self.deletedAt = deletedAt; self.isDuplicate = isDuplicate; self.isTransfer = isTransfer
        self.isCashAccount = isCashAccount; self.hasAccount = hasAccount ?? isCashAccount
        self.isHouseholdAssigned = isHouseholdAssigned
    }
}

struct PropertyResidentReport: Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var income: Decimal
    var confirmed: Bool
    var share: Decimal
    var rent: Decimal
    var sharedExpenses: Decimal
    var individualExpenses: Decimal
    var adjustments: Decimal
    var paid: Decimal
    var priorDebt: Decimal
    var directContribution: Decimal = 0
    var balance: Decimal { rent + sharedExpenses + individualExpenses + adjustments - paid }
}

struct PropertyMonthlyReport: Equatable, Sendable {
    var propertyID: UUID
    var monthStart: Date
    var rent: Decimal
    var expenses: Decimal
    var collected: Decimal
    var cashCollected: Decimal = 0
    var advanceAvailable: Decimal = 0
    var reimbursementsReceived: Decimal = 0
    var priorBalance: Decimal
    var residents: [PropertyResidentReport]
    var obligations: [PropertyObligationSnapshot]
    var warnings: [String]
    var canClose: Bool { warnings.isEmpty }
    var operatingExpenses: Decimal {
        obligations.filter { $0.transactionID != nil && $0.kind != .maintenance && $0.kind != .reimbursement }
            .reduce(Decimal.zero) { $0 + $1.amount }
    }
    var maintenanceExpenses: Decimal {
        obligations.filter { $0.transactionID != nil && $0.kind == .maintenance }
            .reduce(Decimal.zero) { $0 + $1.amount }
    }
    var operatingResult: Decimal { cashCollected + reimbursementsReceived - operatingExpenses }
    var afterMaintenanceResult: Decimal { operatingResult - maintenanceExpenses }
}

enum PropertySettlementCalculator {
    /// A reconciliation payment counts only when its backing transaction is still a
    /// live, MXN, non-transfer inflow with a real account as of `asOf`.
    static func isValidCollectionPayment(_ input: PropertyTransactionInput?, asOf: Date) -> Bool {
        guard let input else { return false }
        return input.deletedAt == nil
            && input.postedAt <= asOf
            && input.isDuplicate == false
            && input.isTransfer == false
            && input.hasAccount
            && !input.isHouseholdAssigned
            && input.currencyCode == "MXN"
            && input.amount > 0
    }

    /// True when any captured source snapshot no longer matches the live transaction.
    /// `postedAt` compares at whole-second precision — the precision the sidecar
    /// preserves on disk — so a snapshot that only lost sub-second detail in a
    /// disk round trip never counts as a change, and a real edit confined to the
    /// same second is not reported by design.
    /// Snapshots the caller does not capture stay `nil` and never count as changed.
    static func hasSourceChanged(amount: Decimal?, postedAt: Date?, currencyCode: String?, description: String?,
                                 versus input: PropertyTransactionInput) -> Bool {
        (amount != nil && amount != input.amount)
            || (postedAt != nil && !isSameWholeSecond(postedAt!, input.postedAt))
            || (currencyCode != nil && currencyCode != input.currencyCode)
            || (description != nil && description != input.description)
    }

    /// Whole-second equality: both instants floor to the same second. The sidecar
    /// encodes dates as ISO8601 without fractional seconds, so whole seconds are
    /// the finest precision a snapshot survives on disk.
    static func isSameWholeSecond(_ a: Date, _ b: Date) -> Bool {
        a.timeIntervalSince1970.rounded(.down) == b.timeIntervalSince1970.rounded(.down)
    }

    /// Shared reconciliation review: receipts used both as reimbursement and collection,
    /// and collections applied beyond their payment amount. `warnings` carries the same
    /// messages report() and frozenReport() surface (frozenReport de-duplicates later).
    static func reconciliationReview(propertyID: UUID, obligations: [PropertyObligationSnapshot],
                                     applications: [PropertyPaymentApplication],
                                     inputs: [UUID: PropertyTransactionInput])
        -> (doubleUsedReceipts: Set<UUID>, overallocatedPaymentIDs: Set<UUID>, warnings: [String]) {
        let reimbursementTransactionIDs = Set(obligations.compactMap {
            $0.kind == .reimbursement ? $0.transactionID : nil
        })
        let doubleUsedReceipts = Set(applications.map(\.paymentTransactionID))
            .intersection(reimbursementTransactionIDs)
        var warnings: [String] = []
        for transactionID in doubleUsedReceipts {
            warnings.append("El movimiento \(transactionID.uuidString.prefix(8)) está conciliado como reembolso y cobro; elige un solo uso.")
        }
        let applicationsByPayment = Dictionary(grouping: applications, by: \.paymentTransactionID)
        let overallocatedPaymentIDs = Set(applicationsByPayment.compactMap { paymentID, applications -> UUID? in
            guard let payment = inputs[paymentID], payment.amount > 0, payment.currencyCode == "MXN" else { return nil }
            return applications.reduce(Decimal.zero) { $0 + $1.amount } > payment.amount ? paymentID : nil
        })
        for paymentID in overallocatedPaymentIDs {
            warnings.append("Las aplicaciones del cobro \(paymentID.uuidString.prefix(8)) superan su importe; revisa la conciliación.")
        }
        return (doubleUsedReceipts, overallocatedPaymentIDs, warnings)
    }

    static func report(propertyID: UUID, month: Date, ledger: PropertyLedger,
                       transactions: [PropertyTransactionInput], calendar: Calendar = .current, asOf: Date = .distantFuture) -> PropertyMonthlyReport {
        let monthStart = calendar.propertyMonthStart(for: month)
        let residents = ledger.residents(for: propertyID, month: monthStart, calendar: calendar)
        let incomes = residents.map { ledger.income(for: $0, month: monthStart, calendar: calendar) }
        let totalIncome = incomes.reduce(Decimal.zero) { $0 + $1.amount }
        var warnings: [String] = []
        for (index, resident) in residents.enumerated() where !incomes[index].confirmed {
            warnings.append("Confirma el ingreso de \(resident.name) para cerrar el mes.")
        }

        var inputsByID: [UUID: PropertyTransactionInput] = [:]
        for input in transactions { inputsByID[input.id] = input }
        var obligations: [PropertyObligationSnapshot] = []
        let rent = ledger.rent(for: propertyID, month: monthStart, calendar: calendar)
        if rent > 0 {
            let allocations = allocate(rent, residentIDs: residents.map(\.id), incomes: incomes.map(\.amount))
            if allocations == nil { warnings.append("La renta queda pendiente: no hay ingresos positivos para calcular proporciones.") }
            obligations.append(PropertyObligationSnapshot(id: UUID.deterministic(propertyID, monthStart, "rent"),
                title: "Renta", kind: .operation, amount: rent, allocations: allocations ?? [:],
                transactionID: nil, responsibility: .shared, isRent: true))
        }

        for attribution in ledger.attributions where attribution.propertyID == propertyID && attribution.deletedAt == nil {
            let input = inputsByID[attribution.transactionID]
            let snapshotDate = attribution.sourcePostedAtSnapshot ?? input?.postedAt ?? attribution.createdAt
            let snapshotMonth = calendar.propertyMonthStart(for: snapshotDate)
            let currentMonth = input.map { calendar.propertyMonthStart(for: $0.postedAt) }
            guard snapshotMonth == monthStart || currentMonth == monthStart else { continue }
            guard let input else {
                warnings.append("Un movimiento atribuido a esta propiedad ya no está disponible; revisa el periodo antes de cerrarlo.")
                continue
            }
            let sourceChanged = hasSourceChanged(amount: attribution.sourceAmountSnapshot,
                postedAt: attribution.sourcePostedAtSnapshot, currencyCode: attribution.sourceCurrencySnapshot,
                description: attribution.sourceDescriptionSnapshot, versus: input)
            if sourceChanged {
                warnings.append("El movimiento «\(input.description)» cambió desde que se atribuyó; revisa la nueva liquidación.")
            }
            guard currentMonth == monthStart, input.postedAt <= asOf else { continue }
            guard !input.isHouseholdAssigned else {
                warnings.append("El movimiento «\(input.description)» también está asignado al hogar; elige un solo destino.")
                continue
            }
            guard input.deletedAt == nil, !input.isDuplicate, !input.isTransfer else {
                warnings.append("El movimiento atribuido «\(input.description)» se eliminó, duplicó o convirtió en transferencia; revisa la liquidación.")
                continue
            }
            guard input.currencyCode == "MXN" else {
                warnings.append("El movimiento «\(input.description)» está en \(input.currencyCode); la liquidación requiere importes en MXN.")
                continue
            }
            if input.amount > 0 {
                if attribution.kind == .reimbursement {
                    obligations.append(PropertyObligationSnapshot(id: attribution.id, title: input.description,
                        kind: .reimbursement, amount: input.amount, allocations: [:], transactionID: input.id,
                        responsibility: .owner, sourcePostedAt: input.postedAt, sourceCurrencyCode: input.currencyCode,
                        coverageStart: attribution.coverageStart, coverageEnd: attribution.coverageEnd))
                } else if attribution.sourceAmountSnapshot.map({ $0 < 0 }) == true {
                    warnings.append("El movimiento atribuido «\(input.description)» ya no es un gasto; revisa su destino.")
                }
                continue
            }
            guard input.amount < 0, attribution.kind != .reimbursement else {
                if attribution.sourceAmountSnapshot.map({ $0 < 0 }) == true {
                    warnings.append("El movimiento atribuido «\(input.description)» ya no es un gasto; revisa su destino.")
                } else if attribution.kind == .reimbursement {
                    warnings.append("El reembolso «\(input.description)» dejó de ser un ingreso; revisa su atribución.")
                }
                continue
            }
            let amount = abs(input.amount)
            let allocations: [UUID: Decimal]?
            switch attribution.responsibility {
            case .owner: allocations = [:]
            case .individual(let residentID):
                allocations = residents.contains(where: { $0.id == residentID }) ? [residentID: amount] : nil
                if allocations == nil { warnings.append(String(format: String(localized: "Assignment needs review: %@. A member no longer participates in this period."), input.description)) }
            case .selected(let residentIDs):
                let selected = residents.filter { residentIDs.contains($0.id) }
                if selected.count != Set(residentIDs).count {
                    warnings.append(String(format: String(localized: "Assignment needs review: %@. A member no longer participates in this period."), input.description))
                    allocations = nil
                    break
                }
                allocations = allocate(amount, residentIDs: selected.map(\.id),
                    incomes: selected.compactMap { resident in residents.firstIndex(where: { $0.id == resident.id }).map { incomes[$0].amount } })
            case .shared:
                allocations = allocate(amount, residentIDs: residents.map(\.id), incomes: incomes.map(\.amount))
            }
            if allocations == nil { warnings.append("Falta una distribución válida para \(input.description).") }
            obligations.append(PropertyObligationSnapshot(id: attribution.id, title: input.description,
                kind: attribution.kind, amount: amount, allocations: allocations ?? [:],
                transactionID: input.id, responsibility: attribution.responsibility, sourcePostedAt: input.postedAt,
                sourceCurrencyCode: input.currencyCode,
                coverageStart: attribution.coverageStart, coverageEnd: attribution.coverageEnd))
        }

        for adjustment in ledger.adjustments where adjustment.propertyID == propertyID
            && adjustment.deletedAt == nil && adjustment.monthStart == monthStart {
            let alloc: [UUID: Decimal]
            let responsibility: PropertyResponsibility
            if let residentID = adjustment.residentID {
                alloc = [residentID: adjustment.amount]
                responsibility = .individual(residentID: residentID)
            } else {
                let positiveAllocations = allocate(abs(adjustment.amount), residentIDs: residents.map(\.id), incomes: incomes.map(\.amount)) ?? [:]
                alloc = positiveAllocations.mapValues { adjustment.amount < 0 ? -$0 : $0 }
                responsibility = .shared
            }
            obligations.append(PropertyObligationSnapshot(id: adjustment.id, title: adjustment.reason,
                kind: .other, amount: adjustment.amount, allocations: alloc, transactionID: nil,
                responsibility: responsibility))
        }

        let obligationIDs = Set(obligations.map(\.id))
        let propertyApplications = ledger.paymentApplications.filter {
            $0.propertyID == propertyID && $0.deletedAt == nil
        }
        let reconciliation = reconciliationReview(propertyID: propertyID, obligations: obligations,
                                                  applications: propertyApplications, inputs: inputsByID)
        warnings.append(contentsOf: reconciliation.warnings)
        let doubleUsedReceipts = reconciliation.doubleUsedReceipts
        let overallocatedPaymentIDs = reconciliation.overallocatedPaymentIDs
        let closedObligationIDs = Set(ledger.closes.filter { $0.propertyID == propertyID }
            .flatMap { $0.obligations.map(\.id) })
        for application in propertyApplications where PropertyPaymentAdvance.isAdvance(application)
            || obligationIDs.contains(application.obligationID) || closedObligationIDs.contains(application.obligationID) {
            guard let payment = inputsByID[application.paymentTransactionID],
                  isValidCollectionPayment(payment, asOf: .distantFuture) else {
                warnings.append("Un cobro vinculado a este periodo cambió, se eliminó o no está en MXN; revisa la conciliación.")
                continue
            }
            if hasSourceChanged(amount: application.sourceAmountSnapshot, postedAt: application.sourcePostedAtSnapshot,
                                currencyCode: application.sourceCurrencySnapshot, description: application.sourceDescriptionSnapshot,
                                versus: payment) {
                warnings.append("El movimiento de cobro «\(payment.description)» cambió desde que se concilió.")
            }
        }
        let applications = ledger.paymentApplications.filter {
            $0.propertyID == propertyID && $0.deletedAt == nil
                && !PropertyPaymentAdvance.isAdvance($0)
                && obligationIDs.contains($0.obligationID)
                && !overallocatedPaymentIDs.contains($0.paymentTransactionID)
                && !doubleUsedReceipts.contains($0.paymentTransactionID)
                && isValidCollectionPayment(inputsByID[$0.paymentTransactionID], asOf: asOf)
        }
        let cashCollected = ledger.paymentApplications.filter { application in
            guard application.propertyID == propertyID, application.deletedAt == nil,
                  let payment = inputsByID[application.paymentTransactionID],
                  isValidCollectionPayment(payment, asOf: asOf),
                  !overallocatedPaymentIDs.contains(application.paymentTransactionID),
                  !doubleUsedReceipts.contains(application.paymentTransactionID) else { return false }
            return calendar.isDate(payment.postedAt, equalTo: monthStart, toGranularity: .month)
        }.reduce(Decimal.zero) { $0 + $1.amount }
        let paidByResident = Dictionary(grouping: applications, by: \.residentID).mapValues {
            $0.reduce(Decimal.zero) { $0 + $1.amount }
        }
        let priorDebts = priorBalances(propertyID: propertyID, before: monthStart, ledger: ledger,
                                       transactions: inputsByID, asOf: asOf)
        let advanceAvailable = propertyApplications.filter {
            PropertyPaymentAdvance.isAdvance($0) && !overallocatedPaymentIDs.contains($0.paymentTransactionID)
                && !doubleUsedReceipts.contains($0.paymentTransactionID)
                && isValidCollectionPayment(inputsByID[$0.paymentTransactionID], asOf: asOf)
        }.reduce(Decimal.zero) { $0 + $1.amount }
        let residentRows = residents.enumerated().map { index, resident in
            let share = totalIncome > 0 ? incomes[index].amount / totalIncome : 0
            var rentShare: Decimal = 0
            var shared: Decimal = 0
            var individual: Decimal = 0
            var adjustment: Decimal = 0
            for obligation in obligations {
                let amount = obligation.allocations[resident.id] ?? 0
                if obligation.isRent {
                    rentShare += amount
                } else if obligation.transactionID == nil {
                    adjustment += amount
                } else {
                    switch obligation.responsibility {
                    case .individual(let assignedID) where assignedID == resident.id: individual += amount
                    case .shared, .selected: shared += amount
                    case .individual, .owner: break
                    }
                }
            }
            return PropertyResidentReport(id: resident.id, name: resident.name, income: incomes[index].amount,
                confirmed: incomes[index].confirmed, share: share, rent: rentShare, sharedExpenses: shared,
                individualExpenses: individual, adjustments: adjustment, paid: paidByResident[resident.id] ?? 0,
                priorDebt: priorDebts[resident.id] ?? 0)
        }
        return PropertyMonthlyReport(propertyID: propertyID, monthStart: monthStart, rent: rent,
            expenses: obligations.filter { $0.transactionID != nil && $0.kind != .reimbursement }
                .reduce(0) { $0 + $1.amount },
            collected: applications.reduce(0) { $0 + $1.amount }, cashCollected: cashCollected,
            advanceAvailable: advanceAvailable,
            reimbursementsReceived: obligations.filter { $0.transactionID != nil && $0.kind == .reimbursement }
                .reduce(Decimal.zero) { $0 + $1.amount },
            priorBalance: priorDebts.values.reduce(Decimal.zero, +), residents: residentRows,
            obligations: obligations, warnings: warnings)
    }

    static func close(_ report: PropertyMonthlyReport, at date: Date = .now) -> PropertySettlementClose? {
        guard report.canClose else { return nil }
        return PropertySettlementClose(id: UUID(), propertyID: report.propertyID, monthStart: report.monthStart,
            closedAt: date, residents: report.residents.map {
                PropertyResidentSnapshot(id: $0.id, name: $0.name, income: $0.income,
                    share: $0.share, obligation: $0.rent + $0.sharedExpenses + $0.individualExpenses + $0.adjustments,
                    paid: $0.paid, directContribution: $0.directContribution)
            }, obligations: report.obligations,
            totalObligations: report.residents.reduce(Decimal.zero) {
                $0 + $1.rent + $1.sharedExpenses + $1.individualExpenses + $1.adjustments
            }, warnings: report.warnings)
    }

    static func frozenReport(_ close: PropertySettlementClose, ledger: PropertyLedger,
                             transactions: [PropertyTransactionInput], asOf: Date = .distantFuture) -> PropertyMonthlyReport {
        let inputs = Dictionary(transactions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let obligationIDs = Set(close.obligations.map(\.id))
        var discrepancies = close.warnings
        for obligation in close.obligations {
            guard let transactionID = obligation.transactionID else { continue }
            guard let input = inputs[transactionID] else {
                discrepancies.append("El movimiento de «\(obligation.title)» ya no está disponible; el cierre conserva su importe original.")
                continue
            }
            let amountMatches = obligation.kind == .reimbursement
                ? input.amount > 0 && input.amount == obligation.amount
                : input.amount < 0 && abs(input.amount) == obligation.amount
            if input.deletedAt != nil || input.isDuplicate || input.isTransfer || (input.isHouseholdAssigned && ledger.householdLink?.propertyID != close.propertyID)
                || !amountMatches
                || (obligation.sourceCurrencyCode != nil && obligation.sourceCurrencyCode != input.currencyCode)
                || (ledger.householdLink?.propertyID != close.propertyID && Calendar.current.propertyMonthStart(for: input.postedAt) != close.monthStart)
                || (obligation.sourcePostedAt != nil && !isSameWholeSecond(obligation.sourcePostedAt!, input.postedAt))
                || obligation.title != input.description {
                discrepancies.append("El movimiento de «\(obligation.title)» cambió después del cierre; revisa un ajuste en un periodo abierto.")
            }
        }
        let propertyApplications = ledger.paymentApplications.filter {
            $0.propertyID == close.propertyID && $0.deletedAt == nil
        }
        let reconciliation = reconciliationReview(propertyID: close.propertyID, obligations: close.obligations,
                                                  applications: propertyApplications, inputs: inputs)
        discrepancies.append(contentsOf: reconciliation.warnings)
        let doubleUsedReceipts = reconciliation.doubleUsedReceipts
        let overallocatedPaymentIDs = reconciliation.overallocatedPaymentIDs
        for application in propertyApplications where PropertyPaymentAdvance.isAdvance(application)
            || obligationIDs.contains(application.obligationID) {
            guard let input = inputs[application.paymentTransactionID],
                  !overallocatedPaymentIDs.contains(application.paymentTransactionID),
                  isValidCollectionPayment(input, asOf: .distantFuture) else {
                discrepancies.append("Un movimiento aplicado a este cierre ya no es un cobro válido; revisa la conciliación.")
                continue
            }
            if hasSourceChanged(amount: application.sourceAmountSnapshot, postedAt: application.sourcePostedAtSnapshot,
                                currencyCode: application.sourceCurrencySnapshot, description: application.sourceDescriptionSnapshot,
                                versus: input) {
                discrepancies.append("Un cobro vinculado cambió después del cierre; revisa la conciliación.")
            }
        }
        let applications = ledger.paymentApplications.filter {
            $0.propertyID == close.propertyID && $0.deletedAt == nil
                && !PropertyPaymentAdvance.isAdvance($0)
                && obligationIDs.contains($0.obligationID)
                && !overallocatedPaymentIDs.contains($0.paymentTransactionID)
                && !doubleUsedReceipts.contains($0.paymentTransactionID)
                && isValidCollectionPayment(inputs[$0.paymentTransactionID], asOf: asOf)
        }
        let cashCollected = ledger.paymentApplications.filter { application in
            guard application.propertyID == close.propertyID, application.deletedAt == nil,
                  let payment = inputs[application.paymentTransactionID],
                  isValidCollectionPayment(payment, asOf: asOf),
                  !overallocatedPaymentIDs.contains(application.paymentTransactionID),
                  !doubleUsedReceipts.contains(application.paymentTransactionID) else { return false }
            return Calendar.current.isDate(payment.postedAt, equalTo: close.monthStart, toGranularity: .month)
        }.reduce(Decimal.zero) { $0 + $1.amount }
        let paid = Dictionary(grouping: applications, by: \.residentID).mapValues {
            $0.reduce(Decimal.zero) { $0 + $1.amount }
        }
        let rows = close.residents.map { snapshot in
            var rent: Decimal = 0
            var shared: Decimal = 0
            var individual: Decimal = 0
            var adjustments: Decimal = 0
            for obligation in close.obligations {
                let allocated = obligation.allocations[snapshot.id] ?? 0
                if obligation.isRent { rent += allocated }
                else if obligation.transactionID == nil { adjustments += allocated }
                else {
                    switch obligation.responsibility {
                    case .individual(let id) where id == snapshot.id: individual += allocated
                    case .shared, .selected: shared += allocated
                    case .individual, .owner: break
                    }
                }
            }
            return PropertyResidentReport(id: snapshot.id, name: snapshot.name, income: snapshot.income,
                confirmed: true, share: snapshot.share, rent: rent, sharedExpenses: shared,
                individualExpenses: individual, adjustments: adjustments, paid: (paid[snapshot.id] ?? 0) + (snapshot.directContribution ?? 0),
                priorDebt: 0)
        }
        let priorDebts = priorBalances(propertyID: close.propertyID, before: close.monthStart, ledger: ledger,
                                       transactions: inputs, asOf: asOf)
        let advanceAvailable = propertyApplications.filter {
            PropertyPaymentAdvance.isAdvance($0) && !overallocatedPaymentIDs.contains($0.paymentTransactionID)
                && !doubleUsedReceipts.contains($0.paymentTransactionID)
                && isValidCollectionPayment(inputs[$0.paymentTransactionID], asOf: asOf)
        }.reduce(Decimal.zero) { $0 + $1.amount }
        let rowsWithPrior = rows.map { row in
            var row = row
            row.priorDebt = priorDebts[row.id] ?? 0
            return row
        }
        let rent = close.obligations.filter(\.isRent).reduce(Decimal.zero) { $0 + $1.amount }
        let expenses = close.obligations.filter { $0.transactionID != nil && $0.kind != .reimbursement }
            .reduce(Decimal.zero) { $0 + $1.amount }
        let reimbursementsReceived = close.obligations.filter {
            $0.transactionID != nil && $0.kind == .reimbursement
        }.reduce(Decimal.zero) { $0 + $1.amount }
        return PropertyMonthlyReport(propertyID: close.propertyID, monthStart: close.monthStart,
            rent: rent, expenses: expenses, collected: applications.reduce(0) { $0 + $1.amount },
            cashCollected: cashCollected, advanceAvailable: advanceAvailable,
            reimbursementsReceived: reimbursementsReceived,
            priorBalance: priorDebts.values.reduce(Decimal.zero, +), residents: rowsWithPrior,
            obligations: close.obligations, warnings: Array(Set(discrepancies)).sorted())
    }

    private static func priorBalances(propertyID: UUID, before month: Date, ledger: PropertyLedger,
                                      transactions: [UUID: PropertyTransactionInput], asOf: Date) -> [UUID: Decimal] {
        var balances: [UUID: Decimal] = [:]
        for close in ledger.closes where close.propertyID == propertyID && close.monthStart < month {
            let obligationIDs = Set(close.obligations.map(\.id))
            let reimbursementTransactionIDs = Set(close.obligations.compactMap {
                $0.kind == .reimbursement ? $0.transactionID : nil
            })
            let paid = Dictionary(grouping: ledger.paymentApplications.filter {
                $0.propertyID == propertyID && $0.deletedAt == nil && obligationIDs.contains($0.obligationID)
                    && !reimbursementTransactionIDs.contains($0.paymentTransactionID)
                    && isValidCollectionPayment(transactions[$0.paymentTransactionID], asOf: asOf)
            }, by: \.residentID).mapValues { $0.reduce(Decimal.zero) { $0 + $1.amount } }
            for resident in close.residents {
                balances[resident.id, default: 0] += resident.obligation - (resident.directContribution ?? 0) - (paid[resident.id] ?? 0)
            }
        }
        return balances
    }

    static func allocate(_ amount: Decimal, residentIDs: [UUID], incomes: [Decimal]) -> [UUID: Decimal]? {
        let incomeTotal = incomes.reduce(Decimal.zero, +)
        guard amount >= 0, residentIDs.count == incomes.count, incomeTotal > 0,
              incomes.allSatisfy({ $0 >= 0 }) else { return nil }
        var amountCopy = amount
        var wholePesos = Decimal()
        NSDecimalRound(&wholePesos, &amountCopy, 0, .down)
        var centsValue = (amount - wholePesos) * 100
        var roundedCents = Decimal()
        NSDecimalRound(&roundedCents, &centsValue, 0, .plain)
        let cents = NSDecimalNumber(decimal: roundedCents).intValue
        let pesoShares = apportion(units: NSDecimalNumber(decimal: wholePesos).intValue,
            residentIDs: residentIDs, incomes: incomes, incomeTotal: incomeTotal)
        let centShares = apportion(units: cents, residentIDs: residentIDs,
            incomes: incomes, incomeTotal: incomeTotal)
        return Dictionary(uniqueKeysWithValues: residentIDs.indices.map { index in
            (residentIDs[index], Decimal(pesoShares[index]) + Decimal(centShares[index]) / 100)
        })
    }

    private static func apportion(units: Int, residentIDs: [UUID], incomes: [Decimal],
                                  incomeTotal: Decimal) -> [Int] {
        var allocated = Array(repeating: 0, count: residentIDs.count)
        var remainders: [(index: Int, value: Decimal)] = []
        var used = 0
        for index in residentIDs.indices {
            let raw = Decimal(units) * incomes[index] / incomeTotal
            var floor = Decimal()
            var value = raw
            NSDecimalRound(&floor, &value, 0, .down)
            allocated[index] = NSDecimalNumber(decimal: floor).intValue
            used += allocated[index]
            remainders.append((index, raw - floor))
        }
        let remaining = max(0, units - used)
        let order = remainders.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return residentIDs[$0.index].uuidString < residentIDs[$1.index].uuidString
        }
        for entry in order.prefix(remaining) { allocated[entry.index] += 1 }
        return allocated
    }

}

struct PropertyMaintenanceSummary: Equatable, Sendable {
    var invested: Decimal
    var budgetAvailable: Decimal
    var recovered: Decimal
    var capitalPending: Decimal
    var reserveAvailable: Decimal
    var warnings: [String] = []
}

enum PropertyMaintenanceCalculator {
    private struct Event {
        var date: Date
        var amount: Decimal
        var rentMonth: Date?
        var isInvestment: Bool
    }

    static func summary(program: PropertyMaintenanceProgram, ledger: PropertyLedger,
                        transactions: [PropertyTransactionInput], calendar: Calendar = .current) -> PropertyMaintenanceSummary {
        let transactionByID = Dictionary(transactions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let reimbursementTransactionIDs = Set(ledger.attributions.filter {
            $0.propertyID == program.propertyID && $0.kind == .reimbursement && $0.deletedAt == nil
        }.map(\.transactionID))
        var events: [Event] = []
        var warnings: [String] = []
        for attribution in ledger.attributions where attribution.propertyID == program.propertyID
            && attribution.maintenanceProgramID == program.id && attribution.kind == .maintenance
            && attribution.deletedAt == nil && attribution.responsibility == .owner {
            guard let transaction = transactionByID[attribution.transactionID] else {
                warnings.append("Un movimiento del programa ya no está disponible; revisa la inversión registrada.")
                continue
            }
            if transaction.currencyCode != "MXN" {
                warnings.append("El movimiento «\(transaction.description)» está en \(transaction.currencyCode); no se suma al programa en MXN.")
                continue
            }
            if transaction.isHouseholdAssigned {
                warnings.append("El movimiento «\(transaction.description)» también está asignado al hogar; no se suma al programa.")
                continue
            }
            if PropertySettlementCalculator.hasSourceChanged(amount: attribution.sourceAmountSnapshot,
                                postedAt: attribution.sourcePostedAtSnapshot,
                                currencyCode: nil, description: attribution.sourceDescriptionSnapshot,
                                versus: transaction) {
                warnings.append("El movimiento «\(transaction.description)» cambió desde que se vinculó al programa.")
            }
            guard transaction.amount < 0, transaction.deletedAt == nil, !transaction.isDuplicate,
                  !transaction.isTransfer, !transaction.isHouseholdAssigned,
                  calendar.propertyMonthStart(for: transaction.postedAt) >= program.startsAt,
                  calendar.propertyMonthStart(for: transaction.postedAt) <= program.endsAt else { continue }
            events.append(Event(date: transaction.postedAt, amount: abs(transaction.amount), rentMonth: nil, isInvestment: true))
        }
        let programMonths = monthStarts(from: program.startsAt, through: program.endsAt, calendar: calendar)
        let rentObligations = Dictionary(uniqueKeysWithValues: programMonths.map {
            (stableRentID(program.propertyID, $0, calendar: calendar), $0)
        })
        let applicationsByPayment = Dictionary(grouping: ledger.paymentApplications.filter { $0.deletedAt == nil },
                                               by: \.paymentTransactionID)
        let overallocatedPaymentIDs = Set(applicationsByPayment.compactMap { paymentID, applications -> UUID? in
            guard let payment = transactionByID[paymentID], payment.amount > 0,
                  payment.currencyCode == "MXN" else { return nil }
            return applications.reduce(Decimal.zero) { $0 + $1.amount } > payment.amount ? paymentID : nil
        })
        for application in ledger.paymentApplications where application.propertyID == program.propertyID
            && application.deletedAt == nil && rentObligations[application.obligationID] != nil {
            if reimbursementTransactionIDs.contains(application.paymentTransactionID) {
                warnings.append("El movimiento aplicado a renta también está atribuido como reembolso; no genera recuperación.")
                continue
            }
            if overallocatedPaymentIDs.contains(application.paymentTransactionID) {
                warnings.append("Las aplicaciones del cobro vinculado a renta superan su importe; no genera recuperación.")
                continue
            }
            if let payment = transactionByID[application.paymentTransactionID], payment.currencyCode != "MXN" {
                warnings.append("El cobro «\(payment.description)» está en \(payment.currencyCode); no genera recuperación en MXN.")
            } else if transactionByID[application.paymentTransactionID] == nil {
                warnings.append("Un cobro del programa ya no está disponible; revisa la recuperación.")
            }
        }
        for application in ledger.paymentApplications where application.propertyID == program.propertyID && application.deletedAt == nil {
            guard let month = rentObligations[application.obligationID],
                  application.amount > 0,
                  !overallocatedPaymentIDs.contains(application.paymentTransactionID),
                  !reimbursementTransactionIDs.contains(application.paymentTransactionID),
                  let transaction = transactionByID[application.paymentTransactionID],
                  PropertySettlementCalculator.isValidCollectionPayment(transaction, asOf: .distantFuture) else { continue }
            let effectiveDate = max(transaction.postedAt, month)
            events.append(Event(date: effectiveDate, amount: application.amount, rentMonth: month, isInvestment: false))
        }
        events.sort {
            if $0.date != $1.date { return $0.date < $1.date }
            if $0.isInvestment != $1.isInvestment { return $0.isInvestment }
            return ($0.rentMonth ?? .distantPast) < ($1.rentMonth ?? .distantPast)
        }
        var invested: Decimal = 0
        var recovered: Decimal = 0
        var recoveredByMonth: [Date: Decimal] = [:]
        var availableByMonth: [Date: Decimal] = [:]
        for event in events {
            if event.isInvestment {
                invested += event.amount
            } else if let month = event.rentMonth {
                availableByMonth[month, default: 0] += event.amount
            }
            for month in availableByMonth.keys.sorted() {
                let roomThisMonth = max(0, program.monthlyRecoveryLimit - (recoveredByMonth[month] ?? 0))
                let roomToRecover = max(0, invested - recovered)
                let recovery = min(availableByMonth[month] ?? 0, min(roomThisMonth, roomToRecover))
                recovered += recovery
                recoveredByMonth[month, default: 0] += recovery
                availableByMonth[month, default: 0] -= recovery
            }
        }
        let reserve = ledger.reserveMovements.filter { $0.propertyID == program.propertyID && $0.deletedAt == nil }
            .reduce(Decimal.zero) { $0 + $1.amount }
        return PropertyMaintenanceSummary(invested: invested,
            budgetAvailable: max(0, program.budget - invested), recovered: recovered,
            capitalPending: max(0, invested - recovered), reserveAvailable: reserve,
            warnings: Array(Set(warnings)).sorted())
    }

    static func stableRentID(_ propertyID: UUID, _ month: Date, calendar: Calendar = .current) -> UUID {
        UUID.deterministic(propertyID, calendar.propertyMonthStart(for: month), "rent")
    }

    private static func monthStarts(from start: Date, through end: Date, calendar: Calendar) -> [Date] {
        var result: [Date] = []
        var month = calendar.propertyMonthStart(for: start)
        let last = calendar.propertyMonthStart(for: end)
        while month <= last {
            result.append(month)
            guard let next = calendar.date(byAdding: .month, value: 1, to: month) else { break }
            month = next
        }
        return result
    }
}

extension Calendar {
    func propertyMonthStart(for date: Date) -> Date {
        let components = dateComponents([.year, .month], from: date)
        return self.date(from: components) ?? startOfDay(for: date)
    }
}

extension UUID {
    static func deterministic(_ propertyID: UUID, _ date: Date, _ suffix: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data("\(propertyID.uuidString)-\(date.timeIntervalSince1970)-\(suffix)".utf8)))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
