import SwiftUI

/// Quiet, secondary net-worth sparkline for the hero card. No axes, no labels,
/// no chart chrome; thin stroke + very soft fill. Reads as supporting context,
/// not a standalone chart (D1). Collapses to hidden below a width threshold so
/// the hero never feels cramped on narrower layouts.
///
/// Source must match the hero metric: callers pass the **available**-net-worth
/// series (excludes retirement), not the total series (refinement #2).
struct DashboardNetWorthSparkline: View {
    let points: [NetWorthPoint]
    var tint: Color = .secondary
    var minHeight: CGFloat = 28

    /// Below this width the sparkline hides (D1 responsive guardrail).
    private let minWidth: CGFloat = 180

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width >= minWidth, points.count >= 2 {
                sparkline(in: proxy.size)
            } else {
                Color.clear
            }
        }
        .frame(height: minHeight)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func sparkline(in size: CGSize) -> some View {
        let geom = SparkGeometry(points: points)
        Canvas { context, _ in
            // Soft fill under the line.
            var fill = Path()
            fill.addLines(geom.fillPoints(in: size))
            context.fill(fill, with: .linearGradient(
                Gradient(colors: [tint.opacity(0.16), tint.opacity(0.02)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)
            ))
            // Thin stroke line.
            context.stroke(
                geom.linePath(in: size),
                with: .color(tint.opacity(0.55)),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
            )
        }
    }
}

/// Pure geometry helper — extracted so projection math is unit-testable.
struct SparkGeometry {
    let points: [NetWorthPoint]

    struct Bounds { let minX, maxX, minY, maxY: Double }

    let bounds: Bounds

    init(points: [NetWorthPoint]) {
        self.points = points
        guard !points.isEmpty else {
            self.bounds = Bounds(minX: 0, maxX: 1, minY: 0, maxY: 1)
            return
        }
        let xs = points.map { $0.month.timeIntervalSince1970 }
        let ys = points.map { ($0.balance as NSDecimalNumber).doubleValue }
        self.bounds = Bounds(
            minX: xs.min() ?? 0, maxX: xs.max() ?? 1,
            minY: ys.min() ?? 0, maxY: ys.max() ?? 0
        )
    }

    func linePath(in size: CGSize) -> Path {
        var path = Path()
        for (index, point) in points.enumerated() {
            let p = projected(point, in: size)
            if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }

    /// Line path closed down to the bottom edge, for the soft fill.
    func fillPoints(in size: CGSize) -> [CGPoint] {
        var pts = points.map { projected($0, in: size) }
        if let first = pts.first, let last = pts.last {
            pts.append(CGPoint(x: last.x, y: size.height))
            pts.append(CGPoint(x: first.x, y: size.height))
        }
        return pts
    }

    private func projected(_ point: NetWorthPoint, in size: CGSize) -> CGPoint {
        let xSpan = max(bounds.maxX - bounds.minX, 1)
        let ySpan = max(bounds.maxY - bounds.minY, 1)
        let x = CGFloat((point.month.timeIntervalSince1970 - bounds.minX) / xSpan) * size.width
        let yNorm = ((point.balance as NSDecimalNumber).doubleValue - bounds.minY) / ySpan
        // Flip Y (origin top-left).
        let y = (1 - CGFloat(yNorm)) * size.height
        return CGPoint(x: x, y: y)
    }
}
