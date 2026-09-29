import Foundation

enum TransactionTreatmentKind: String, Codable, CaseIterable {
    case regular
    case retirementContributionUserFunded
    case retirementContributionEmployerFunded
    case statutoryRetirementContribution
    case investmentReturn
    case fee
    case valuationAdjustment
}

extension TransactionTreatmentKind {
    var displayName: String {
        switch self {
        case .regular: String(localized: "Regular")
        case .retirementContributionUserFunded: String(localized: "User-funded retirement contribution")
        case .retirementContributionEmployerFunded: String(localized: "Employer retirement contribution")
        case .statutoryRetirementContribution: String(localized: "Statutory retirement contribution")
        case .investmentReturn: String(localized: "Investment return")
        case .fee: String(localized: "Fee")
        case .valuationAdjustment: String(localized: "Valuation adjustment")
        }
    }
}
