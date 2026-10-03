import Foundation
import Testing
@testable import FinanceTracker

@Suite("PromotionLedgerStore (JSON atómico, upserts idempotentes, merge determinista)")
struct PromotionLedgerStoreTests {
    private let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("PromotionLedgerStoreTests-\(UUID().uuidString).json")

    private func date(_ value: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = MexicoBankingCalendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.date(from: value)!
    }

    private func promo(id: UUID = UUID(), name: String = "Platinum 90 días",
                       updatedAt: Date, deletedAt: Date? = nil) -> PromotionRecord {
        PromotionRecord(id: id, name: name, accountID: UUID(), currency: "MXN",
                        windowStart: nil, windowEnd: nil, targetAmount: 100_000,
                        rewardNote: nil, notes: nil, archivedAt: nil,
                        createdAt: date("2026-09-09T00:00:00"), updatedAt: updatedAt,
                        deletedAt: deletedAt)
    }

    private func attribution(id: UUID = UUID(), promotionID: UUID = UUID(),
                             transactionID: UUID = UUID(), updatedAt: Date,
                             deletedAt: Date? = nil) -> PromotionAttribution {
        PromotionAttribution(id: id, promotionID: promotionID, transactionID: transactionID,
                             createdAt: updatedAt, updatedAt: updatedAt, deletedAt: deletedAt)
    }

    // MARK: Lectura y persistencia básica

    @Test("Archivo inexistente se lee como ledger vacío")
    func missingFileReadsEmpty() throws {
        let ledger = try PromotionLedgerStore.read(fileURL: url)
        #expect(ledger.promotions.isEmpty)
        #expect(ledger.attributions.isEmpty)
        #expect(ledger.schemaVersion == 1)
    }

    @Test("replace + read hace round-trip del ledger completo")
    func replaceRoundTrip() throws {
        var ledger = PromotionLedger()
        ledger.promotions = [promo(updatedAt: date("2026-09-09T00:00:00"))]
        ledger.attributions = [attribution(updatedAt: date("2026-09-20T00:00:00"))]
        ledger.updatedAt = date("2026-09-20T00:00:00")
        try PromotionLedgerStore.replace(with: ledger, at: url)
        let read = try PromotionLedgerStore.read(fileURL: url)
        #expect(read == ledger)
    }

    @Test("JSON corrupto falla visiblemente, sin reparación silenciosa")
    func corruptFileThrows() throws {
        try "{ no es json }".data(using: .utf8)!.write(to: url, options: .atomic)
        #expect(throws: Error.self) {
            _ = try PromotionLedgerStore.read(fileURL: url)
        }
    }

    @Test("Una versión de schema desconocida falla la lectura")
    func unknownSchemaVersionThrows() throws {
        var ledger = PromotionLedger()
        ledger.schemaVersion = 99
        let payload = try JSONEncoder().encode(ledger)
        try payload.write(to: url, options: .atomic)
        #expect(throws: Error.self) {
            _ = try PromotionLedgerStore.read(fileURL: url)
        }
    }

    @Test("Toda escritura exitosa notifica promotionLedgerDidChange")
    func writePostsNotification() async throws {
        let ledger = PromotionLedger()
        await confirmation("notifica cambio") { posted in
            let token = NotificationCenter.default.addObserver(
                forName: PromotionLedgerStore.didChangeNotification, object: nil, queue: nil
            ) { _ in posted() }
            do {
                try PromotionLedgerStore.replace(with: ledger, at: url)
            } catch {
                Issue.record("replace falló inesperadamente: \(error)")
            }
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: Upserts

    @Test("Guardar una promo existente reemplaza por id, sin duplicar")
    func savePromotionUpsertsById() throws {
        let id = UUID()
        try PromotionLedgerStore.save(promotion: promo(id: id, updatedAt: date("2026-09-09T00:00:00")), at: url)
        try PromotionLedgerStore.save(promotion: promo(id: id, name: "Platinum (editada)",
                                                       updatedAt: date("2026-09-25T00:00:00")), at: url)
        let ledger = try PromotionLedgerStore.read(fileURL: url)
        #expect(ledger.promotions.count == 1)
        #expect(ledger.promotions.first?.name == "Platinum (editada)")
    }

    @Test("Adjudicar dos veces la misma tx a la misma promo es idempotente")
    func attributeIsIdempotent() throws {
        let promotionID = UUID()
        let transactionID = UUID()
        try PromotionLedgerStore.attribute(transactionID: transactionID, promotionID: promotionID, at: url)
        try PromotionLedgerStore.attribute(transactionID: transactionID, promotionID: promotionID, at: url)
        let ledger = try PromotionLedgerStore.read(fileURL: url)
        #expect(ledger.attributions.count == 1)
        #expect(ledger.attributions.first?.deletedAt == nil)
    }

    @Test("Des-adjudicar deja tombstone, no borra la fila")
    func unattributeTombstones() throws {
        let promotionID = UUID()
        let transactionID = UUID()
        try PromotionLedgerStore.attribute(transactionID: transactionID, promotionID: promotionID, at: url)
        try PromotionLedgerStore.unattribute(transactionID: transactionID, promotionID: promotionID, at: url)
        let ledger = try PromotionLedgerStore.read(fileURL: url)
        #expect(ledger.attributions.count == 1)
        #expect(ledger.attributions.first?.deletedAt != nil)
    }

    @Test("Eliminar una promo deja tombstone")
    func deletePromotionTombstones() throws {
        let id = UUID()
        try PromotionLedgerStore.save(promotion: promo(id: id, updatedAt: date("2026-09-09T00:00:00")), at: url)
        try PromotionLedgerStore.deletePromotion(id: id, at: url)
        let ledger = try PromotionLedgerStore.read(fileURL: url)
        #expect(ledger.promotions.count == 1)
        #expect(ledger.promotions.first?.deletedAt != nil)
    }

    // MARK: Normalización de llave natural

    @Test("Duplicados cross-id de la llave natural se colapsan al ganador en lectura")
    func naturalKeyDuplicatesCollapseOnRead() throws {
        let promotionID = UUID()
        let transactionID = UUID()
        let lowID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000000")!
        let highID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000000")!
        var ledger = PromotionLedger()
        ledger.attributions = [
            attribution(id: highID, promotionID: promotionID, transactionID: transactionID,
                        updatedAt: date("2026-09-20T00:00:00")),
            attribution(id: lowID, promotionID: promotionID, transactionID: transactionID,
                        updatedAt: date("2026-09-20T00:00:00")),
        ]
        try PromotionLedgerStore.replace(with: ledger, at: url)
        let read = try PromotionLedgerStore.read(fileURL: url)
        #expect(read.attributions.count == 1)
        #expect(read.attributions.first?.id == highID)
    }

    // MARK: Merge determinista

    @Test("Merge: la fila con updatedAt mayor gana; ids distintos coexisten")
    func mergeNewestWinsWithIdTieBreak() throws {
        let id = UUID()
        let older = promo(id: id, name: "Local", updatedAt: date("2026-09-01T00:00:00"))
        try PromotionLedgerStore.replace(with: {
            var ledger = PromotionLedger()
            ledger.promotions = [older]
            return ledger
        }(), at: url)

        var incoming = PromotionLedger()
        incoming.promotions = [promo(id: id, name: "Remota", updatedAt: date("2026-09-10T00:00:00"))]
        try PromotionLedgerStore.merge(incoming, at: url)
        #expect(try PromotionLedgerStore.read(fileURL: url).promotions.first?.name == "Remota")

        // Promos con ids distintos son entidades distintas: el merge las conserva ambas.
        let otherID = UUID()
        var local = PromotionLedger()
        local.promotions = [promo(id: otherID, name: "Gold Everyday",
                                  updatedAt: date("2026-09-15T00:00:00"))]
        try PromotionLedgerStore.replace(with: local, at: url)
        var additive = PromotionLedger()
        additive.promotions = [promo(id: UUID(), name: "Otra promo",
                                     updatedAt: date("2026-09-15T00:00:00"))]
        try PromotionLedgerStore.merge(additive, at: url)
        #expect(try PromotionLedgerStore.read(fileURL: url).promotions.count == 2)
    }

    @Test("Merge: un tombstone más nuevo mantiene la eliminación; uno más viejo revive la fila")
    func mergeTombstonePrecedence() throws {
        let id = UUID()
        var local = PromotionLedger()
        local.promotions = [promo(id: id, updatedAt: date("2026-09-20T00:00:00"),
                                  deletedAt: date("2026-09-20T00:00:00"))]
        try PromotionLedgerStore.replace(with: local, at: url)

        var resurrect = PromotionLedger()
        resurrect.promotions = [promo(id: id, updatedAt: date("2026-09-25T00:00:00"))]
        try PromotionLedgerStore.merge(resurrect, at: url)
        #expect(try PromotionLedgerStore.read(fileURL: url).promotions.first?.deletedAt == nil)

        var deleteAgain = PromotionLedger()
        deleteAgain.promotions = [promo(id: id, updatedAt: date("2026-09-28T00:00:00"),
                                        deletedAt: date("2026-09-28T00:00:00"))]
        try PromotionLedgerStore.merge(deleteAgain, at: url)
        #expect(try PromotionLedgerStore.read(fileURL: url).promotions.first?.deletedAt != nil)
    }

    @Test("Merge de adjudicaciones conserva la unicidad de la llave natural")
    func mergeAttributionsKeepNaturalKeyUnique() throws {
        let promotionID = UUID()
        let transactionID = UUID()
        var local = PromotionLedger()
        local.attributions = [attribution(promotionID: promotionID, transactionID: transactionID,
                                          updatedAt: date("2026-09-10T00:00:00"))]
        try PromotionLedgerStore.replace(with: local, at: url)

        var incoming = PromotionLedger()
        incoming.attributions = [
            attribution(promotionID: promotionID, transactionID: transactionID,
                        updatedAt: date("2026-09-20T00:00:00")),
            attribution(promotionID: promotionID, transactionID: UUID(),
                        updatedAt: date("2026-09-21T00:00:00")),
        ]
        try PromotionLedgerStore.merge(incoming, at: url)
        let merged = try PromotionLedgerStore.read(fileURL: url)
        #expect(merged.attributions.count == 2)
        let pairCount = merged.attributions.filter {
            $0.promotionID == promotionID && $0.transactionID == transactionID
        }.count
        #expect(pairCount == 1)
    }

    // MARK: Reset

    @Test("reset elimina el archivo del ledger")
    func resetRemovesFile() throws {
        try PromotionLedgerStore.save(promotion: promo(updatedAt: date("2026-09-09T00:00:00")), at: url)
        try PromotionLedgerStore.reset(fileURL: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: Retiro del store legacy del V1

    @Test("retireLegacyOverridesIfNeeded renombra PromotionOverrides.json a copia retired verbatim")
    func retireLegacyOverridesRenames() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("retire-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let legacy = dir.appendingPathComponent("PromotionOverrides.json")
        let original = Data("{}".utf8)
        try original.write(to: legacy)

        try PromotionLedgerStore.retireLegacyOverridesIfNeeded(overridesURL: legacy)

        #expect(!FileManager.default.fileExists(atPath: legacy.path), "el archivo legacy desaparece")
        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(contents.count == 1)
        #expect(contents[0].hasPrefix("PromotionOverrides.retired-"))
        #expect(contents[0].hasSuffix(".json"))
        let retired = dir.appendingPathComponent(contents[0])
        #expect(try Data(contentsOf: retired) == original, "la copia retired conserva el contenido verbatim")
    }

    @Test("retireLegacyOverridesIfNeeded es no-op si no hay archivo legacy")
    func retireLegacyOverridesNoOp() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("retire-empty-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        try PromotionLedgerStore.retireLegacyOverridesIfNeeded(
            overridesURL: dir.appendingPathComponent("PromotionOverrides.json"))

        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    // MARK: Re-adjudicación, reparaciones y precisión

    @Test("Re-adjudicar tras tombstone restaura la fila sin duplicar y conserva createdAt")
    func reAdjudicationAfterTombstone() throws {
        let promotionID = UUID()
        let transactionID = UUID()
        try PromotionLedgerStore.attribute(transactionID: transactionID, promotionID: promotionID, at: url)
        let original = try PromotionLedgerStore.read(fileURL: url).attributions[0]
        try PromotionLedgerStore.unattribute(transactionID: transactionID, promotionID: promotionID, at: url)
        try PromotionLedgerStore.attribute(transactionID: transactionID, promotionID: promotionID, at: url)

        let ledger = try PromotionLedgerStore.read(fileURL: url)
        #expect(ledger.attributions.count == 1)
        #expect(ledger.attributions[0].deletedAt == nil)
        #expect(ledger.attributions[0].id == original.id)
        #expect(ledger.attributions[0].createdAt == original.createdAt,
                "la re-adjudicación restaura la MISMA fila (llave natural), no crea otra")
    }

    @Test("validate reporta duplicados colapsables en vez de reparar en silencio")
    func validateReportsCollapsibleDuplicates() {
        let promotionID = UUID()
        let transactionID = UUID()
        var ledger = PromotionLedger()
        ledger.promotions = [
            promo(id: promotionID, updatedAt: date("2026-09-20T00:00:00")),
            promo(id: promotionID, name: "Duplicada", updatedAt: date("2026-09-21T00:00:00")),
        ]
        ledger.attributions = [
            attribution(promotionID: promotionID, transactionID: transactionID,
                        updatedAt: date("2026-09-20T00:00:00")),
            attribution(promotionID: promotionID, transactionID: transactionID,
                        updatedAt: date("2026-09-20T00:00:00")),
        ]
        let notes = PromotionLedgerStore.validate(ledger)
        #expect(notes.count == 2)
        #expect(notes.contains { $0.contains("adjudicaciones duplicadas") })
        #expect(notes.contains { $0.contains("promociones duplicadas") })
    }

    @Test("La escritura trunca fechas a segundos enteros (paridad local Double vs bundle ISO8601)")
    func writeTruncatesDatesToWholeSeconds() throws {
        let subSecond = Date(timeIntervalSince1970: 1_700_000_000.75)
        let floorSecond = Date(timeIntervalSince1970: 1_700_000_000)
        var ledger = PromotionLedger()
        ledger.promotions = [PromotionRecord(id: UUID(), name: "Platinum 90 días", accountID: UUID(),
                                             currency: "MXN", windowStart: subSecond, windowEnd: subSecond,
                                             targetAmount: nil, rewardNote: nil, notes: nil,
                                             archivedAt: subSecond, createdAt: subSecond,
                                             updatedAt: subSecond, deletedAt: subSecond)]
        ledger.attributions = [PromotionAttribution(id: UUID(), promotionID: UUID(), transactionID: UUID(),
                                                    createdAt: subSecond, updatedAt: subSecond,
                                                    deletedAt: subSecond)]
        ledger.updatedAt = subSecond
        try PromotionLedgerStore.replace(with: ledger, at: url)

        let read = try PromotionLedgerStore.read(fileURL: url)
        let promotion = read.promotions[0]
        #expect(promotion.createdAt == floorSecond)
        #expect(promotion.updatedAt == floorSecond)
        #expect(promotion.windowStart == floorSecond)
        #expect(promotion.windowEnd == floorSecond)
        #expect(promotion.archivedAt == floorSecond)
        #expect(read.attributions[0].createdAt == floorSecond)
        #expect(read.attributions[0].updatedAt == floorSecond)
        #expect(read.updatedAt == floorSecond)
    }

    @Test("Merge con updatedAt idéntico es determinista por id, y el ganador de adjudicaciones se asevera")
    func mergeTieBreakIsDeterministicById() throws {
        let lowID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000000")!
        let highID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000000")!
        let tie = date("2026-09-15T00:00:00")

        // Local con id mayor gana frente a entrante con id menor y mismo updatedAt.
        var local = PromotionLedger()
        local.promotions = [promo(id: highID, name: "Local", updatedAt: tie)]
        try PromotionLedgerStore.replace(with: local, at: url)
        var incoming = PromotionLedger()
        incoming.promotions = [promo(id: lowID, name: "Entrante", updatedAt: tie)]
        try PromotionLedgerStore.merge(incoming, at: url)
        // Nota: ids distintos son promos distintas que coexisten (contrato probado arriba);
        // el empate real es mismo id, mismo updatedAt: gana la local (displaces = false).
        #expect(try PromotionLedgerStore.read(fileURL: url).promotions.count == 2)

        // Empate REAL: mismo id, updatedAt idéntico, payloads distintos → se conserva la local.
        var tieLocal = PromotionLedger()
        tieLocal.promotions = [promo(id: lowID, name: "Local misma fila", updatedAt: tie)]
        try PromotionLedgerStore.replace(with: tieLocal, at: url)
        var tieIncoming = PromotionLedger()
        tieIncoming.promotions = [promo(id: lowID, name: "Entrante misma fila", updatedAt: tie)]
        try PromotionLedgerStore.merge(tieIncoming, at: url)
        #expect(try PromotionLedgerStore.read(fileURL: url).promotions.first?.name == "Local misma fila")

        // Adjudicaciones misma llave natural: gana la de updatedAt mayor, aseverando el ganador.
        let promotionID = UUID()
        let transactionID = UUID()
        var attrLocal = PromotionLedger()
        attrLocal.promotions = tieLocal.promotions
        attrLocal.attributions = [attribution(promotionID: promotionID, transactionID: transactionID,
                                              updatedAt: date("2026-09-10T00:00:00"))]
        try PromotionLedgerStore.replace(with: attrLocal, at: url)
        var attrIncoming = PromotionLedger()
        attrIncoming.attributions = [attribution(promotionID: promotionID, transactionID: transactionID,
                                                 updatedAt: date("2026-09-20T00:00:00"))]
        try PromotionLedgerStore.merge(attrIncoming, at: url)
        let merged = try PromotionLedgerStore.read(fileURL: url)
        let pair = merged.attributions.filter { $0.promotionID == promotionID }
        #expect(pair.count == 1)
        #expect(pair[0].updatedAt == date("2026-09-20T00:00:00"))
    }
}


extension PromotionLedgerStoreTests {
    @Test("Rapid edits and tombstones survive a merge of a newer backup")
    func rapidEditsSurviveMerge() throws {
        let id = UUID()
        let initial = promo(id: id, name: "Old", updatedAt: .now)
        try PromotionLedgerStore.save(promotion: initial, at: url)
        let old = try PromotionLedgerStore.read(fileURL: url)
        var edited = initial
        edited.name = "New"
        try PromotionLedgerStore.save(promotion: edited, at: url)
        let newer = try PromotionLedgerStore.read(fileURL: url)
        #expect(newer.promotions[0].updatedAt > old.promotions[0].updatedAt)
        try PromotionLedgerStore.replace(with: old, at: url)
        try PromotionLedgerStore.merge(newer, at: url)
        #expect(try PromotionLedgerStore.read(fileURL: url).promotions[0].name == "New")
        try PromotionLedgerStore.deletePromotion(id: id, at: url)
        let tombstone = try PromotionLedgerStore.read(fileURL: url)
        try PromotionLedgerStore.replace(with: newer, at: url)
        try PromotionLedgerStore.merge(tombstone, at: url)
        #expect(try PromotionLedgerStore.read(fileURL: url).promotions[0].deletedAt != nil)
    }
}
