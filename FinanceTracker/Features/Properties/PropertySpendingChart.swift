import SwiftUI
import AppKit

struct PropertySpendingChart: View {
    let rows: [PropertyActivityRow]
    var contributors: [PropertyExpenseFlow.Contributor] = []
    @State private var expanded = false

    var body: some View {
        let groups = PropertyExpenseFlow.groups(rows: rows, contributors: contributors, expanded: expanded)
        VStack(alignment: .leading, spacing: DashboardCardTokens.sectionSpacing) {
            PropertySectionHeading(title: "Spending by Category", actionTitle: groups.contains { $0.canExpand } ? (expanded ? "Summarize" : "See all") : nil,
                action: { expanded.toggle() })
            PropertyTableCard {
                VStack(alignment: .leading, spacing: 14) {
                    if groups.isEmpty { Text("No linked expenses to chart.").foregroundStyle(.secondary) }
                    ForEach(groups) { group in PropertyCurrencyFlow(graph: group) }
                    Text("Linked expenses only. Calculated rent, collections and reimbursements are excluded.")
                        .font(.caption).foregroundStyle(.secondary)
                    let missing = PropertyActivitySummary.uniqueRows(rows).filter { $0.kind == .expense && $0.amount == nil }.count
                    if missing > 0 { Text("\(missing) amounts unavailable").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .onChange(of: rows) { expanded = false }
    }
}

private struct PropertyCurrencyFlow: View {
    let graph: PropertyExpenseFlow
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(graph.currency).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            if !graph.contributionsAvailable {
                Text("Contributions pending calculation").font(.caption).foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                PropertyWideFlow(graph: graph).frame(minWidth: PropertySankeyLayout.minimumWidth)
                PropertyCompactFlow(graph: graph)
            }
        }
    }
}

/// Measure at the minimum label width to reserve enough vertical room before layout.
/// No hover or focus state participates in this calculation.
private struct PropertyWideFlow: View {
    let graph: PropertyExpenseFlow
    private func heights(width: CGFloat) -> [String: CGFloat] {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping; paragraph.hyphenationFactor = 0
        return Dictionary(uniqueKeysWithValues: graph.nodes.map { node in
            let name = NSAttributedString(string: node.name, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .paragraphStyle: paragraph])
            let detail = NSAttributedString(string: flowDetail(node, graph: graph), attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .paragraphStyle: paragraph])
            let size = NSSize(width: width, height: .greatestFiniteMagnitude)
            let height = name.boundingRect(with: size, options: [.usesLineFragmentOrigin, .usesFontLeading]).height
                + detail.boundingRect(with: size, options: [.usesLineFragmentOrigin, .usesFontLeading]).height + 12
            return (node.id, ceil(height))
        })
    }
    var body: some View {
        let reserved = PropertySankeyLayout.requiredHeight(graph: graph, labelHeights: heights(width: 150))
        ScrollView(.vertical) {
            GeometryReader { proxy in
                let layout = PropertySankeyLayout(graph: graph, width: proxy.size.width,
                    labelHeights: heights(width: PropertySankeyLayout.labelWidth(for: proxy.size.width)), minimumHeight: reserved)
                PropertyFlowDrawing(graph: graph, layout: layout)
            }
            .frame(height: reserved)
        }
        .frame(height: min(520, reserved))
    }
}

private func flowDetail(_ node: PropertyExpenseFlow.Node, graph: PropertyExpenseFlow) -> String {
    let detail = "\(propertyMoneyText(node.amount, code: graph.currency)) · \(propertyPercentText(node.contributionShare ?? (node.amount / graph.total)))"
    return node.estimated ? String(format: String(localized: "%@ (estimated)"), detail) : detail
}

private struct FlowRibbonShape: Shape {
    var ribbon: PropertySankeyLayout.Ribbon
    func path(in rect: CGRect) -> Path {
        let a = ribbon.start; let b = ribbon.end; let h = ribbon.thickness
        let bend = (b.x - a.x) * 0.45
        return Path { path in
            path.move(to: a)
            path.addCurve(to: b, control1: CGPoint(x: a.x + bend, y: a.y), control2: CGPoint(x: b.x - bend, y: b.y))
            path.addLine(to: CGPoint(x: b.x, y: b.y + h))
            path.addCurve(to: CGPoint(x: a.x, y: a.y + h), control1: CGPoint(x: b.x - bend, y: b.y + h), control2: CGPoint(x: a.x + bend, y: a.y + h))
            path.closeSubpath()
        }
    }
}

private struct PropertyFlowDrawing: View {
    let graph: PropertyExpenseFlow
    let layout: PropertySankeyLayout
    @State private var hovered: String?
    @State private var pinned: String?
    @FocusState private var focused: String?
    private var active: String? { pinned ?? focused ?? hovered }
    private var colors: [UUID: Color] { CategoryChartPalette.colors(for: graph.paletteIDs) }
    private func color(_ id: UUID?) -> Color { id.flatMap { colors[$0] } ?? .secondary }
    private var highlighted: Set<String> { graph.highlightedLinkIDs(for: active) }
    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(layout.ribbons) { ribbon in
                FlowRibbonShape(ribbon: ribbon).fill(color(ribbon.link.colorID).opacity(highlighted.contains(ribbon.id) ? 0.24 : 0.04))
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            ForEach(layout.placements) { placement in
                Rectangle().fill(color(placement.node.colorID))
                    .frame(width: placement.bar.width, height: placement.bar.height)
                    .position(x: placement.bar.midX, y: placement.bar.midY).accessibilityHidden(true)
                Button {
                    pinned = pinned == placement.id ? nil : placement.id
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(placement.node.name).font(.system(size: 13, weight: .medium))
                        Text(flowDetail(placement.node, graph: graph)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).focused($focused, equals: placement.id)
                .onHover { hovered = $0 ? placement.id : nil }
                .help(placement.node.name + " · " + flowDetail(placement.node, graph: graph))
                .accessibilityLabel(placement.node.name).accessibilityValue(flowDetail(placement.node, graph: graph))
                .accessibilityAddTraits(pinned == placement.id ? .isSelected : [])
                .frame(width: placement.label.width, height: placement.label.height)
                .position(x: placement.label.midX, y: placement.label.midY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onExitCommand { pinned = nil; focused = nil; hovered = nil }
        .onChange(of: graph) { pinned = nil; focused = nil; hovered = nil }
    }
}

private struct PropertyCompactFlow: View {
    let graph: PropertyExpenseFlow
    @State private var pinned: String?
    @State private var hovered: String?
    @FocusState private var focused: String?
    private var highlightedNodes: Set<String> {
        let highlighted = graph.highlightedLinkIDs(for: pinned ?? focused ?? hovered)
        return Set(graph.links.filter { highlighted.contains($0.id) }.flatMap { [$0.source, $0.target] })
    }
    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(graph.nodes) { node in
                    Button { pinned = pinned == node.id ? nil : node.id } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(node.name).font(node.stage == .subcategories ? .callout : .headline)
                            Text(flowDetail(node, graph: graph)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, CGFloat(max(0, node.stage.rawValue - PropertyExpenseFlow.Stage.total.rawValue)) * 14)
                        .background(pinned == node.id ? Color.accentColor.opacity(0.10) : .clear)
                    }
                    .buttonStyle(.plain).focused($focused, equals: node.id)
                    .onHover { hovered = $0 ? node.id : nil }
                    .opacity(highlightedNodes.contains(node.id) ? 1 : 0.45)
                    .help(node.name + " · " + flowDetail(node, graph: graph))
                    .accessibilityLabel(node.name).accessibilityValue(flowDetail(node, graph: graph))
                    .accessibilityAddTraits(pinned == node.id ? .isSelected : [])
                }
            }
        }
        .frame(height: min(520, CGFloat(graph.nodes.count) * 70))
        .onExitCommand { pinned = nil; focused = nil; hovered = nil }
        .onChange(of: graph) { pinned = nil; focused = nil; hovered = nil }
    }
}

private let previewFlowContributors: [PropertyExpenseFlow.Contributor] = [
    .init(id: UUID(), name: "Integrante de ejemplo con nombre completo", share: Decimal(string: "0.9845")),
    .init(id: UUID(), name: "Segundo integrante", share: Decimal(string: "0.0155"), estimated: true)
]

private func previewFlowRows() -> [PropertyActivityRow] {
    let names = ["Alimentos y compras para la casa", "Servicios domésticos", "Conservación de espacios comunes", "Suministros", "Transporte", "Equipamiento", "Limpieza"]
    return names.enumerated().flatMap { index, name in
        let root = PropertyCategoryComponent(id: UUID(), name: name)
        return (1...5).map { detail in
            PropertyActivityRow(id: UUID(), date: .now, concept: "Compra de prueba", account: "Cuenta de prueba",
                kind: .expense, amount: Decimal((index + 1) * detail * 17), currency: "MXN", responsibility: "Shared", canAssign: true,
                isClosed: false, categoryHierarchy: .path([root, .init(id: UUID(), name: "Detalle de ejemplo con nombre completo \(detail)")]))
        }
    }
}
#Preview("Wide property spending flow") {
    PropertySpendingChart(rows: previewFlowRows(), contributors: previewFlowContributors).padding(24).frame(width: 1100).background(AppBackdrop())
        .environment(\.locale, Locale(identifier: "es-MX"))
}
#Preview("Compact property spending flow") {
    PropertySpendingChart(rows: previewFlowRows(), contributors: previewFlowContributors).padding(24).frame(width: 480).background(AppBackdrop())
        .environment(\.locale, Locale(identifier: "es-MX"))
}
#Preview("Expanded property spending flow") {
    if let graph = PropertyExpenseFlow.groups(rows: previewFlowRows(), contributors: previewFlowContributors, expanded: true).first {
        PropertyTableCard { PropertyCurrencyFlow(graph: graph) }.padding(24).frame(width: 1100).background(AppBackdrop())
            .environment(\.locale, Locale(identifier: "es-MX"))
    }
}
