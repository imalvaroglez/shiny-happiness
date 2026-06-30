import SwiftUI

/// The single backdrop the whole app renders over. Keep this cheap: it sits
/// behind every scrollable screen and participates in every frame.
///
/// Tone is tuned to NOT compete with the category colors used in the spending
/// donut — saturation is intentionally low. Light mode is paler; dark mode is
/// deeper.
struct AppBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Self.coolMid, Self.midNeutral, Self.warmMid],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [Self.accentWarm.opacity(0.45), .clear],
                center: .trailing,
                startRadius: 40,
                endRadius: 560
            )
            RadialGradient(
                colors: [Self.accentCool.opacity(0.32), .clear],
                center: .bottomLeading,
                startRadius: 20,
                endRadius: 520
            )
        }
        .ignoresSafeArea()
    }

    // Palette tuned for both color schemes. Both modes stay low-saturation so
    // charts and category colors remain readable.
    private static var coolMid: Color {
        Color(light: Color(hex: "DDE6EF") ?? .blue,
              dark:  Color(hex: "141A24") ?? .blue)
    }
    private static var midNeutral: Color {
        Color(light: Color(hex: "ECE8E3") ?? .gray,
              dark:  Color(hex: "1D1B1D") ?? .gray)
    }
    private static var warmMid: Color {
        Color(light: Color(hex: "F2E2D2") ?? .orange,
              dark:  Color(hex: "3A241A") ?? .orange)
    }
    private static var accentWarm: Color {
        Color(light: Color(hex: "F59A5B") ?? .orange,
              dark:  Color(hex: "D75A1B") ?? .orange)
    }
    private static var accentCool: Color {
        Color(light: Color(hex: "84B8D8") ?? .cyan,
              dark:  Color(hex: "235B74") ?? .cyan)
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
