import Foundation

@MainActor
final class LayoutStore {
    private var store: [String: LayoutFingerprint] = [:]

    func save(_ fingerprint: LayoutFingerprint) {
        store[fingerprint.key] = fingerprint
    }

    func query(key: String) -> LayoutFingerprint? {
        store[key]
    }

    func query(institutionHint: String) -> [LayoutFingerprint] {
        store.values.filter { $0.institutionHint == institutionHint }
    }

    func list() -> [LayoutFingerprint] {
        Array(store.values)
    }

    func remove(key: String) {
        store.removeValue(forKey: key)
    }

    func count() -> Int {
        store.count
    }
}
