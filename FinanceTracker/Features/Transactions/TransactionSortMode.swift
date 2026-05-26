import Foundation

enum TransactionSortMode: String, CaseIterable {
    case dateDesc = "Newest First"
    case dateAsc = "Oldest First"
    case amountDesc = "Amount ↓"
    case amountAsc = "Amount ↑"
    case name = "Name A-Z"

    var groupsReversed: Bool {
        switch self {
        case .dateAsc: return true
        default: return false
        }
    }

    var rowSort: (Transaction, Transaction) -> Bool {
        switch self {
        case .dateDesc: { $0.postedAt > $1.postedAt }
        case .dateAsc: { $0.postedAt > $1.postedAt }
        case .amountDesc: { $0.amount > $1.amount }
        case .amountAsc: { $0.amount < $1.amount }
        case .name: { $0.merchantNormalized.localizedCaseInsensitiveCompare($1.merchantNormalized) == .orderedAscending }
        }
    }
}
