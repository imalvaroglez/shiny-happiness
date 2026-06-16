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
