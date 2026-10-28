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
        let input = [a, a, b, foreign, receipt, refund, row(nil), unavailable, row(4)]
        let groups = PropertyExpenseFlow.groups(rows: input)
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
        // The 80% budget keeps Root (13 of 20) and groups Uncategorized (4) plus
        // Category unavailable (3) into a 7 Other categories node; both remain
        // real categories in the expanded presentation.
        #expect(mxn.nodes.contains { $0.name == String(localized: "Other categories") && $0.amount == 7 })
        let full = try #require(PropertyExpenseFlow.groups(rows: input, expanded: true).first { $0.currency == "MXN" })
        #expect(full.nodes.contains { $0.name == String(localized: "Uncategorized") })
        #expect(full.nodes.contains { $0.name == String(localized: "Category unavailable") })
        #expect(groups.first { $0.currency == "USD" }?.total == 10.25)
        #expect(PropertyExpenseFlow.groups(rows: [row(nil), row(0), receipt, refund]).isEmpty)
    }

    @Test("Summary keeps the 80% budget prefix with Others last, stable palette and exact expansion")
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
        // Root totals are 21...168; the 604.8 budget of 756 keeps 168+147+126+105 = 546
        // and groups the remaining 210 into Other categories, appended last.
        let categories = compact.nodes.filter { $0.stage == .categories }
        #expect(categories.map(\.amount) == [168, 147, 126, 105, 210])
        #expect(categories.last?.id == compact.currency + "/other")
        #expect(full.nodes.filter { $0.stage == .categories }.count == 8)
        #expect(full.nodes.filter { $0.stage == .subcategories }.count == 48)
        #expect(compact.nodes.filter { $0.stage == .subcategories }.count == 13)
        for root in categories {
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

    @Test("Ties use identity order inside the budget prefix, tiny Others keep proportional size")
    func tiesKeepStableIdentityOrdering() throws {
        let one = PropertyCategoryComponent(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "One")
        let two = PropertyCategoryComponent(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "Two")
        let three = PropertyCategoryComponent(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, name: "Three")
        let four = PropertyCategoryComponent(id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!, name: "Four")
        let tied = try #require(PropertyExpenseFlow.groups(rows: [
            row(10, path: [two]), row(10, path: [one]), row(10, path: [four]), row(10, path: [three])]).first)
        let categories = tied.nodes.filter { $0.stage == .categories }
        // Equal amounts resolve by id; three tied categories fit the 32 budget of 40, the fourth groups.
        #expect(categories.map(\.colorID) == [one.id, two.id, three.id, nil])
        #expect(categories.last?.name == String(localized: "Other categories") && categories.last?.amount == 10)
        // A dominant category keeps its tiny counterpart proportional inside Other categories.
        let dominant = try #require(PropertyExpenseFlow.groups(rows: [row(1000000, path: [two]), row(0.01, path: [one])]).first)
        let layout = PropertySankeyLayout(graph: dominant, width: 720, labelHeights: [:])
        let tiny = try #require(layout.placements.first { $0.node.stage == .categories && $0.node.id == dominant.currency + "/other" })
        #expect(tiny.bar.height < 0.01 && tiny.label.height >= 48)
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


    @Test("Other categories append last after the budget prefix instead of sorting by amount")
    func groupedOrder() throws {
        // Semantics inverted by the owner's rule: the previous test asserted Other
        // categories sorted among real categories by combined amount (it came first
        // at 40); Other categories now always render last, after the visible prefix.
        let main = PropertyCategoryComponent(id: UUID(), name: "Main")
        var rows = [10, 9, 8, 7].map { row(Decimal($0), path: [main, .init(id: UUID(), name: "Detail \($0)")]) }
        for index in 0..<8 {
            rows.append(row(10, path: [.init(id: UUID(), name: "Category \(index)")]))
        }
        let graph = try #require(PropertyExpenseFlow.groups(rows: rows).first)
        let categories = graph.nodes.filter { $0.stage == .categories }
        // Main (34) plus five tied 10s reach 84 of the 91.2 budget; three 10s group into a 30 Others.
        #expect(categories.map(\.amount) == [34, 10, 10, 10, 10, 10, 30])
        #expect(categories.last?.name == String(localized: "Other categories"))
        #expect(categories.last?.id == graph.currency + "/other")
        let mainID = try #require(categories.first { $0.colorID == main.id }).id
        let details = graph.nodes.filter { $0.parentID == mainID }
        #expect(details.map(\.amount) == [15, 10, 9])
        #expect(details[0].name == String(localized: "Other subcategories"))
    }

    @Test("Compact keeps the cumulative 80% prefix and appends Other categories last")
    func compactShowsBudgetPrefixWithOthersLast() throws {
        let rows = [50, 20, 10, 5, 4, 3, 2, 1].enumerated().map { index, amount in
            row(Decimal(amount), path: [PropertyCategoryComponent(id: UUID(), name: "Root \(index)")])
        }
        let compact = try #require(PropertyExpenseFlow.groups(rows: rows).first)
        let categories = compact.nodes.filter { $0.stage == .categories }
        // 50 + 20 = 70 of the 76 budget; the 10 that would cross it groups every remainder.
        #expect(categories.map(\.amount) == [50, 20, 25])
        #expect(categories.last?.id == compact.currency + "/other")
        #expect(categories.last?.name == String(localized: "Other categories"))
        #expect(categories.last?.amount == compact.total - categories.dropLast().reduce(Decimal.zero) { $0 + $1.amount })
        let visible = categories.dropLast()
        #expect(zip(visible, visible.dropFirst()).allSatisfy { $0.amount > $1.amount })
        #expect(compact.canExpand)
        #expect(PropertyExpenseFlow.groups(rows: rows.reversed()) == [compact])
    }

    @Test("The category crossing the 80% budget groups every following category, no skipping")
    func crossingCategoryGroupsAllFollowingNoSkipping() throws {
        let dominant = PropertyCategoryComponent(id: UUID(), name: "Dominant")
        let crossing = PropertyCategoryComponent(id: UUID(), name: "Crossing")
        let wouldFit = PropertyCategoryComponent(id: UUID(), name: "Would fit")
        let tail = PropertyCategoryComponent(id: UUID(), name: "Tail")
        let rows = [row(60, path: [dominant]), row(25, path: [crossing]), row(10, path: [wouldFit]), row(5, path: [tail])]
        let compact = try #require(PropertyExpenseFlow.groups(rows: rows).first)
        let categories = compact.nodes.filter { $0.stage == .categories }
        // 60 + 25 would cross the 80 budget, so 25 groups even though the later 10 would still fit.
        #expect(categories.map(\.amount) == [60, 40])
        #expect(categories.first?.colorID == dominant.id)
        #expect(categories.last?.id == compact.currency + "/other")
        #expect(compact.nodes.contains { $0.colorID == crossing.id } == false)
        #expect(compact.nodes.contains { $0.colorID == wouldFit.id } == false)
        #expect(compact.nodes.contains { $0.colorID == tail.id } == false)
    }

    @Test("A category above 80% alone is still shown and everything else groups")
    func dominantAloneIsShownAndRestGrouped() throws {
        let dominant = PropertyCategoryComponent(id: UUID(), name: "Dominant")
        let rows = [row(90, path: [dominant]), row(5, path: [.init(id: UUID(), name: "Small A")]), row(5, path: [.init(id: UUID(), name: "Small B")])]
        let compact = try #require(PropertyExpenseFlow.groups(rows: rows).first)
        let categories = compact.nodes.filter { $0.stage == .categories }
        // 90 alone crosses the 80 budget; the owner's exception still shows it.
        #expect(categories.map(\.amount) == [90, 10])
        #expect(categories.first?.colorID == dominant.id)
        #expect(categories.last?.id == compact.currency + "/other")
        #expect(compact.canExpand)
        let expanded = try #require(PropertyExpenseFlow.groups(rows: rows, expanded: true).first)
        #expect(expanded.nodes.filter { $0.stage == .categories }.map(\.amount) == [90, 5, 5])
    }

    @Test("Reaching exactly 80% keeps the category; the next one groups")
    func exactEightyBoundaryIncludesCategory() throws {
        let first = PropertyCategoryComponent(id: UUID(), name: "First")
        let boundary = PropertyCategoryComponent(id: UUID(), name: "Boundary")
        let next = PropertyCategoryComponent(id: UUID(), name: "Next")
        let rows = [row(50, path: [first]), row(30, path: [boundary]), row(20, path: [next])]
        let compact = try #require(PropertyExpenseFlow.groups(rows: rows).first)
        let categories = compact.nodes.filter { $0.stage == .categories }
        // 50 + 30 equals 100 * Decimal(string: "0.8")! exactly, which still counts as inside the budget.
        #expect(categories.map(\.amount) == [50, 30, 20])
        #expect(categories[1].colorID == boundary.id)
        #expect(categories.last?.id == compact.currency + "/other")
        #expect(categories.last?.amount == 20)
        #expect(compact.nodes.contains { $0.colorID == next.id } == false)
    }

    @Test("A single category with few details shows no Other categories and cannot expand")
    func singleCategoryWithoutOthersCannotExpand() throws {
        let root = PropertyCategoryComponent(id: UUID(), name: "Root")
        let rows = [row(10, path: [root, .init(id: UUID(), name: "Detail A")]), row(5, path: [root, .init(id: UUID(), name: "Detail B")])]
        let compact = try #require(PropertyExpenseFlow.groups(rows: rows).first)
        // 15 alone crosses its own 12 budget, but with nothing to group there is no Others node.
        #expect(compact.nodes.filter { $0.stage == .categories }.count == 1)
        #expect(compact.nodes.contains { $0.name == String(localized: "Other categories") } == false)
        #expect(compact.canExpand == false)
        #expect(PropertyExpenseFlow.groups(rows: rows, expanded: true) == [compact])
    }

    @Test("A single category with many details still expands through Other subcategories")
    func singleCategoryWithManySubcategoriesStillExpands() throws {
        let root = PropertyCategoryComponent(id: UUID(), name: "Root")
        let rows = [4, 3, 2, 1].map { row(Decimal($0), path: [root, .init(id: UUID(), name: "Detail \($0)")]) }
        let compact = try #require(PropertyExpenseFlow.groups(rows: rows).first)
        #expect(compact.nodes.filter { $0.stage == .categories }.count == 1)
        #expect(compact.nodes.contains { $0.name == String(localized: "Other categories") } == false)
        // "See all" stays available because the expansion reason is subcategory collapse.
        #expect(compact.canExpand)
        let rootID = try #require(compact.nodes.first { $0.stage == .categories }?.id)
        let details = compact.nodes.filter { $0.parentID == rootID }
        #expect(details.map(\.amount) == [4, 3, 3])
        #expect(details.last?.name == String(localized: "Other subcategories"))
        #expect(PropertyExpenseFlow.groups(rows: rows, expanded: true).first?.canExpand == true)
    }

    @Test("The 80% budget applies per currency with each currency's own total")
    func budgetAppliesPerCurrencyIndependently() throws {
        var rows = [50, 30, 10, 10].map { row(Decimal($0), path: [PropertyCategoryComponent(id: UUID(), name: "MXN \($0)")]) }
        for expense in [500, 300, 200].map({ row(Decimal($0), path: [PropertyCategoryComponent(id: UUID(), name: "USD \($0)")]) }) {
            var foreign = expense; foreign.currency = "USD"; rows.append(foreign)
        }
        let groups = PropertyExpenseFlow.groups(rows: rows)
        #expect(groups.map(\.currency) == ["MXN", "USD"])
        let mxnCategories = try #require(groups.first { $0.currency == "MXN" }).nodes.filter { $0.stage == .categories }
        let usdCategories = try #require(groups.first { $0.currency == "USD" }).nodes.filter { $0.stage == .categories }
        // MXN keeps 80 of 100; USD keeps 800 of 1000 — each budget comes from its own total.
        #expect(mxnCategories.map(\.amount) == [50, 30, 20])
        #expect(usdCategories.map(\.amount) == [500, 300, 200])
        #expect(mxnCategories.last?.id == "MXN/other" && usdCategories.last?.id == "USD/other")
        #expect(mxnCategories.dropLast().reduce(Decimal.zero) { $0 + $1.amount } == 80)
        #expect(usdCategories.dropLast().reduce(Decimal.zero) { $0 + $1.amount } == 800)
    }

    @Test("Totals, contributors and total-to-category links are identical across presentations")
    func totalsContributionsAndLinksMatchAcrossPresentations() throws {
        let roots = (0..<3).map { PropertyCategoryComponent(id: UUID(), name: "Category \($0)") }
        let rows = [60, 25, 15].enumerated().map { index, amount in row(Decimal(amount), path: [roots[index]]) }
        let members: [PropertyExpenseFlow.Contributor] = [.init(id: firstID, name: "First", share: 0.6), .init(id: secondID, name: "Second", share: 0.4)]
        let compact = try #require(PropertyExpenseFlow.groups(rows: rows, contributors: members).first)
        let expanded = try #require(PropertyExpenseFlow.groups(rows: rows, contributors: members, expanded: true).first)
        #expect(compact.total == expanded.total)
        #expect(compact.nodes.filter { $0.stage == .contributors } == expanded.nodes.filter { $0.stage == .contributors })
        func categoryInflow(_ graph: PropertyExpenseFlow) -> Decimal {
            let categoryIDs = Set(graph.nodes.filter { $0.stage == .categories }.map(\.id))
            return graph.links.filter { $0.source == graph.totalID && categoryIDs.contains($0.target) }.reduce(Decimal.zero) { $0 + $1.amount }
        }
        let inflow = categoryInflow(compact)
        #expect(inflow == categoryInflow(expanded))
        #expect(inflow == compact.total)
        // Every real category keeps its exact incoming amount in both presentations.
        for link in compact.links where link.target.hasPrefix(compact.currency + "/category/") {
            #expect(expanded.links.contains(link))
        }
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
