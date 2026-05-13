import SwiftUI

/// The single backdrop the whole app renders over. A static 3x3 MeshGradient
/// with cool deep blue in the top half and warm soft amber in the bottom,
/// adapted for light/dark via `Color(light:dark:)`. Glass surfaces refract
/// this scene; without it the existing `.glassEffect` renders as flat
/// translucent gray.
///
/// Tone is tuned to NOT compete with the category colors used in the spending
/// donut — saturation is intentionally low. Light mode is paler; dark mode is
/// deeper.
struct AppBackdrop: View {
    var body: some View {
        MeshGradient(
            width: 3,
            height: 3,
            points: [
                .init(0.0, 0.0), .init(0.5, 0.0), .init(1.0, 0.0),
                .init(0.0, 0.5), .init(0.5, 0.5), .init(1.0, 0.5),
                .init(0.0, 1.0), .init(0.5, 1.0), .init(1.0, 1.0),
            ],
            colors: [
                Self.coolDeep, Self.coolMid, Self.coolDeep,
                Self.coolMid, Self.midNeutral, Self.warmMid,
                Self.warmMid, Self.warmDeep, Self.warmMid,
            ]
        )
        .ignoresSafeArea()
    }

    // Palette tuned for both color schemes. Hex values come from the design
    // proposal: cool ~ evening sky blue, warm ~ soft amber. Both modes stay
    // low-saturation so the glass refraction stays subtle.
    private static var coolDeep: Color {
        Color(light: Color(hex: "C7D5EC") ?? .blue,
              dark:  Color(hex: "1A2D4A") ?? .blue)
    }
    private static var coolMid: Color {
        Color(light: Color(hex: "DBE4F3") ?? .blue,
              dark:  Color(hex: "2A4570") ?? .blue)
    }
    private static var midNeutral: Color {
        Color(light: Color(hex: "EEEAE5") ?? .gray,
              dark:  Color(hex: "232328") ?? .gray)
    }
    private static var warmMid: Color {
        Color(light: Color(hex: "F3E5D4") ?? .orange,
              dark:  Color(hex: "4A3A28") ?? .orange)
    }
    private static var warmDeep: Color {
        Color(light: Color(hex: "ECD9BD") ?? .orange,
              dark:  Color(hex: "6B5340") ?? .orange)
    }
}

extension Color {
    /// Light/dark adaptive Color, AppKit-backed on macOS.
    init(light: Color, dark: Color) {
        #if os(macOS)
        self = Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            return NSColor(isDark ? dark : light)
        })
        #else
        self = Color(UIColor { trait in
            UIColor(trait.userInterfaceStyle == .dark ? dark : light)
        })
        #endif
    }
}
