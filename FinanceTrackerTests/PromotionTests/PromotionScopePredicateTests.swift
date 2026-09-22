import Testing
import Foundation
import SwiftData
@testable import FinanceTracker

/// Ciclo 3 (TDD): predicado de alcance — whitelist regex con alias, canal por tabla compartida,
/// exclusión de terceros/agregadores, default por revisar (spec G.3/H).
@Suite("Promotion Scope Predicates")
@MainActor
struct PromotionScopePredicateTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            Account.self, AccountBalanceSnapshot.self, Transaction.self,
            Statement.self,
            FinanceTracker.Category.self,
            CategoryRule.self,
            InstallmentPlan.self,
            PendingImport.self,
            SignRecoveryHint.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d
        c.timeZone = TimeZone(identifier: "America/Mexico_City")
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    private let ibmScope = PromotionScope(
        currency: "MXN",
        merchants: [MerchantEntry(id: "cafeteria-ibm",
                                  patterns: ["(?i)CAFETERIA IBM", "(?i)CAFETERÍA IBM", "(?i)CAFECITO IBM"],
                                  channel: .physical)],
        requireChannel: .any,
        excludeFees: true,
        excludeThirdParties: true)

    private func cashbackDef(account: Account, scope: PromotionScope) -> PromotionDefinition {
        PromotionDefinition(id: "scope-promo", displayName: "Scope", accountUUID: account.id,
                            authoringNickname: nil,
                            window: .fixed(start: "2026-09-01", end: "2026-09-30", provenance: "test"),
                            shape: .cashbackCap(ratePercent: 100, cap: 3_000),
                            scope: scope,
                            refundPolicy: RefundPolicy(kind: .subtract),
                            msiPolicy: MsiPolicy(kind: .uncertain, reversalPatterns: [],
                                                 conversionRiskThreshold: nil),
                            reward: RewardSpec(expectedAmount: 0, descriptorPatterns: []),
                            knownUnknowns: [])
    }

    /// Evalúa una tx por descriptor y devuelve su outcome (índice posicional = orden de descriptors).
    private func evaluateOne(scope: PromotionScope, descriptor: String,
                             channelTable: ChannelTable = ChannelTable(entries: [])) throws -> PromotionProgress.RowOutcome {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(institution: "American Express Mexico", type: .creditCard)
        context.insert(account)
        let tx = Transaction(account: account, postedAt: date(2026, 9, 10), amount: -300,
                             descriptionRaw: descriptor)
        context.insert(tx)
        let progress = PromotionEvaluator().evaluate(
            definitions: [cashbackDef(account: account, scope: scope)], account: account,
            transactions: [tx], channelTable: channelTable, asOf: .distantFuture).first!
        return progress.rows.first!
    }

    @Test("Whitelist estricta: variantes de alias elegibles, fuera de lista excluido")
    func whitelistWithAliases() throws {
        #expect(try evaluateOne(scope: ibmScope, descriptor: "Cafeteria IBM").outcome == .eligible)
        #expect(try evaluateOne(scope: ibmScope, descriptor: "CAFETERÍA IBM").outcome == .eligible)
        #expect(try evaluateOne(scope: ibmScope, descriptor: "Cafecito IBM").outcome == .eligible)
        #expect(try evaluateOne(scope: ibmScope, descriptor: "OXXO 123").outcome == .excluded,
                "Whitelist estricta: fuera de lista NO es elegible (ni review)")
    }

    @Test("Agregador por tabla compartida queda excluido cuando la promo prohíbe terceros")
    func aggregatorExcluded() throws {
        let table = ChannelTable(entries: [
            .init(pattern: "(?i)UBER EATS", merchantID: nil, channel: .aggregator),
        ])
        let row = try evaluateOne(scope: ibmScope, descriptor: "UBER EATS 123", channelTable: table)
        #expect(row.outcome == .excluded)
        #expect(row.reason.contains("tercero") == true)
    }

    @Test("Agregador cuenta como compra normal cuando la promo NO excluye terceros (bono)")
    func aggregatorCountsWhenThirdPartiesAllowed() throws {
        let table = ChannelTable(entries: [
            .init(pattern: "(?i)UBER EATS", merchantID: nil, channel: .aggregator),
        ])
        let openScope = PromotionScope(currency: "MXN", merchants: [], requireChannel: .any,
                                       excludeFees: true, excludeThirdParties: false)
        #expect(try evaluateOne(scope: openScope, descriptor: "UBER EATS 123",
                                channelTable: table).outcome == .eligible)
    }

    @Test("Canal desconocido en promo physicalOnly → por revisar (nunca 'ambos' por intuición)")
    func unknownChannelGoesToReview() throws {
        let freskoScope = PromotionScope(
            currency: "MXN",
            merchants: [MerchantEntry(id: "fresko", patterns: ["(?i)FRESKO"], channel: nil)],
            requireChannel: .physicalOnly,
            excludeFees: true,
            excludeThirdParties: true)
        let row = try evaluateOne(scope: freskoScope, descriptor: "FRESKO LA RIOJA A DOM")
        #expect(row.outcome == .review(direction: .couldAdd),
                "Descriptor que no revela canal + promo physicalOnly → clase ③, no firme")
    }

    @Test("Tabla compartida declara el canal por merchantID y lo hace firme")
    func sharedTableDeclaresChannelByMerchantID() throws {
        let freskoScope = PromotionScope(
            currency: "MXN",
            merchants: [MerchantEntry(id: "fresko", patterns: ["(?i)FRESKO"], channel: nil)],
            requireChannel: .physicalOnly,
            excludeFees: true,
            excludeThirdParties: true)
        let table = ChannelTable(entries: [
            .init(pattern: nil, merchantID: "fresko", channel: .physical),
        ])
        #expect(try evaluateOne(scope: freskoScope, descriptor: "FRESKO LA RIOJA A DOM",
                                channelTable: table).outcome == .eligible)
    }

    @Test("Canal declarado físico es firme en promo physicalOnly; declarado online excluido")
    func declaredChannelDecides() throws {
        let pharmacy = PromotionScope(
            currency: "MXN",
            merchants: [
                MerchantEntry(id: "guadalajara", patterns: ["(?i)FARMACIA GUADALAJARA"], channel: .physical),
                MerchantEntry(id: "fitsi", patterns: ["(?i)FITSI"], channel: .online),
            ],
            requireChannel: .physicalOnly,
            excludeFees: true,
            excludeThirdParties: true)
        #expect(try evaluateOne(scope: pharmacy, descriptor: "FARMACIA GUADALAJARA 001").outcome == .eligible)
        #expect(try evaluateOne(scope: pharmacy, descriptor: "FITSI APP").outcome == .excluded,
                "Comercio online-only en promo presencial → excluido")
    }
}
