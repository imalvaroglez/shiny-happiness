import Foundation

/// Monetary graph construction has no SwiftUI or SwiftData dependencies.
struct PropertyExpenseFlow: Identifiable, Equatable {
    enum Stage: Int, CaseIterable { case contributors, total, categories, subcategories }
    struct Contributor: Equatable {
        var id: UUID
        var name: String
        var share: Decimal?
        var estimated: Bool = false

        init(id: UUID, name: String, share: Decimal?, estimated: Bool = false) {
            self.id = id; self.name = name; self.share = share; self.estimated = estimated
        }
        init(_ row: PropertyMonthlyMemberRow) {
            self.init(id: row.memberID, name: row.name, share: row.share, estimated: row.shareIsEstimated)
        }
    }
    struct Node: Identifiable, Equatable {
        var id: String
        var name: String
        var amount: Decimal
        var stage: Stage
        var contributionShare: Decimal? = nil
        var estimated = false
        var parentID: String?
        var colorID: UUID?
    }
    struct Link: Identifiable, Equatable {
        var source: String
        var target: String
        var amount: Decimal
        var colorID: UUID?
        var id: String { source + ":" + target }
    }
    var currency: String
    var nodes: [Node]
    var links: [Link]
    var paletteIDs: [UUID]
    var canExpand: Bool
    var contributionsAvailable: Bool
    var stages: [Stage] { Stage.allCases.filter { stage in nodes.contains { $0.stage == stage } } }
    var totalID: String { currency + "/total" }
    var id: String { currency }
    var total: Decimal { nodes.first { $0.stage == .total }?.amount ?? 0 }

    static func groups(rows: [PropertyActivityRow], contributors: [Contributor] = [], expanded: Bool = false) -> [Self] {
        let expenses = PropertyActivitySummary.uniqueRows(rows).filter { $0.kind == .expense && ($0.amount ?? 0) > 0 }
        return Dictionary(grouping: expenses, by: \.currency).sorted { $0.key < $1.key }.map { currency, rows in
            var roots: [String: Node] = [:]
            var leaves: [String: Node] = [:]
            for row in rows {
                let hierarchy = row.categoryHierarchy ?? row.categoryID.map {
                    .path([PropertyCategoryComponent(id: $0, name: row.categoryName ?? String(localized: "Category unavailable"))])
                } ?? (row.categoryName == nil ? .unavailable : .uncategorized)
                let rootKey: String; let rootName: String; let color: UUID?
                let leafKey: String; let leafName: String
                switch hierarchy {
                case .path(let path) where !path.isEmpty:
                    let root = path[0]
                    rootKey = root.id.uuidString; rootName = root.name; color = root.id
                    leafKey = path.count == 1 ? "direct" : path.dropFirst().map { $0.id.uuidString }.joined(separator: "/")
                    leafName = path.count == 1 ? String(localized: "Without subcategory") : path.dropFirst().map(\.name).joined(separator: " › ")
                case .uncategorized:
                    rootKey = "uncategorized"; rootName = String(localized: "Uncategorized"); color = nil
                    leafKey = "direct"; leafName = String(localized: "Without subcategory")
                default:
                    rootKey = "unavailable"; rootName = String(localized: "Category unavailable"); color = nil
                    leafKey = "unavailable"; leafName = String(localized: "Detail unavailable")
                }
                let rootID = currency + "/category/" + rootKey
                let leafID = rootID + "/detail/" + leafKey
                if roots[rootID] == nil { roots[rootID] = Node(id: rootID, name: rootName, amount: 0, stage: .categories, colorID: color) }
                if leaves[leafID] == nil { leaves[leafID] = Node(id: leafID, name: leafName, amount: 0, stage: .subcategories, parentID: rootID, colorID: color) }
                roots[rootID]!.amount += row.amount!
                leaves[leafID]!.amount += row.amount!
            }
            let categories = roots.values.sorted(by: precedes)
            let palette = categories.compactMap(\.colorID)
            let totalID = currency + "/total"
            let total = categories.reduce(Decimal.zero) { $0 + $1.amount }
            let cut = visiblePrefix(of: categories, total: total)
            var nodes = [Node(id: totalID, name: String(localized: "Total spending"), amount: total, stage: .total)]
            var links: [Link] = []
            var displayed: [(category: Node, details: [Node])] = []
            // The summary cut decides expansion for both presentations, so the
            // Summarize action never disappears once the graph is expanded.
            let canExpand = !cut.grouped.isEmpty || cut.visible.contains { category in
                leaves.values.filter { $0.parentID == category.id }.count > 3
            }
            func append(_ category: Node, details: [Node]) {
                nodes.append(category)
                links.append(Link(source: totalID, target: category.id, amount: category.amount, colorID: category.colorID))
                for detail in details {
                    nodes.append(detail)
                    links.append(Link(source: category.id, target: detail.id, amount: detail.amount, colorID: category.colorID))
                }
            }
            for category in expanded ? categories : Array(cut.visible) {
                var details = leaves.values.filter { $0.parentID == category.id }.sorted(by: precedes)
                if !expanded && details.count > 3 {
                    let other = Node(id: category.id + "/other", name: String(localized: "Other subcategories"),
                        amount: details.dropFirst(2).reduce(0) { $0 + $1.amount }, stage: .subcategories, parentID: category.id, colorID: category.colorID)
                    details = Array(details.prefix(2)) + [other]
                }
                displayed.append((category, details.sorted(by: precedes)))
            }
            if !expanded && !cut.grouped.isEmpty {
                let id = currency + "/other"
                let amount = cut.grouped.reduce(Decimal.zero) { $0 + $1.amount }
                displayed.append((Node(id: id, name: String(localized: "Other categories"), amount: amount, stage: .categories),
                    [Node(id: id + "/details", name: String(localized: "Other categories"), amount: amount, stage: .subcategories, parentID: id)]))
            }
            for group in displayed { append(group.category, details: group.details) }
            let contributions = contributionNodes(contributors, total: total, currency: currency)
            if let contributions {
                nodes = contributions + nodes
                links = contributions.map { Link(source: $0.id, target: totalID, amount: $0.amount, colorID: nil) } + links
            }
            return Self(currency: currency, nodes: nodes, links: links, paletteIDs: palette,
                canExpand: canExpand, contributionsAvailable: contributions != nil)
        }
    }

    /// `categories` must already be ordered by `precedes`. Categories whose
    /// running total stays within 80% of `total` — reaching the budget exactly
    /// still counts as inside — are visible; the first category that would
    /// cross the budget groups itself together with every following category,
    /// so a large category is never skipped in favor of smaller ones. A first
    /// category above the budget on its own is still shown, with every other
    /// category grouped.
    static func visiblePrefix(of categories: [Node], total: Decimal) -> (visible: ArraySlice<Node>, grouped: ArraySlice<Node>) {
        let budget = total * Decimal(string: "0.8")!
        var accumulated = Decimal.zero
        var cut = categories.startIndex
        while cut < categories.endIndex, accumulated + categories[cut].amount <= budget {
            accumulated += categories[cut].amount
            cut += 1
        }
        if cut == categories.startIndex, !categories.isEmpty { cut += 1 }
        return (categories[..<cut], categories[cut...])
    }

    /// Only cent allocation is rounded; labels retain the original monthly percentage.
    private static func contributionNodes(_ members: [Contributor], total: Decimal, currency: String) -> [Node]? {
        guard !members.isEmpty, Set(members.map(\.id)).count == members.count,
              members.allSatisfy({ member in
                  guard let share = member.share else { return false }
                  return !share.isNaN && share >= 0 && share <= 1
              }) else { return nil }
        let sum = members.reduce(Decimal.zero) { $0 + ($1.share ?? 0) }
        // Decimal division may leave an insignificant tail; incomplete shares must not be normalized.
        guard sum > 0, abs(sum - 1) <= Decimal(string: "0.000000000000000000000001")! else { return nil }
        var amounts: [UUID: Decimal] = [:]
        var residuals: [UUID: Decimal] = [:]
        for member in members {
            let raw = total * (member.share ?? 0) / sum
            var value = raw; var floor = Decimal()
            NSDecimalRound(&floor, &value, 2, .down)
            amounts[member.id] = floor; residuals[member.id] = raw - floor
        }
        var remaining = total - amounts.values.reduce(0, +)
        let order = members.sorted {
            let a = residuals[$0.id, default: 0]; let b = residuals[$1.id, default: 0]
            return a == b ? $0.id.uuidString < $1.id.uuidString : a > b
        }
        for member in order where remaining > 0 {
            let unit = min(Decimal(string: "0.01")!, remaining)
            amounts[member.id, default: 0] += unit; remaining -= unit
        }
        return members.map { member in
            Node(id: currency + "/contributor/" + member.id.uuidString, name: member.name,
                amount: amounts[member.id, default: 0], stage: .contributors,
                contributionShare: member.share, estimated: member.estimated)
        }.sorted(by: precedes)
    }

    func highlightedLinkIDs(for selectedID: String?) -> Set<String> {
        guard let selectedID, let node = nodes.first(where: { $0.id == selectedID }), node.stage != .total else {
            return Set(links.map(\.id))
        }
        return Set(links.filter { link in
            if node.stage == .contributors { return link.source == node.id }
            if node.stage == .categories { return link.source == node.id || link.target == node.id }
            return link.target == node.id || (link.target == node.parentID && link.source == totalID)
        }.map(\.id))
    }

    private static func precedes(_ lhs: Node, _ rhs: Node) -> Bool {
        lhs.amount == rhs.amount ? lhs.id < rhs.id : lhs.amount > rhs.amount
    }
}
