import SwiftUI

/// Color del badge de categoría: tinte personalizado (store de
/// personalización) con fallback a la paleta automática por nombre.
/// Caché en memoria recargada con `categoryCustomizationDidChange`.
@MainActor
enum CategoryBadgeColor {
    static func color(for category: Category?) -> Color {
        guard let category else { return CategoryPalette.color(for: "") }
        if let hex = CategoryCustomizationState.shared.entry(for: category.id)?.tintHex,
           let tint = Color(hex: hex) { return tint }
        return CategoryPalette.color(for: category.name)
    }

    static func refresh() { CategoryCustomizationState.shared.refresh() }
}
