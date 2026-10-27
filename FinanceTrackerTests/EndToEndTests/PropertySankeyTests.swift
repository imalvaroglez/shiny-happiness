import Testing
import Foundation
@testable import FinanceTracker

@Suite("Property Sankey")
struct PropertySankeyTests {
    private func row(_ amount: Decimal?, path: [PropertyCategoryComponent]? = nil) -> PropertyActivityRow {
        PropertyActivityRow(id: UUID(), date: .now, concept: "Fixture", account: "Test account", kind: .expense,
            amount: amount, currency: "MXN", responsibility: "Shared", canAssign: true, isClosed: false,
            categoryHierarchy: path.map { .path($0) } ?? .uncategorized)
    }

    @Test("Every level and connection conserves cents, currencies and unique financial sources")
    func conservation() throws {
        let root = PropertyCategoryComponent(id: UUID(), name: "Root")
        let child = PropertyCategoryComponent(id: UUID(), name: "Child")
        let deep = PropertyCategoryComponent(id: UUID(), name: "Deep")
        let a = row(10.25, path: [root, child, deep]); let b = row(2.75, path: [root])
        var foreign = a; foreign.id = UUID(); foreign.currency = "USD"
        var receipt = a; receipt.id = UUID(); receipt.kind = .collection
        var refund = receipt; refund.id = UUID(); refund.kind = .reimbursement
        var unavailable = row(3); unavailable.categoryHierarchy = .unavailable
        let groups = PropertyExpenseFlow.groups(rows: [a, a, b, foreign, receipt, refund, row(nil), unavailable, row(4)])
        let mxn = try #require(groups.first { $0.currency == "MXN" })
        #expect(mxn.total == 20)
        for stage in mxn.stages { #expect(mxn.nodes.filter { $0.stage == stage }.reduce(Decimal.zero) { $0 + $1.amount } == 20) }
        for node in mxn.nodes {
            let incoming = mxn.links.filter { $0.target == node.id }.reduce(Decimal.zero) { $0 + $1.amount }
            let outgoing = mxn.links.filter { $0.source == node.id }.reduce(Decimal.zero) { $0 + $1.amount }
            if node.stage != .total { #expect(incoming == node.amount) }
            if node.stage != .subcategories { #expect(outgoing == node.amount) }
        }
        #expect(mxn.nodes.contains { $0.name == "Child › Deep" && $0.amount == 10.25 })
        #expect(mxn.nodes.contains { $0.name == String(localized: "Without subcategory") && $0.amount == 2.75 })
        #expect(mxn.nodes.contains { $0.name == String(localized: "Uncategorized") })
        #expect(mxn.nodes.contains { $0.name == String(localized: "Category unavailable") })
        #expect(groups.first { $0.currency == "USD" }?.total == 10.25)
        #expect(PropertyExpenseFlow.groups(rows: [row(nil), row(0), receipt, refund]).isEmpty)
    }

    @Test("Summary has five categories plus others, two details plus others, stable palette and exact expansion")
    func collapse() throws {
        var rows: [PropertyActivityRow] = []
        for index in 0..<8 {
            let root = PropertyCategoryComponent(id: UUID(), name: "Root \(index)")
            for detail in 0..<6 {
                rows.append(row(Decimal((index + 1) * (detail + 1)), path: [root, .init(id: UUID(), name: "Detail \(detail)")]))
            }
        }
        let compact = try #require(PropertyExpenseFlow.groups(rows: rows).first)
        let full = try #require(PropertyExpenseFlow.groups(rows: rows, expanded: true).first)
        #expect(compact.total == full.total)
        #expect(compact.canExpand && full.canExpand)
        #expect(compact.paletteIDs == full.paletteIDs)
        #expect(compact.nodes.filter { $0.stage == .categories }.count == 6)
        #expect(full.nodes.filter { $0.stage == .categories }.count == 8)
        #expect(full.nodes.filter { $0.stage == .subcategories }.count == 48)
        for root in compact.nodes.filter({ $0.stage == .categories }) {
            #expect(compact.nodes.filter { $0.parentID == root.id }.count <= 3)
            #expect(compact.nodes.filter { $0.parentID == root.id }.reduce(Decimal.zero) { $0 + $1.amount } == root.amount)
        }
        #expect(PropertyExpenseFlow.groups(rows: rows.reversed()) == [compact])
    }

    @Test("Geometry preserves thickness independently of label heights and is deterministic without label overlap")
    func geometry() throws {
        let root = PropertyCategoryComponent(id: UUID(), name: "A long category with complete words")
        let rows = (1...40).map { row(Decimal($0), path: [root, .init(id: UUID(), name: "Long detail \($0)")]) }
        let graph = try #require(PropertyExpenseFlow.groups(rows: rows, expanded: true).first)
        let heights = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, CGFloat($0.stage == .subcategories ? 90 : 70)) })
        let layout = PropertySankeyLayout(graph: graph, width: 900, labelHeights: heights)
        let again = PropertySankeyLayout(graph: graph, width: 900, labelHeights: heights)
        #expect(layout.height > 520)
        #expect(layout.placements.map(\.bar) == again.placements.map(\.bar))
        for stage in graph.stages {
            let nodes = layout.placements.filter { $0.node.stage == stage }
            for (first, second) in zip(nodes, nodes.dropFirst()) { #expect(first.label.maxY <= second.label.minY) }
        }
        let scale = try #require(layout.ribbons.first).thickness / CGFloat(NSDecimalNumber(decimal: graph.links[0].amount).doubleValue)
        for ribbon in layout.ribbons {
            #expect(abs(ribbon.thickness - CGFloat(NSDecimalNumber(decimal: ribbon.link.amount).doubleValue) * scale) < 0.000001)
            #expect(ribbon.start.x < ribbon.end.x)
        }
        for node in layout.placements {
            #expect(node.label.maxX <= 900 && node.label.minY >= 0 && node.label.maxY <= layout.height + 0.001)
            #expect(node.bar.height.isFinite && node.bar.height > 0)
        }
    }

    @Test("Ties use identity, tiny monetary nodes keep their actual proportional size")
    func tiesAndTinyAmounts() throws {
        let first = PropertyCategoryComponent(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "One")
        let second = PropertyCategoryComponent(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "Two")
        let graph = try #require(PropertyExpenseFlow.groups(rows: [row(1000000, path: [second]), row(0.01, path: [first])]).first)
        let layout = PropertySankeyLayout(graph: graph, width: 720, labelHeights: [:])
        let tiny = try #require(layout.placements.first { $0.node.stage == .categories && $0.node.colorID == first.id })
        #expect(tiny.bar.height < 0.01 && tiny.label.height >= 48)
        let tied = try #require(PropertyExpenseFlow.groups(rows: [row(1, path: [second]), row(1, path: [first])]).first)
        #expect(tied.nodes.filter { $0.stage == .categories }.map(\.colorID) == [first.id, second.id])
    }

    @Test("Preparation benchmark uses 1,000 expenses, 12 categories and 120 details")
    func preparationBenchmark() throws {
        let roots = (0..<12).map { PropertyCategoryComponent(id: UUID(), name: "Category \($0)") }
        let details = (0..<120).map { PropertyCategoryComponent(id: UUID(), name: "Subcategory \($0)") }
        let rows = (0..<1000).map { row(Decimal($0 + 1) / 100, path: [roots[$0 % 12], details[$0 % 120]]) }
        let members: [PropertyExpenseFlow.Contributor] = [.init(id: firstID, name: "First", share: 0.75), .init(id: secondID, name: "Second", share: 0.25)]
        let start = ContinuousClock.now
        let compact = try #require(PropertyExpenseFlow.groups(rows: rows, contributors: members).first)
        let full = try #require(PropertyExpenseFlow.groups(rows: rows, contributors: members, expanded: true).first)
        let layout = PropertySankeyLayout(graph: full, width: 1200, labelHeights: [:])
        print("Sankey preparation, 1000 rows, summary + expanded + geometry: \(start.duration(to: .now))")
        #expect(compact.total == 5005 && full.total == 5005)
        #expect(full.nodes.count == 135 && layout.placements.count == 135)
    }


    @Test("Grouped other nodes are sorted by their combined amount, not appended last")
    func groupedOrder() throws {
        let main = PropertyCategoryComponent(id: UUID(), name: "Main")
        var rows = [10, 9, 8, 7].map { row(Decimal($0), path: [main, .init(id: UUID(), name: "Detail \($0)")]) }
        for index in 0..<8 {
            rows.append(row(10, path: [.init(id: UUID(), name: "Category \(index)")]))
        }
        let graph = try #require(PropertyExpenseFlow.groups(rows: rows).first)
        let categories = graph.nodes.filter { $0.stage == .categories }
        #expect(categories.map(\.amount) == [40, 34, 10, 10, 10, 10])
        #expect(categories[0].name == String(localized: "Other categories"))
        let mainID = try #require(categories.first { $0.colorID == main.id }).id
        let details = graph.nodes.filter { $0.parentID == mainID }
        #expect(details.map(\.amount) == [15, 10, 9])
        #expect(details[0].name == String(localized: "Other subcategories"))
    }

    private let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    @Test("Member proportions fund the complete total independently of expense responsibility")
    func proportionalContributions() throws {
        let members: [PropertyExpenseFlow.Contributor] = [
            .init(id: firstID, name: "First member", share: Decimal(string: "0.9845")),
            .init(id: secondID, name: "Second member", share: Decimal(string: "0.0155"))]
        var expense = row(23665.88); expense.responsibility = "Individual"
        let baseline = try #require(PropertyExpenseFlow.groups(rows: [expense]).first)
        let graph = try #require(PropertyExpenseFlow.groups(rows: [expense, expense], contributors: members).first)
        let incoming = graph.nodes.filter { $0.stage == .contributors }
        #expect(incoming.map(\.amount) == [23299.06, 366.82])
        #expect(incoming.map(\.contributionShare) == [Decimal(string: "0.9845"), Decimal(string: "0.0155")])
        #expect(incoming.map(\.name) == ["First member", "Second member"])
        #expect(graph.contributionsAvailable && graph.stages.count == 4)
        #expect(graph.nodes.filter { $0.stage != .contributors } == baseline.nodes)
        #expect(graph.links.filter { $0.target != graph.totalID } == baseline.links)
        for stage in graph.stages {
            #expect(graph.nodes.filter { $0.stage == stage }.reduce(Decimal.zero) { $0 + $1.amount } == graph.total)
        }
        #expect(graph.links.filter { $0.target == graph.totalID }.reduce(Decimal.zero) { $0 + $1.amount } == graph.total)
        #expect(PropertyExpenseFlow.groups(rows: [expense], contributors: members.reversed()) == [graph])
    }

    @Test("Cent ties use UUID, zero contribution remains visible, a single member funds the total")
    func contributionRounding() throws {
        let members: [PropertyExpenseFlow.Contributor] = [
            .init(id: secondID, name: "Second", share: 0.5), .init(id: firstID, name: "First", share: 0.5)]
        let graph = try #require(PropertyExpenseFlow.groups(rows: [row(0.01)], contributors: members).first)
        #expect(graph.nodes.filter { $0.stage == .contributors }.map(\.amount) == [0.01, 0])
        let one: [PropertyExpenseFlow.Contributor] = [.init(id: firstID, name: "First", share: 1), .init(id: secondID, name: "Second", share: 0)]
        let zero = try #require(PropertyExpenseFlow.groups(rows: [row(9.99)], contributors: one).first)
        #expect(zero.nodes.filter { $0.stage == .contributors }.map(\.amount) == [9.99, 0])
        let single = try #require(PropertyExpenseFlow.groups(rows: [row(9.99)], contributors: Array(one.prefix(1))).first)
        #expect(single.nodes.first?.amount == 9.99)
    }

    @Test("Unknown or incomplete percentages produce no invented sources; estimated shares are identified")
    func missingAndEstimatedShares() throws {
        let invalid: [[PropertyExpenseFlow.Contributor]] = [[], [.init(id: firstID, name: "First", share: nil)],
            [.init(id: firstID, name: "First", share: 0)], [.init(id: firstID, name: "First", share: 0.8)],
            [.init(id: firstID, name: "First", share: -1)],
            [.init(id: firstID, name: "First", share: 0.5), .init(id: firstID, name: "Duplicate", share: 0.5)]]
        for members in invalid {
            let graph = try #require(PropertyExpenseFlow.groups(rows: [row(10)], contributors: members).first)
            #expect(!graph.contributionsAvailable && !graph.stages.contains(.contributors))
            #expect(graph.total == 10)
        }
        let members: [PropertyExpenseFlow.Contributor] = [.init(id: firstID, name: "First", share: 1, estimated: true)]
        let graph = try #require(PropertyExpenseFlow.groups(rows: [row(10)], contributors: members).first)
        #expect(graph.nodes.first?.estimated == true && graph.contributionsAvailable)
        // Accept only insignificant Decimal division tails, on either side of one.
        for second in ["0.4999999999999999999999999", "0.499999999999999999999999", "0.5000000000000000000000001"] {
            let tail: [PropertyExpenseFlow.Contributor] = [.init(id: firstID, name: "First", share: 0.5),
                .init(id: secondID, name: "Second", share: Decimal(string: second))]
            let accepted = try #require(PropertyExpenseFlow.groups(rows: [row(10.01)], contributors: tail).first)
            #expect(accepted.contributionsAvailable)
            #expect(accepted.nodes.filter { $0.stage == .contributors }.reduce(Decimal.zero) { $0 + $1.amount } == 10.01)
            #expect(accepted.nodes.first { $0.id.hasSuffix(secondID.uuidString) }?.contributionShare == Decimal(string: second))
        }
        for second in ["0.499999999999999999999998", "0.500000000000000000000002"] {
            let outside: [PropertyExpenseFlow.Contributor] = [.init(id: firstID, name: "First", share: 0.5),
                .init(id: secondID, name: "Second", share: Decimal(string: second))]
            #expect(PropertyExpenseFlow.groups(rows: [row(10.01)], contributors: outside).first?.contributionsAvailable == false)
        }
    }

    @Test("Contributions remain separate by currency and survive category expansion without change")
    func contributionCurrenciesAndExpansion() throws {
        var rows = (0..<8).map { row(Decimal($0 + 1), path: [.init(id: UUID(), name: "Category \($0)")]) }
        var foreign = row(3.33); foreign.currency = "USD"; rows.append(foreign)
        let members: [PropertyExpenseFlow.Contributor] = [.init(id: firstID, name: "First", share: 0.7), .init(id: secondID, name: "Second", share: 0.3)]
        let compact = PropertyExpenseFlow.groups(rows: rows, contributors: members)
        let expanded = PropertyExpenseFlow.groups(rows: rows, contributors: members, expanded: true)
        for group in compact {
            let full = try #require(expanded.first { $0.currency == group.currency })
            let sources = group.nodes.filter { $0.stage == .contributors }
            #expect(sources == full.nodes.filter { $0.stage == .contributors })
            #expect(sources.reduce(Decimal.zero) { $0 + $1.amount } == group.total)
        }
        #expect(compact.map(\.total) == [36, 3.33])
    }

    @Test("Four-column geometry reserves labels at 720 points and member selection only highlights its incoming flow")
    func fourColumnGeometryAndSelection() throws {
        let members: [PropertyExpenseFlow.Contributor] = [.init(id: firstID, name: "First member with a complete long name", share: 0.75),
            .init(id: secondID, name: "Second", share: 0.25)]
        let graph = try #require(PropertyExpenseFlow.groups(rows: [row(100)], contributors: members).first)
        for width in [CGFloat(720), CGFloat(1200)] {
            let heights = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, CGFloat(90)) })
            let layout = PropertySankeyLayout(graph: graph, width: width, labelHeights: heights)
            let total = try #require(layout.placements.first { $0.node.stage == .total })
            let source = try #require(layout.placements.first { $0.node.stage == .contributors })
            #expect(source.label.maxX < total.bar.minX)
            for node in layout.placements { #expect(node.label.maxX <= width && node.label.height >= 90) }
        }
        let member = try #require(graph.nodes.first { $0.stage == .contributors })
        let selected = graph.highlightedLinkIDs(for: member.id)
        #expect(selected.count == 1)
        #expect(graph.links.filter { selected.contains($0.id) }.allSatisfy { $0.source == member.id && $0.target == graph.totalID })
        #expect(graph.highlightedLinkIDs(for: graph.totalID).count == graph.links.count)
        #expect(graph.highlightedLinkIDs(for: nil).count == graph.links.count)
    }

}
