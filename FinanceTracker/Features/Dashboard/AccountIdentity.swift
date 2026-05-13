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
        if let mapped = defaultMap[account.institution] { return mapped }
        return .accentColor
    }

    /// Built-in identity colors for known issuers in this repo's sample set.
    /// Add to this map as new institutions ship; users can always override via
    /// `Account.tintHex`.
    static let defaultMap: [String: Color] = [
        "HSBC 2Now": Color(red: 0.83, green: 0.13, blue: 0.18),   // HSBC red
        "Openbank Mexico": Color(red: 0.00, green: 0.62, blue: 0.65), // Openbank teal
        "American Express Mexico": Color(red: 0.00, green: 0.43, blue: 0.79), // Amex blue
        "Banorte POR Ti": Color(red: 0.88, green: 0.16, blue: 0.20),
        "Mercado Pago": Color(red: 0.00, green: 0.45, blue: 0.94),
        "DiDi Cuenta": Color(red: 0.95, green: 0.55, blue: 0.08),
        "Skandia": Color(red: 0.20, green: 0.32, blue: 0.55),
        "CI Banco": Color(red: 0.40, green: 0.55, blue: 0.20),
        "Suburbia": Color(red: 0.85, green: 0.15, blue: 0.55),
    ]
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
