import Foundation

struct PropertyActivityColumnFilters {
    var accounts: Set<String> = []
    var responsibilities: Set<String> = []
    var isActive: Bool { !accounts.isEmpty || !responsibilities.isEmpty }

    func apply(to rows: [PropertyActivityRow]) -> [PropertyActivityRow] {
        let unavailableAccount = String(localized: "Account unavailable")
        return rows.filter {
            (accounts.isEmpty || accounts.contains($0.account ?? unavailableAccount))
                && (responsibilities.isEmpty || responsibilities.contains($0.responsibility))
        }
    }
}

/// Presentation totals use visible financial rows, never calculated rent or bank mutations.
struct PropertyActivitySummary: Equatable {
    struct Total: Identifiable, Equatable {
        var kind: PropertyActivityRow.Kind
        var currency: String
        var amount: Decimal?
        var id: String { kind.rawValue + ":" + currency }
    }
    var count: Int
    var missingAmountCount: Int
    var totals: [Total]

    static func uniqueRows(_ rows: [PropertyActivityRow]) -> [PropertyActivityRow] {
        var seen = Set<UUID>()
        return rows.filter { seen.insert($0.id).inserted }
    }

    init(rows: [PropertyActivityRow]) {
        let rows = Self.uniqueRows(rows)
        count = rows.count
        missingAmountCount = rows.filter { $0.amount == nil }.count
        totals = PropertyActivityRow.Kind.allCases.flatMap { kind in
            let matching = rows.filter { $0.kind == kind }
            return Dictionary(grouping: matching, by: \.currency).sorted { $0.key < $1.key }.map { code, values in
                let amounts = values.compactMap(\.amount)
                return Total(kind: kind, currency: code, amount: amounts.isEmpty ? nil : amounts.reduce(Decimal.zero, +))
            }
        }
    }
}
