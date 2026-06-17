import Foundation
import SwiftData

@Model
final class Account: LastModifiedTracking {
    var id: UUID
    var institution: String
    var type: AccountType
    var currency: String
    var nickname: String
    var accountNumber: String?
    var openedAt: Date
    var closedAt: Date?
    var creditLimit: Decimal?
    var statementDayOfMonth: Int?
    var paymentDayOfMonth: Int?
    /// Optional user-chosen identity color stored as `#RRGGBB`. When nil,
    /// `AccountIdentity.color(for:)` falls back to the institution default map.
    var tintHex: String?
    var manuallyCreatedAt: Date?
    var retirementKindRaw: String?
    var liquidityRaw: String?
    var includeInNetWorth: Bool?
    var includeInCashFlow: Bool?
    var includeInRegularIncome: Bool?
    var taxTrackingEnabled: Bool?
    var lastModifiedAt: Date = Date.now

    init(
        id: UUID = UUID(),
        institution: String,
        type: AccountType,
        currency: String = "MXN",
        nickname: String? = nil,
        accountNumber: String? = nil,
        openedAt: Date = .now,
        closedAt: Date? = nil,
        creditLimit: Decimal? = nil,
        statementDayOfMonth: Int? = nil,
        paymentDayOfMonth: Int? = nil,
        tintHex: String? = nil,
        manuallyCreatedAt: Date? = nil,
        retirementKindRaw: String? = nil,
        liquidityRaw: String? = nil,
        includeInNetWorth: Bool? = nil,
        includeInCashFlow: Bool? = nil,
        includeInRegularIncome: Bool? = nil,
        taxTrackingEnabled: Bool? = nil
    ) {
        self.id = id
        self.institution = institution
        self.type = type
        self.currency = currency
        self.nickname = nickname ?? institution
        self.accountNumber = accountNumber
        self.openedAt = openedAt
        self.closedAt = closedAt
        self.creditLimit = creditLimit
        self.statementDayOfMonth = statementDayOfMonth
        self.paymentDayOfMonth = paymentDayOfMonth
        self.tintHex = tintHex
        self.manuallyCreatedAt = manuallyCreatedAt
        self.retirementKindRaw = retirementKindRaw
        self.liquidityRaw = liquidityRaw
        self.includeInNetWorth = includeInNetWorth
        self.includeInCashFlow = includeInCashFlow
        self.includeInRegularIncome = includeInRegularIncome
        self.taxTrackingEnabled = taxTrackingEnabled

        if type == .retirement {
            if self.retirementKindRaw == nil { self.retirementKindRaw = RetirementKind.other.rawValue }
            applyRetirementDefaultsForCurrentKind()
        } else if type == .investment {
            self.liquidityRaw = liquidityRaw ?? AccountLiquidity.restricted.rawValue
            self.includeInNetWorth = includeInNetWorth ?? true
            self.includeInCashFlow = includeInCashFlow ?? false
            self.includeInRegularIncome = includeInRegularIncome ?? false
            self.taxTrackingEnabled = taxTrackingEnabled ?? false
        } else {
            self.liquidityRaw = liquidityRaw ?? Account.defaultLiquidity(type: type, retirementKind: nil).rawValue
            self.includeInNetWorth = includeInNetWorth ?? Account.defaultIncludeInNetWorth(type: type)
            self.includeInCashFlow = includeInCashFlow ?? Account.defaultIncludeInCashFlow(type: type)
            self.includeInRegularIncome = includeInRegularIncome ?? Account.defaultIncludeInRegularIncome(type: type)
            self.taxTrackingEnabled = taxTrackingEnabled ?? false
        }
    }

    var displayName: String {
        if nickname != institution { return nickname }
        if let last4 = accountNumber { return "\(institution) ····\(last4)" }
        return institution
    }
}

extension Account {
    var retirementKind: RetirementKind? {
        get { retirementKindRaw.flatMap(RetirementKind.init(rawValue:)) }
        set {
            retirementKindRaw = newValue?.rawValue
            applyRetirementDefaultsForCurrentKind()
        }
    }

    var liquidity: AccountLiquidity {
        get {
            if let raw = liquidityRaw, let value = AccountLiquidity(rawValue: raw) { return value }
            return Self.defaultLiquidity(type: type, retirementKind: retirementKind)
        }
        set { liquidityRaw = newValue.rawValue }
    }

    var isTaxTrackablePPR: Bool {
        retirementKind == .ppr && (taxTrackingEnabled ?? true)
    }

    var effectiveIncludeInNetWorth: Bool {
        includeInNetWorth ?? Self.defaultIncludeInNetWorth(type: type)
    }

    var effectiveIncludeInCashFlow: Bool {
        includeInCashFlow ?? Self.defaultIncludeInCashFlow(type: type)
    }

    var effectiveIncludeInRegularIncome: Bool {
        includeInRegularIncome ?? Self.defaultIncludeInRegularIncome(type: type)
    }

    func setInvestmentRetirementClassification(_ newType: AccountType) {
        switch (type, newType) {
        case (.investment, .retirement):
            type = .retirement
            retirementKindRaw = RetirementKind.other.rawValue
            applyRetirementDefaultsForCurrentKind()
        case (.retirement, .investment):
            type = .investment
            retirementKindRaw = nil
            taxTrackingEnabled = false
        default:
            return
        }
        touch()
    }

    func applyRetirementDefaultsForCurrentKind() {
        guard type == .retirement else { return }
        let kind = retirementKind ?? .other
        liquidityRaw = Self.defaultLiquidity(type: type, retirementKind: kind).rawValue
        includeInNetWorth = true
        includeInCashFlow = false
        includeInRegularIncome = false
        taxTrackingEnabled = kind == .ppr
    }

    static func defaultLiquidity(type: AccountType, retirementKind: RetirementKind?) -> AccountLiquidity {
        if type == .retirement {
            switch retirementKind ?? .other {
            case .ppr, .other: return .restricted
            case .afore, .employerRetirementPlan: return .lockedUntilRetirement
            }
        }
        return .liquid
    }

    static func defaultIncludeInNetWorth(type: AccountType) -> Bool {
        type != .other
    }

    static func defaultIncludeInCashFlow(type: AccountType) -> Bool {
        switch type {
        case .investment, .retirement:
            false
        default:
            true
        }
    }

    static func defaultIncludeInRegularIncome(type: AccountType) -> Bool {
        switch type {
        case .investment, .retirement, .creditCard, .loan:
            false
        default:
            true
        }
    }
}
