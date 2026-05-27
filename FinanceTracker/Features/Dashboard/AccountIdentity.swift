import SwiftUI

/// Identity color for an Account. Resolution order:
///   1. The user-stored `tintHex` on the Account, if set.
///   2. A built-in default keyed by institution (HSBC red, Openbank teal, …).
///   3. `Color.accentColor` as the universal fallback.
///
/// The consolidated scope uses a neutral system tint so the chrome reads as
/// "no account selected" — see `AccountIdentity.consolidated`.
enum AccountIdentity {
    /// Neutral tint used by the consolidated scope.
    static var consolidated: Color { Color(white: 0.55) }

    static func color(for account: Account?) -> Color {
        guard let account else { return consolidated }
        if let hex = account.tintHex, let c = Color(hex: hex) { return c }
        let base = defaultMap[account.institution] ?? .accentColor
        return shiftedHue(of: base, by: hueOffset(for: account.id))
    }

    static func color(for identity: DashboardAccountIdentity?) -> Color {
        guard let identity else { return consolidated }
        if let hex = identity.tintHex, let c = Color(hex: hex) { return c }
        let base = defaultMap[identity.institution] ?? .accentColor
        return shiftedHue(of: base, by: hueOffset(for: identity.id))
    }

    /// Built-in identity colors for known issuers in this repo's sample set.
    /// Add to this map as new institutions ship; users can always override via
    /// `Account.tintHex`.
    static let defaultMap: [String: Color] = [
        "HSBC 2Now": Color(red: 0.83, green: 0.13, blue: 0.18),
        "Openbank Mexico": Color(red: 0.00, green: 0.62, blue: 0.65),
        "American Express Mexico": Color(red: 0.00, green: 0.43, blue: 0.79),
        "Banorte POR Ti": Color(red: 0.88, green: 0.16, blue: 0.20),
        "Mercado Pago": Color(red: 0.00, green: 0.45, blue: 0.94),
        "DiDi Cuenta": Color(red: 0.95, green: 0.55, blue: 0.08),
        "Skandia": Color(red: 0.20, green: 0.32, blue: 0.55),
        "CI Banco": Color(red: 0.40, green: 0.55, blue: 0.20),
        "Suburbia": Color(red: 0.85, green: 0.15, blue: 0.55),
    ]

    private static func hueOffset(for id: UUID) -> Double {
        #if os(macOS)
        let byte = id.uuid.0
        let scaled = (Double(byte) / 255.0) - 0.5
        return scaled * 40
        #else
        return 0
        #endif
    }

    #if os(macOS)
    private static func shiftedHue(of color: Color, by degrees: Double) -> Color {
        let nsColor = NSColor(color).usingColorSpace(.deviceRGB) ?? .controlAccentColor
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        nsColor.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let newHue = (h + CGFloat(degrees / 360.0)).truncatingRemainder(dividingBy: 1)
        let normalized = newHue < 0 ? newHue + 1 : newHue
        return Color(nsColor: NSColor(hue: normalized, saturation: s, brightness: b, alpha: a))
    }
    #endif
}

extension Color {
    /// Parse `#RRGGBB` (or `RRGGBB`) into a Color. Returns nil for malformed input.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        self = Color(red: r, green: g, blue: b)
    }
}

// MARK: - Environment plumbing

private struct ScopedTintKey: EnvironmentKey {
    static let defaultValue: Color = AccountIdentity.consolidated
}

extension EnvironmentValues {
    /// Identity color for the currently scoped account. Consolidated scope
    /// uses the neutral system tint. Apply via `.environment(\.scopedTint, ...)`
    /// at the scope-aware view root.
    var scopedTint: Color {
        get { self[ScopedTintKey.self] }
        set { self[ScopedTintKey.self] = newValue }
    }
}
