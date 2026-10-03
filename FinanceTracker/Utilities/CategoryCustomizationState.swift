import Foundation
import Observation

/// Observable shared index: a color change invalidates every badge reading it,
/// and report semantics use the same immutable seed identity.
@MainActor
@Observable
final class CategoryCustomizationState {
    static let shared = CategoryCustomizationState()
    private(set) var entriesByID: [UUID: CategoryCustomization] = [:]
    private(set) var loadError: String?
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    var seedNames: [UUID: String] {
        ensureLoaded()
        return entriesByID.compactMapValues(\.seedName)
    }

    func entry(for id: UUID) -> CategoryCustomization? {
        ensureLoaded()
        return entriesByID[id]
    }

    func refresh(fileURL: URL? = nil) {
        do {
            let catalog = try CategoryCustomizationStore.read(fileURL: fileURL)
            entriesByID = Dictionary(uniqueKeysWithValues: catalog.entries.filter { $0.deletedAt == nil }.map { ($0.categoryID, $0) })
            loadError = nil
        } catch {
            // Keep the last good index if the file becomes unreadable.
            loadError = error.localizedDescription
        }
        loaded = true
    }

    private func ensureLoaded() {
        if !loaded { refresh() }
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: CategoryCustomizationStore.didChangeNotification,
            object: nil, queue: .main) { notification in
                let fileURL = notification.object as? URL
                MainActor.assumeIsolated { Self.shared.refresh(fileURL: fileURL) }
            }
    }
}

@MainActor
enum CategorySemanticIdentity {
    static func name(for category: Category) -> String {
        CategoryCustomizationState.shared.entry(for: category.id)?.seedName ?? category.name
    }

    static func matches(_ category: Category?, name: String) -> Bool {
        guard let category else { return false }
        return Self.name(for: category).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            == name.lowercased()
    }
}
