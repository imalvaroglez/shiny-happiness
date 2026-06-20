import SwiftUI

/// The single backdrop the whole app renders over. Keep this cheap: it sits
/// behind every scrollable screen and participates in every frame.
///
/// Tone is tuned to NOT compete with the category colors used in the spending
/// donut — saturation is intentionally low. Light mode is paler; dark mode is
/// deeper.
struct AppBackdrop: View {
    var body: some View {
        LinearGradient(
            colors: [Self.coolMid, Self.midNeutral, Self.warmMid],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    // Palette tuned for both color schemes. Both modes stay low-saturation so
    // charts and category colors remain readable.
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
