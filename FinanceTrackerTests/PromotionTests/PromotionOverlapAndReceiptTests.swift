import Testing
import Foundation
import SwiftData
@testable import FinanceTracker

/// Ciclo 7 (TDD): solapamiento por cruce de IDs de candidatos (no intersección de regex)
/// y créditos candidatos a recibo listados SIN asignación, hasta la fecha de evaluación
/// (incluidos posteriores al cierre) — spec G (solapamiento + recibo, v2/v4-i).
@Suite("Promotion Overlap & Receipt Candidates")
@MainActor
struct PromotionOverlapAndReceiptTests {

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
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Mexico_City")!
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d
        return calendar.date(from: c)!
    }

    private var channelTable: ChannelTable {
        ChannelTable(entries: [.init(pattern: "(?i)UBER EATS", merchantID: nil, channel: .aggregator)])
    }

    private func cashback(_ id: String, account: Account, merchantPattern: String) -> PromotionDefinition {
        PromotionDefinition(id: id, displayName: id, accountUUID: account.id, authoringNickname: nil,
                            window: .fixed(start: "2026-09-01", end: "2026-09-15", provenance: "t"),
                            shape: .cashbackCap(ratePercent: 100, cap: 3_000),
                            scope: PromotionScope(currency: "MXN",
                                                  merchants: [MerchantEntry(id: "cm", patterns: [merchantPattern], channel: nil)],
                                                  requireChannel: .any, excludeFees: true, excludeThirdParties: true),
                            refundPolicy: RefundPolicy(kind: .subtract),
                            msiPolicy: MsiPolicy(kind: .uncertain, reversalPatterns: [],
                                                 conversionRiskThreshold: nil),
                            reward: RewardSpec(expectedAmount: 1_000, descriptorPatterns: ["(?i)BONIFICACI"]),
                            knownUnknowns: [])
    }

    @Test("Solapamiento: una tx candidata en dos promos se advierte en ambas (cruce de IDs)")
    func overlapDetectedViaCandidateIDCrossing() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(institution: "American Express Mexico", type: .creditCard)
        context.insert(account)
        // City Market: elegible para las DOS promos (C∩E del mundo real).
        let tx = Transaction(account: account, postedAt: date(2026, 9, 10), amount: -700,
                             descriptionRaw: "CITY MARKET POLANCO")
        context.insert(tx)

        let results = PromotionEvaluator().evaluate(
            definitions: [cashback("supermercados-legacy", account: account, merchantPattern: "(?i)CITY MARKET"),
                          cashback("everyday-value", account: account, merchantPattern: "(?i)CITY MARKET")],
            account: account, transactions: [tx],
            channelTable: channelTable, asOf: date(2026, 9, 12))

        let legacy = results.first { $0.definitionID == "supermercados-legacy" }!
        let everyday = results.first { $0.definitionID == "everyday-value" }!
        #expect(legacy.overlaps == ["everyday-value"],
                "La advertencia nombra a la otra promo — conteo único no confirmado")
        #expect(everyday.overlaps == ["supermercados-legacy"])
    }

    @Test("Sin solapamiento no hay advertencias")
    func noOverlapNoWarning() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(institution: "American Express Mexico", type: .creditCard)
        context.insert(account)
        let tx = Transaction(account: account, postedAt: date(2026, 9, 10), amount: -700,
                             descriptionRaw: "CITY MARKET POLANCO")
        context.insert(tx)

        let results = PromotionEvaluator().evaluate(
            definitions: [cashback("a", account: account, merchantPattern: "(?i)CITY MARKET"),
                          cashback("b", account: account, merchantPattern: "(?i)FARMACIA")],
            account: account, transactions: [tx],
            channelTable: channelTable, asOf: date(2026, 9, 12))
        #expect(results.allSatisfy { $0.overlaps.isEmpty })
    }

    @Test("Candidatos de recibo: listados sin asignación, hasta asOf, incluidos post-cierre")
    func receiptCandidatesListedUnassigned() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(institution: "American Express Mexico", type: .creditCard)
        context.insert(account)
        let charge = Transaction(account: account, postedAt: date(2026, 9, 10), amount: -5_100,
                                 descriptionRaw: "CITY MARKET")
        // Recompensa recibida DESPUÉS del cierre de la ventana (15-sep) — sigue siendo candidata.
        let lateReward = Transaction(account: account, postedAt: date(2026, 9, 20), amount: 1_000,
                                     descriptionRaw: "BONIFICACION EVERYDAY")
        let unrelated = Transaction(account: account, postedAt: date(2026, 9, 21), amount: 2_000,
                                    descriptionRaw: "GRACIAS POR SU PAGO")
        context.insert(charge); context.insert(lateReward); context.insert(unrelated)

        let results = PromotionEvaluator().evaluate(
            definitions: [cashback("everyday-value", account: account, merchantPattern: "(?i)CITY MARKET")],
            account: account, transactions: [charge, lateReward, unrelated],
            channelTable: channelTable, asOf: date(2026, 9, 25))

        let p = results.first!
        #expect(p.receiptCandidates.count == 1, "Solo el crédito «Bonificación» es candidato")
        #expect(p.receiptCandidates.first?.transactionID == lateReward.id)
        #expect(p.receiptCandidates.first?.amount == 1_000)
        // Sin asignación: nada marca «recibida»; el estado no cambia por el candidato.
        #expect(p.displayState == .expired(reachedPerRecords: true),
                "El devengo nace del gasto, no del crédito; el candidato NO marca «recibida» (V1: solo se lista)")
    }

    @Test("Un mismo crédito aparece como candidato en dos promos sin atribuirse a ninguna")
    func singleCreditListedEverywhereAssignedNowhere() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(institution: "American Express Mexico", type: .creditCard)
        context.insert(account)
        let chargeA = Transaction(account: account, postedAt: date(2026, 9, 10), amount: -5_100,
                                  descriptionRaw: "CITY MARKET")
        let credit = Transaction(account: account, postedAt: date(2026, 9, 12), amount: 1_000,
                                 descriptionRaw: "BONIFICACION AMEX")
        context.insert(chargeA); context.insert(credit)

        let results = PromotionEvaluator().evaluate(
            definitions: [cashback("p1", account: account, merchantPattern: "(?i)CITY MARKET"),
                          cashback("p2", account: account, merchantPattern: "(?i)CITY MARKET")],
            account: account, transactions: [chargeA, credit],
            channelTable: channelTable, asOf: date(2026, 9, 12))

        // E, F y G esperando $1,000 cada una NO pueden marcar todas «recibida» con un solo
        // abono: en V1 el crédito se lista en ambas y no se asigna a ninguna (spec G-recibo).
        for p in results {
            #expect(p.receiptCandidates.map(\.transactionID) == [credit.id])
            #expect(p.displayState == .enCurso)
        }
    }
}
