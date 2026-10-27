import Foundation
import CoreGraphics

/// Rendering geometry only. Monetary totals and cumulative offsets remain Decimal.
struct PropertySankeyLayout {
    struct Placement: Identifiable {
        var node: PropertyExpenseFlow.Node
        var bar: CGRect
        var label: CGRect
        var id: String { node.id }
    }
    struct Ribbon: Identifiable {
        var link: PropertyExpenseFlow.Link
        var start: CGPoint
        var end: CGPoint
        var thickness: CGFloat
        var id: String { link.id }
    }
    var placements: [Placement]
    var ribbons: [Ribbon]
    var height: CGFloat
    static let minimumWidth: CGFloat = 720
    static func labelWidth(for width: CGFloat) -> CGFloat { min(220, max(150, width * 0.20)) }

    static func requiredHeight(graph: PropertyExpenseFlow, labelHeights: [String: CGFloat]) -> CGFloat {
        max(320, graph.stages.map { stage in
            let nodes = graph.nodes.filter { $0.stage == stage }
            return nodes.reduce(CGFloat.zero) { $0 + max(24, labelHeights[$1.id] ?? 48) } + CGFloat(max(0, nodes.count - 1)) * 12
        }.max() ?? 320)
    }

    init(graph: PropertyExpenseFlow, width: CGFloat, labelHeights: [String: CGFloat], minimumHeight: CGFloat = 320) {
        height = max(minimumHeight, Self.requiredHeight(graph: graph, labelHeights: labelHeights))
        placements = []; ribbons = []
        guard graph.total > 0 else { return }
        let labelWidth = Self.labelWidth(for: width)
        let lastX = max(0, width - labelWidth - 18)
        let columns = graph.stages.map { stage in graph.nodes.filter { $0.stage == stage } }
        func ratio(_ amount: Decimal) -> CGFloat { CGFloat(NSDecimalNumber(decimal: amount / graph.total).doubleValue) }
        func usedHeight(_ nodes: [PropertyExpenseFlow.Node], scale: CGFloat) -> CGFloat {
            nodes.reduce(CGFloat.zero) { $0 + max(labelHeights[$1.id] ?? 48, ratio($1.amount) * scale) }
                + CGFloat(max(0, nodes.count - 1)) * 12
        }
        var low: CGFloat = 0; var high = height
        for _ in 0..<48 {
            let candidate = (low + high) / 2
            if columns.allSatisfy({ usedHeight($0, scale: candidate) <= height }) { low = candidate } else { high = candidate }
        }
        let scale = low
        for (column, nodes) in columns.enumerated() {
            var y = (height - usedHeight(nodes, scale: scale)) / 2
            for node in nodes {
                let thickness = ratio(node.amount) * scale
                let labelHeight = labelHeights[node.id] ?? 48
                let slot = max(labelHeight, thickness)
                let x = CGFloat(column) * lastX / CGFloat(max(1, columns.count - 1))
                placements.append(Placement(node: node,
                    bar: CGRect(x: x, y: y + (slot - thickness) / 2, width: 12, height: thickness),
                    label: CGRect(x: x + 18, y: y + (slot - labelHeight) / 2, width: labelWidth, height: labelHeight)))
                y += slot + 12
            }
        }
        let byID = Dictionary(uniqueKeysWithValues: placements.map { ($0.id, $0) })
        var outgoing: [String: Decimal] = [:]; var incoming: [String: Decimal] = [:]
        for link in graph.links {
            guard let source = byID[link.source], let target = byID[link.target] else { continue }
            let from = outgoing[link.source, default: 0]; let to = incoming[link.target, default: 0]
            ribbons.append(Ribbon(link: link,
                start: CGPoint(x: source.bar.maxX, y: source.bar.minY + ratio(from) * scale),
                end: CGPoint(x: target.bar.minX, y: target.bar.minY + ratio(to) * scale),
                thickness: ratio(link.amount) * scale))
            outgoing[link.source] = from + link.amount; incoming[link.target] = to + link.amount
        }
    }
}
