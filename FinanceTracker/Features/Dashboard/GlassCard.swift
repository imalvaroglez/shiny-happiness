import SwiftUI

/// Standardized corner radii for the app. Glass surfaces should pick a role
/// rather than hardcode a number so the visual language stays coherent.
enum GlassRadius {
    static let card: CGFloat = 12
    static let hero: CGFloat = 16
    static let sheet: CGFloat = 20
    static let chip: CGFloat = 999   // resolves to .capsule
}

/// Card primitive used everywhere a glass surface is needed. Reads
/// `\.scopedTint` from the environment and uses it for the hover specular
/// highlight and (optionally) a static identity-tinted edge.
///
/// Hover-only motion per Direction-B+A: the gradient stroke rotates while the
/// pointer is over the card; rotation pauses when the hover ends.
struct GlassCard<Content: View>: View {
    enum Role { case card, hero }

    let role: Role
    let isInteractive: Bool
    @ViewBuilder var content: () -> Content

    @Environment(\.scopedTint) private var scopedTint
    @State private var hovered = false
    private let rotation: Double = 35

    init(role: Role = .card, interactive: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.role = role
        self.isInteractive = interactive
        self.content = content
    }

    private var radius: CGFloat {
        switch role {
        case .card: return GlassRadius.card
        case .hero: return GlassRadius.hero
        }
    }

    var body: some View {
        content()
            .glassEffect(.regular, in: .rect(cornerRadius: radius))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: [
                                scopedTint.opacity(hovered ? 0.55 : 0.0),
                                scopedTint.opacity(0.0),
                                scopedTint.opacity(hovered ? 0.35 : 0.0),
                                scopedTint.opacity(0.0),
                            ]),
                            center: .center,
                            angle: .degrees(rotation)
                        ),
                        lineWidth: 1
                    )
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(scopedTint.opacity(0.10), lineWidth: 0.5)
                    .allowsHitTesting(false)
            )
            .onHover { isHovering in
                guard isInteractive else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    hovered = isHovering
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Convenience wrapper for capsule-shaped glass chips (e.g. category badges).
/// Picks up `scopedTint` for a faint border.
struct GlassChip<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @Environment(\.scopedTint) private var scopedTint

    var body: some View {
        content()
            .glassEffect(.regular, in: .capsule)
            .overlay(
                Capsule()
                    .stroke(scopedTint.opacity(0.15), lineWidth: 0.5)
                    .allowsHitTesting(false)
            )
    }
}
