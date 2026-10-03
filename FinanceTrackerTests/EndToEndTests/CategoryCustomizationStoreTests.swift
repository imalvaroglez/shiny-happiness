import Foundation
import Testing
@testable import FinanceTracker

@Suite("CategoryCustomizationStore (renames y tintes, JSON en Application Support)")
struct CategoryCustomizationStoreTests {
    private let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("CategoryCustomizationStoreTests-\(UUID().uuidString).json")

    private let categoryID = UUID()

    @Test("Archivo inexistente se lee como catálogo vacío")
    func missingFileReadsEmpty() throws {
        let catalog = try CategoryCustomizationStore.read(fileURL: url)
        #expect(catalog.entries.isEmpty)
        #expect(catalog.schemaVersion == 1)
    }

    @Test("setSeedName y setTint hacen upsert idempotente por categoría")
    func upsertIsIdempotentPerCategory() throws {
        try CategoryCustomizationStore.setSeedName(categoryID: categoryID, seedName: "Food & Drink", at: url)
        try CategoryCustomizationStore.setTint(categoryID: categoryID, hex: "#FF8800", at: url)
        try CategoryCustomizationStore.setTint(categoryID: categoryID, hex: "#FF8800", at: url)

        let catalog = try CategoryCustomizationStore.read(fileURL: url)
        #expect(catalog.entries.count == 1)
        #expect(catalog.entries[0].seedName == "Food & Drink")
        #expect(catalog.entries[0].tintHex == "#FF8800")
    }

    @Test("clearTint deja sin tinte sin perder el seedName")
    func clearTintKeepsSeedName() throws {
        try CategoryCustomizationStore.setSeedName(categoryID: categoryID, seedName: "Food & Drink", at: url)
        try CategoryCustomizationStore.setTint(categoryID: categoryID, hex: "#FF8800", at: url)
        try CategoryCustomizationStore.clearTint(categoryID: categoryID, at: url)

        let catalog = try CategoryCustomizationStore.read(fileURL: url)
        #expect(catalog.entries.count == 1)
        #expect(catalog.entries[0].tintHex == nil)
        #expect(catalog.entries[0].seedName == "Food & Drink")
    }

    @Test("Merge por categoría: gana updatedAt mayor y conserva el tinte del otro bando")
    func mergeKeepsNewestPerField() throws {
        let otherID = UUID()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var local = CategoryCustomizationCatalog()
        local.entries = [
            CategoryCustomization(categoryID: categoryID, seedName: "Food & Drink",
                                  tintHex: "#111111", updatedAt: base, deletedAt: nil),
        ]
        local.updatedAt = base
        try CategoryCustomizationStore.replace(with: local, at: url)

        var incoming = CategoryCustomizationCatalog()
        incoming.entries = [
            // Más nueva: reemplaza la local de la misma categoría.
            CategoryCustomization(categoryID: categoryID, seedName: "Food & Drink",
                                  tintHex: "#222222", updatedAt: base.addingTimeInterval(60),
                                  deletedAt: nil),
            // Nueva categoría: se agrega.
            CategoryCustomization(categoryID: otherID, seedName: nil,
                                  tintHex: "#333333", updatedAt: base.addingTimeInterval(30),
                                  deletedAt: nil),
        ]
        incoming.updatedAt = base.addingTimeInterval(60)
        try CategoryCustomizationStore.merge(incoming, at: url)

        let merged = try CategoryCustomizationStore.read(fileURL: url)
        #expect(merged.entries.count == 2)
        let mine = merged.entries.first { $0.categoryID == categoryID }
        #expect(mine?.tintHex == "#222222")
        #expect(merged.entries.contains { $0.categoryID == otherID })
    }

    @Test("JSON corrupto falla visiblemente")
    func corruptFileThrows() throws {
        try "{ no json }".data(using: .utf8)!.write(to: url, options: .atomic)
        #expect(throws: Error.self) {
            _ = try CategoryCustomizationStore.read(fileURL: url)
        }
    }

    @Test("Toda escritura exitosa notifica el cambio")
    func writePostsNotification() async throws {
        await confirmation("notifica cambio") { posted in
            let token = NotificationCenter.default.addObserver(
                forName: CategoryCustomizationStore.didChangeNotification, object: nil, queue: nil
            ) { _ in posted() }
            do {
                try CategoryCustomizationStore.setTint(categoryID: categoryID, hex: "#00AAFF", at: url)
            } catch {
                Issue.record("setTint falló inesperadamente: \(error)")
            }
            NotificationCenter.default.removeObserver(token)
        }
    }

    @Test("reset elimina el archivo")
    func resetRemovesFile() throws {
        try CategoryCustomizationStore.setTint(categoryID: categoryID, hex: "#00AAFF", at: url)
        try CategoryCustomizationStore.reset(fileURL: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
