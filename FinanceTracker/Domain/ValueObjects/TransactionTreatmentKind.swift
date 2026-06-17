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
        case .regular: "Regular"
        case .retirementContributionUserFunded: "User-funded retirement contribution"
        case .retirementContributionEmployerFunded: "Employer retirement contribution"
        case .statutoryRetirementContribution: "Statutory retirement contribution"
        case .investmentReturn: "Investment return"
        case .fee: "Fee"
        case .valuationAdjustment: "Valuation adjustment"
        }
    }
}
