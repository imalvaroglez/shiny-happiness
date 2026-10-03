import SwiftUI

/// Color del badge de categoría: tinte personalizado (store de
/// personalización) con fallback a la paleta automática por nombre.
/// Caché en memoria recargada con `categoryCustomizationDidChange`.
@MainActor
enum CategoryBadgeColor {
    private static var catalog = CategoryCustomizationCatalog()
    private static var isLoaded = false
    private static var observer: (any NSObjectProtocol)?

    static func color(for category: Category?) -> Color {
        ensureLoaded()
        guard let category else { return CategoryPalette.color(for: "") }
        if let hex = catalog.entries.first(where: { $0.categoryID == category.id })?.tintHex,
           let tint = Color(hex: hex) {
            return tint
        }
        return CategoryPalette.color(for: category.name)
    }

    static func refresh() {
        catalog = (try? CategoryCustomizationStore.read()) ?? CategoryCustomizationCatalog()
        isLoaded = true
    }

    private static func ensureLoaded() {
        if !isLoaded { refresh() }
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: CategoryCustomizationStore.didChangeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in refresh() }
        }
    }
}
