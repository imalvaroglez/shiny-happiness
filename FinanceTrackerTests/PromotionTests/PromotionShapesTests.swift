import Testing
import Foundation
import SwiftData
@testable import FinanceTracker

/// Ciclo 6 (TDD): formas matemáticas + estados (spec D/G-estados + v4-g suspensión).
/// Umbral alcanzado SOLO «según registros» y sin ambigüedad decisiva; periodos sin arrastre;
/// tope anual acota por periodo; devengo con tope; todo recomputado (nada congelado).
@Suite("Promotion Shapes & States")
@MainActor
struct PromotionShapesTests {

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

    private func makeAccount(_ context: ModelContext) -> Account {
        let a = Account(institution: "American Express Mexico", type: .creditCard)
        context.insert(a)
        return a
    }

    private func insertTx(_ context: ModelContext, _ account: Account,
                          day: Int, amount: Decimal, descriptor: String = "COMPRA") -> Transaction {
        let t = Transaction(account: account, postedAt: date(2026, 9, day),
                            amount: amount, descriptionRaw: descriptor)
        context.insert(t)
        return t
    }

    private func run(_ context: ModelContext, def: PromotionDefinition, txs: [Transaction],
                     asOf: Date) -> PromotionProgress {
        let account = txs.first?.account ?? Account(institution: "X", type: .creditCard)
        return PromotionEvaluator().evaluate(definitions: [def], account: account,
                                             transactions: txs, channelTable: ChannelTable(entries: [
                                                .init(pattern: "(?i)UBER EATS", merchantID: nil, channel: .aggregator),
                                             ]),
                                             asOf: asOf).first!
    }

    private func thresholdDef(account: Account, target: Decimal, assumptions: [String] = []) -> PromotionDefinition {
        PromotionDefinition(id: "t", displayName: "T", accountUUID: account.id, authoringNickname: nil,
                            window: .fixed(start: "2026-09-01", end: "2026-09-15", provenance: "test"),
                            shape: .spendThreshold(target: target, reward: 15_000),
                            scope: PromotionScope(currency: "MXN", merchants: [], requireChannel: .any,
                                                  excludeFees: true, excludeThirdParties: false),
                            refundPolicy: RefundPolicy(kind: .subtract),
                            msiPolicy: MsiPolicy(kind: .countPostedInstallments,
                                                 reversalPatterns: [], conversionRiskThreshold: nil),
                            reward: RewardSpec(expectedAmount: 15_000, descriptorPatterns: []),
                            knownUnknowns: assumptions)
    }

    // MARK: Umbral en ventana

    @Test("Umbral cruzado sin ambigüedad → alcanzado según registros; falta/días correctos")
    func thresholdReached() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = makeAccount(context)
        let txs = [insertTx(context, account, day: 10, amount: -5_100)]

        let p = run(context, def: thresholdDef(account: account, target: 5_000),
                    txs: txs, asOf: date(2026, 9, 10))
        #expect(p.displayState == .thresholdReachedPerRecords)
        guard case .spendThreshold(let target, let remaining) = p.shapeSummary else {
            Issue.record("summary inesperado"); return }
        #expect(target == 5_000)
        #expect(remaining == 0)
        #expect(p.daysRemaining == 5, "10→15 sep, contra fecha de evaluación (no la última tx)")
        #expect(p.campaignPhase == .active)
        #expect(p.currentGoalReached)
        #expect(p.deadlineDate == date(2026, 9, 15))
        #expect(p.deadlineDisplayText == "15 sep (quedan 5 días)")
    }

    @Test("Umbral NO cruzado → en curso con restante")
    func thresholdNotReached() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = makeAccount(context)
        let txs = [insertTx(context, account, day: 10, amount: -4_900)]

        let p = run(context, def: thresholdDef(account: account, target: 5_000),
                    txs: txs, asOf: date(2026, 9, 10))
        #expect(p.displayState == .enCurso)
        guard case .spendThreshold(_, let remaining) = p.shapeSummary else { return }
        #expect(remaining == 100)
    }

    @Test("Los supuestos degradan el estado y nunca se afirma umbral alcanzado")
    func assumptionsProduceEstimate() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = makeAccount(context)
        let txs = [insertTx(context, account, day: 10, amount: -5_100)]
        let p = run(context, def: thresholdDef(account: account, target: 5_000,
            assumptions: ["fecha de publicación aproximada a facturación"]),
            txs: txs, asOf: date(2026, 9, 10))
        #expect(p.displayState == .estimated)
        #expect(p.displayState != .thresholdReachedPerRecords)
        #expect(!p.currentGoalReached)
    }

    @Test("Suspensión v4-g: $5,100 firme + refund ambiguo $300 vs umbral $5,000")
    func thresholdSuspendedByAmbiguity() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = makeAccount(context)
        let txs = [
            insertTx(context, account, day: 10, amount: -4_500, descriptor: "COMPRA GRANDE"),
            insertTx(context, account, day: 11, amount: -300, descriptor: "TIENDA"),
            insertTx(context, account, day: 12, amount: -300, descriptor: "TIENDA"),
            insertTx(context, account, day: 13, amount: 300, descriptor: "TIENDA"),
        ]
        let p = run(context, def: thresholdDef(account: account, target: 5_000),
                    txs: txs, asOf: date(2026, 9, 14))
        #expect(p.eligibleFirm == 5_100)
        #expect(p.possibleNegativeAdjustment == 300)
        #expect(p.displayState == .thresholdSuspended,
                "La ambigüedad pendiente puede cambiar el desenlace → NO «alcanzado»")
        #expect(!p.currentGoalReached)
    }

    @Test("Ventana cerrada: expirada con resultado final salvo datos tardíos")
    func windowClosed() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = makeAccount(context)
        let txs = [insertTx(context, account, day: 10, amount: -6_000)]

        let p = run(context, def: thresholdDef(account: account, target: 5_000),
                    txs: txs, asOf: date(2026, 9, 20))
        #expect(p.displayState == .expired(reachedPerRecords: true))
        #expect(p.daysRemaining == nil)
        #expect(p.campaignPhase == .finished)
        #expect(p.campaignEndDate == date(2026, 9, 15))
        #expect(p.deadlineDate == date(2026, 9, 15))
        #expect(!p.currentGoalReached)

        // Dato tardío en periodo cerrado: se reintegra (final salvo tardíos, nunca congelado)
        let late = insertTx(context, account, day: 5, amount: -1_000)
        let p2 = run(context, def: thresholdDef(account: account, target: 10_000),
                     txs: txs + [late], asOf: date(2026, 9, 20))
        guard case .spendThreshold(_, let remaining) = p2.shapeSummary else { return }
        #expect(remaining == 3_000, "La tx tardía dentro de ventana reintegra al cálculo")
    }

    @Test("Una promoción aún no iniciada se separa de las activas")
    func windowUpcoming() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = makeAccount(context)
        let txs = [insertTx(context, account, day: 10, amount: -1_000)]

        let p = run(context, def: thresholdDef(account: account, target: 5_000),
                    txs: txs, asOf: date(2026, 8, 31))
        #expect(p.campaignPhase == .upcoming)
        #expect(p.campaignStartDate == date(2026, 9, 1))
        #expect(p.daysRemaining == nil)
        #expect(!p.currentGoalReached)
    }

    // MARK: Cashback con tope

    @Test("Cashback: devengo = tasa × firme con tope acumulado")
    func cashbackCapMath() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = makeAccount(context)
        let def = PromotionDefinition(id: "cb", displayName: "CB", accountUUID: account.id,
                                      authoringNickname: nil,
                                      window: .fixed(start: "2026-09-01", end: "2026-09-15", provenance: "t"),
                                      shape: .cashbackCap(ratePercent: 100, cap: 3_000),
                                      scope: PromotionScope(currency: "MXN",
                                                            merchants: [MerchantEntry(id: "wmt", patterns: ["(?i)WALMART"], channel: nil)],
                                                            requireChannel: .any, excludeFees: true, excludeThirdParties: true),
                                      refundPolicy: RefundPolicy(kind: .subtract),
                                      msiPolicy: MsiPolicy(kind: .uncertain, reversalPatterns: [],
                                                           conversionRiskThreshold: nil),
                                      reward: RewardSpec(expectedAmount: 0, descriptorPatterns: []),
                                      knownUnknowns: [])

        let under = run(context, def: def,
                        txs: [insertTx(context, account, day: 10, amount: -2_000, descriptor: "WALMART SUPER")],
                        asOf: date(2026, 9, 11))
        guard case .cashback(let devengado, let cap, let capRemaining) = under.shapeSummary else {
            Issue.record("summary cashback inesperado"); return }
        #expect(devengado == 2_000)
        #expect(cap == 3_000)
        #expect(capRemaining == 1_000)
        #expect(under.displayState == .enCurso)
        #expect(!under.currentGoalReached)

        let capped = run(context, def: def,
                         txs: [insertTx(context, account, day: 10, amount: -4_000, descriptor: "WALMART SUPER")],
                         asOf: date(2026, 9, 11))
        guard case .cashback(let devengado2, _, let capRemaining2) = capped.shapeSummary else { return }
        #expect(devengado2 == 3_000, "tope acumulado alcanzado")
        #expect(capRemaining2 == 0)
        #expect(capped.currentGoalReached)
    }

    // MARK: Periodos escalonados

    private func tieredDef(account: Account, threshold: Decimal = 5_000, reward: Decimal = 1_000,
                           cap: Decimal = 4_000) -> PromotionDefinition {
        PromotionDefinition(id: "tier", displayName: "Tier", accountUUID: account.id, authoringNickname: nil,
                            window: .fixed(start: "2026-09-01", end: "2026-10-31", provenance: "t"),
                            shape: .tieredPeriods(periods: [
                                .init(start: "2026-09-01", end: "2026-09-15"),
                                .init(start: "2026-09-16", end: "2026-09-30"),
                                .init(start: "2026-10-01", end: "2026-10-31"),
                            ], threshold: threshold, reward: reward, annualCap: cap, capScope: .promoLifetime),
                            scope: PromotionScope(currency: "MXN", merchants: [], requireChannel: .any,
                                                  excludeFees: true, excludeThirdParties: false),
                            refundPolicy: RefundPolicy(kind: .subtract),
                            msiPolicy: MsiPolicy(kind: .countPostedInstallments,
                                                 reversalPatterns: [], conversionRiskThreshold: nil),
                            reward: RewardSpec(expectedAmount: reward, descriptorPatterns: []),
                            knownUnknowns: [])
    }

    @Test("Periodos: cerrado-ganado, actual, futuro; sin arrastre; devengado anual")
    func tieredPeriodsBasics() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = makeAccount(context)
        let txs = [
            insertTx(context, account, day: 10, amount: -5_200),   // P1 (1–15) ganado
            insertTx(context, account, day: 18, amount: -3_000),   // P2 (16–30) en curso
        ]
        let p = run(context, def: tieredDef(account: account), txs: txs, asOf: date(2026, 9, 22))
        guard case .tieredPeriods(let periods, let earned, let cap) = p.shapeSummary else {
            Issue.record("summary tiered inesperado"); return }
        #expect(periods.count == 3)
        #expect(periods[0].phase == .closedWon)
        #expect(periods[0].firm == 5_200)
        #expect(periods[0].rewardEarned == 1_000)
        #expect(periods[1].phase == .current)
        #expect(periods[1].firm == 3_000)
        #expect(periods[2].phase == .future)
        #expect(earned == 1_000)
        #expect(cap == 4_000)
        #expect(p.displayState == .enCurso)
        #expect(p.daysRemaining == 8, "22→30 sep (cierre del periodo actual)")
        #expect(p.deadlineDate == date(2026, 9, 30))
        #expect(p.deadlineDisplayText == "30 sep (quedan 8 días)")
        #expect(p.campaignPhase == .active)

        let reached = run(context, def: tieredDef(account: account),
                          txs: txs + [insertTx(context, account, day: 19, amount: -2_200)],
                          asOf: date(2026, 9, 22))
        #expect(reached.currentGoalReached, "El objetivo del periodo actual se distingue en verde")
    }

    @Test("Sin arrastre: lo no ganado en P1 no se arrastra a P2")
    func noCarryover() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = makeAccount(context)
        let txs = [
            insertTx(context, account, day: 10, amount: -3_000),   // P1 no ganado
            insertTx(context, account, day: 18, amount: -5_100),   // P2 ganado por sí mismo
        ]
        let p = run(context, def: tieredDef(account: account), txs: txs, asOf: date(2026, 9, 20))
        guard case .tieredPeriods(let periods, let earned, _) = p.shapeSummary else { return }
        #expect(periods[0].phase == .closedLost, "P1 cerrado sin umbral → perdido, sin arrastre")
        #expect(periods[1].phase == .current)
        #expect(earned == 0, "P2 aún abierto — el devengo del periodo en curso no se anticipa")
    }

    @Test("Tope anual acota la recompensa por periodo (reward = min(fijo, tope − ya devengado))")
    func annualCapBoundsPerPeriodReward() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = makeAccount(context)
        let txs = [
            insertTx(context, account, day: 10, amount: -5_200),   // P1 gana 1,000
            insertTx(context, account, day: 18, amount: -5_200),   // P2 ganado (cerrado por asOf)
        ]
        // P1 y P2 cerrados con asOf 5-oct; tope 1,500 → P2 cobra solo 500.
        let p = run(context, def: tieredDef(account: account, cap: 1_500),
                    txs: txs, asOf: date(2026, 10, 5))
        guard case .tieredPeriods(let periods, let earned, _) = p.shapeSummary else { return }
        #expect(periods[0].rewardEarned == 1_000)
        #expect(periods[1].rewardEarned == 500, "P2 acotado por el tope anual, no 1,000")
        #expect(earned == 1_500)
    }

    @Test("calendarYear reinicia el tope en enero según año civil CDMX")
    func calendarYearCapResets() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = makeAccount(context)
        let definition = PromotionDefinition(id: "calendar", displayName: "Calendar cap",
            accountUUID: account.id, authoringNickname: nil,
            window: .fixed(start: "2026-12-01", end: "2027-02-28", provenance: "test"),
            shape: .tieredPeriods(periods: [
                .init(start: "2026-12-01", end: "2026-12-31"),
                .init(start: "2027-01-01", end: "2027-01-31"),
            ], threshold: 5_000, reward: 1_000, annualCap: 1_000, capScope: .calendarYear),
            scope: PromotionScope(currency: "MXN", merchants: [], requireChannel: .any,
                                  excludeFees: true, excludeThirdParties: false),
            refundPolicy: RefundPolicy(kind: .subtract),
            msiPolicy: MsiPolicy(kind: .countPostedInstallments, reversalPatterns: [],
                                 conversionRiskThreshold: nil),
            reward: RewardSpec(expectedAmount: 1_000, descriptorPatterns: []), knownUnknowns: [])
        let december = Transaction(account: account, postedAt: date(2026, 12, 10),
                                   amount: -5_000, descriptionRaw: "DECEMBER")
        let january = Transaction(account: account, postedAt: date(2027, 1, 10),
                                  amount: -5_000, descriptionRaw: "JANUARY")
        context.insert(december)
        context.insert(january)
        let p = run(context, def: definition, txs: [december, january], asOf: date(2027, 2, 1))
        guard case .tieredPeriods(let periods, let earned, _) = p.shapeSummary else { return }
        #expect(periods.map(\.rewardEarned) == [1_000, 1_000])
        #expect(earned == 2_000)
    }
}
