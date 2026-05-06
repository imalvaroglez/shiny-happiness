import Testing
import Foundation
@testable import FinanceTracker

@Suite("LayoutStore")
struct LayoutStoreTests {

    @MainActor
    @Test("Saves and retrieves fingerprint by key")
    func saveAndQuery() {
        let store = LayoutStore()
        let fp = LayoutFingerprint(
            institutionHint: "Openbank Mexico",
            headerPattern: "Fecha Concepto Depósito Retiro Saldo",
            layout: "grid",
            amountConvention: "split_columns",
            columnRoles: [:],
            sourceFileHash: "abc123",
            transactionCount: 42
        )

        store.save(fp)

        let retrieved = store.query(key: fp.key)
        #expect(retrieved != nil)
        #expect(retrieved?.institutionHint == "Openbank Mexico")
        #expect(retrieved?.transactionCount == 42)
        #expect(retrieved?.amountConvention == "split_columns")
    }

    @MainActor
    @Test("Queries by institution hint")
    func queryByInstitution() {
        let store = LayoutStore()
        store.save(LayoutFingerprint(
            institutionHint: "Banorte POR Ti",
            headerPattern: "Fecha Concepto Importe",
            layout: "flow",
            amountConvention: nil,
            columnRoles: [:],
            sourceFileHash: "a",
            transactionCount: 10
        ))
        store.save(LayoutFingerprint(
            institutionHint: "Banorte POR Ti",
            headerPattern: "Fecha Descripción Cargo Abono",
            layout: "grid",
            amountConvention: "split_columns",
            columnRoles: [:],
            sourceFileHash: "b",
            transactionCount: 15
        ))
        store.save(LayoutFingerprint(
            institutionHint: "Openbank Mexico",
            headerPattern: "Fecha Concepto Depósito Retiro Saldo",
            layout: "grid",
            amountConvention: "split_columns",
            columnRoles: [:],
            sourceFileHash: "c",
            transactionCount: 30
        ))

        let banorteFps = store.query(institutionHint: "Banorte POR Ti")
        #expect(banorteFps.count == 2)

        let openbankFps = store.query(institutionHint: "Openbank Mexico")
        #expect(openbankFps.count == 1)
    }

    @MainActor
    @Test("Removes fingerprint")
    func removeFingerprint() {
        let store = LayoutStore()
        let fp = LayoutFingerprint(
            institutionHint: "Test",
            headerPattern: "Header",
            layout: "flow",
            amountConvention: nil,
            columnRoles: [:],
            sourceFileHash: "x",
            transactionCount: 1
        )
        store.save(fp)
        #expect(store.count() == 1)

        store.remove(key: fp.key)
        #expect(store.count() == 0)
        #expect(store.query(key: fp.key) == nil)
    }

    @MainActor
    @Test("Lists all fingerprints")
    func listAll() {
        let store = LayoutStore()
        #expect(store.list().isEmpty)

        store.save(LayoutFingerprint(
            institutionHint: "A", headerPattern: "H1", layout: "flow",
            amountConvention: nil, columnRoles: [:], sourceFileHash: "1", transactionCount: 1
        ))
        store.save(LayoutFingerprint(
            institutionHint: "B", headerPattern: "H2", layout: "grid",
            amountConvention: "cr_suffix", columnRoles: [:], sourceFileHash: "2", transactionCount: 2
        ))

        #expect(store.list().count == 2)
    }
}
