import Testing
import Foundation
import SwiftData
@testable import FinanceTracker

/// Ciclo 8 (TDD): el catálogo real del bundle carga — A vinculada a la Platinum por UUID,
/// E desvinculada (Gold inexistente) con sus 6 periodos literales; tabla de canal presente.
@Suite("Promotion Bundle Catalog")
struct PromotionBundleCatalogTests {

    @Test("El bundle entrega A vinculada y E desvinculada con 6 periodos y tabla de canal")
    func bundleCatalogLoads() throws {
        let catalog = PromotionCatalog.load(bundle: .main)
        #expect(catalog.warnings.isEmpty, "Warnings: \(catalog.warnings)")

        let platinum = try #require(catalog.definitions.first { $0.id == "amex-platinum-bienvenida-2026" })
        #expect(platinum.accountUUID == UUID(uuidString: "98635015-070A-4EB5-9050-3268FB4B49FA"))
        guard case .anchored(let start, let days, _) = platinum.window else {
            Issue.record("A debía ser anchored"); return }
        #expect(start == "2026-09-09")
        #expect(days == 90)

        let everyday = try #require(catalog.definitions.first { $0.id == "amex-gold-everyday-value" })
        #expect(everyday.accountUUID == nil, "E queda desvinculada hasta que exista la Gold (clase ①)")
        #expect(everyday.knownUnknowns.count >= 5, "knownUnknowns obligatorios declarados")
        guard case .tieredPeriods(let periods, let threshold, _, let cap, let capScope) = everyday.shape else {
            Issue.record("E debía ser tieredPeriods"); return }
        #expect(periods.count == 6)
        #expect(periods.first?.start == "2026-09-22")
        #expect(periods.last?.end == "2027-12-31")
        #expect(threshold == 5_000)
        #expect(cap == 4_000)
        #expect(capScope == .promoLifetime)

        #expect(catalog.channelTable.entries.contains { $0.pattern == "(?i)UBER EATS" })
    }

    @Test("Evaluada contra la Platinum, E es no calculable (nunca revincula por nickname)")
    func unboundEverydayIsNotCalculableAgainstPlatinum() throws {
        // Solo comprobación del vínculo a nivel definición: el evaluador ya lo testea por
        // unidad; aquí garantizamos que el JSON real no vincula E a ninguna cuenta por error.
        let catalog = PromotionCatalog.load(bundle: .main)
        let everyday = try #require(catalog.definitions.first { $0.id == "amex-gold-everyday-value" })
        #expect(everyday.accountUUID != UUID(uuidString: "98635015-070A-4EB5-9050-3268FB4B49FA"))
    }

    @Test("El progress lleva knownUnknowns y filas auto-suficientes para la UI")
    @MainActor
    func progressCarriesUIPayload() throws {
        let schema = Schema([
            Account.self, AccountBalanceSnapshot.self, Transaction.self, Statement.self,
            FinanceTracker.Category.self, CategoryRule.self, InstallmentPlan.self,
            PendingImport.self, SignRecoveryHint.self,
        ])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let account = Account(institution: "American Express Mexico", type: .creditCard)
        account.id = UUID(uuidString: "98635015-070A-4EB5-9050-3268FB4B49FA")!
        context.insert(account)
        var c = DateComponents()
        c.year = 2026; c.month = 9; c.day = 10
        c.timeZone = TimeZone(identifier: "America/Mexico_City")
        let tx = Transaction(account: account,
                             postedAt: Calendar(identifier: .gregorian).date(from: c)!,
                             amount: -1_200, descriptionRaw: "OXXO 123")
        context.insert(tx)

        let catalog = PromotionCatalog.load(bundle: .main)
        let platinum = try #require(catalog.definitions.first { $0.id == "amex-platinum-bienvenida-2026" })
        let progress = PromotionEvaluator().evaluate(definitions: [platinum], account: account,
                                                     transactions: [tx],
                                                     channelTable: catalog.channelTable,
                                                     asOf: c.date!) .first!
        #expect(progress.knownUnknowns.count == 2, "Los supuestos declarados viajan al UI")
        let row = try #require(progress.rows.first)
        #expect(row.descriptor == "OXXO 123", "Fila auto-suficiente (material fuente embebido)")
        #expect(row.amount == -1_200)
    }
}
