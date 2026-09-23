import Testing
import Foundation
import SwiftData
@testable import FinanceTracker

/// Ciclo 4 (TDD): conciliación MSI — reconciliar ANTES de sumar (spec G.4).
/// Neutraliza el original solo con correspondencia inequívoca; disputado fuera del firme;
/// candidatos por signo y función primero; historial completo hasta la fecha de evaluación.
@Suite("Promotion MSI Reconciliation")
@MainActor
struct PromotionMsiReconciliationTests {

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

    /// Umbral $100k, ventana 1–15 sep 2026, alcance abierto, MSI contarPublicadas.
    private func msiDef(id: String = "msi-promo", account: Account, window: PromotionDefinition.PromotionWindow =
                            .fixed(start: "2026-09-01", end: "2026-09-15", provenance: "test"),
                        msi: MsiPolicy = MsiPolicy(kind: .countPostedInstallments,
                                                   reversalPatterns: ["(?i)MONTO A DIFERIR", "(?i)MESES EN AUTOMÁTICO"],
                                                   conversionRiskThreshold: 6_000)) -> PromotionDefinition {
        PromotionDefinition(id: id, displayName: "MSI Promo", accountUUID: account.id,
                            authoringNickname: nil, window: window,
                            shape: .spendThreshold(target: 100_000, reward: 15_000),
                            scope: PromotionScope(currency: "MXN", merchants: [], requireChannel: .any,
                                                  excludeFees: true, excludeThirdParties: false),
                            refundPolicy: RefundPolicy(kind: .subtract),
                            msiPolicy: msi,
                            reward: RewardSpec(expectedAmount: 15_000, descriptorPatterns: []),
                            knownUnknowns: [])
    }

    private func run(_ def: PromotionDefinition, _ context: ModelContext, txs: [Transaction],
                     asOf: Date) -> PromotionProgress {
        let account = txs.first?.account ?? Account(institution: "X", type: .creditCard)
        return PromotionEvaluator().evaluate(definitions: [def], account: account,
                                             transactions: txs, channelTable: ChannelTable(entries: []),
                                             asOf: asOf).first!
    }

    private func tx(_ context: ModelContext, _ account: Account, day: Int, amount: Decimal,
                    descriptor: String, merchant: String = "",
                    ccpCategory: FinanceTracker.Category? = nil) -> Transaction {
        let t = Transaction(account: account, postedAt: date(2026, 9, day), amount: amount,
                            descriptionRaw: descriptor, merchantNormalized: merchant, category: ccpCategory)
        context.insert(t)
        return t
    }

    @Test("Correspondencia inequívoca neutraliza el original aunque la reversión viva como CCP")
    func unambiguousReversalNeutralizesOriginal() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(institution: "American Express Mexico", type: .creditCard)
        context.insert(account)
        let ccp = FinanceTracker.Category(name: "Credit Card Payments", kind: .creditCardPayment)
        context.insert(ccp)

        let original = tx(context, account, day: 10, amount: -8_000, descriptor: "MUEBLES XL", merchant: "Muebles")
        let cuota = tx(context, account, day: 11, amount: -2_666.67,
                       descriptor: "MESES EN AUTOMÁTICO: MUEBLES 1/3")
        // Reversión FUERA de la ventana (20-sep > fin 15-sep) y categorizada CCP:
        // el conjunto de conciliación es el historial completo hasta asOf (spec v3-d).
        let reversal = tx(context, account, day: 20, amount: 8_000,
                          descriptor: "MONTO A DIFERIR MESES EN AUTOMÁTICO", merchant: "Muebles", ccpCategory: ccp)

        let progress = run(msiDef(account: account), context,
                           txs: [original, cuota, reversal], asOf: date(2026, 9, 30))

        func outcome(_ t: Transaction) -> PromotionProgress.RowOutcome {
            progress.rows.first { $0.transactionID == t.id }!
        }
        #expect(outcome(original).outcome == .excluded,
                "El original conciliado se neutraliza — cuentan solo las cuotas publicadas")
        #expect(outcome(original).reason.contains("conciliad"))
        #expect(progress.reconciliations.first?.amountApplied == 8_000)
        #expect(outcome(cuota).outcome == .eligible,
                "La cuota publicada en ventana cuenta firme (doctrina resuelta)")
        #expect(outcome(reversal).outcome == .evidence)
        #expect(progress.eligibleFirm == 2_666.67,
                "firm = solo la cuota; el original neutralizado no suma (antes: doble conteo ~2×)")
    }

    @Test("Dos compras del mismo importe con una reversión: disputa → ambas fuera del firme")
    func ambiguousReversalDisputesBothOriginals() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(institution: "American Express Mexico", type: .creditCard)
        context.insert(account)

        let a = tx(context, account, day: 10, amount: -8_000, descriptor: "MUEBLES XL")
        let b = tx(context, account, day: 12, amount: -8_000, descriptor: "SILLA GAMER")
        let reversal = tx(context, account, day: 20, amount: 8_000,
                          descriptor: "MONTO A DIFERIR MESES EN AUTOMÁTICO")

        let progress = run(msiDef(account: account), context, txs: [a, b, reversal],
                           asOf: date(2026, 9, 30))

        func outcome(_ t: Transaction) -> PromotionProgress.RowOutcome {
            progress.rows.first { $0.transactionID == t.id }!
        }
        #expect(outcome(a).outcome == .review(direction: .couldAdd),
                "Disputa no se resuelve por adivinanza — clase ③ con dirección")
        #expect(outcome(b).outcome == .review(direction: .couldAdd))
        #expect(progress.eligibleFirm == 0, "Las contribuciones disputadas salen del firme")
    }

    @Test("«Amazon MSI» negativo es cargo probable-cuota (review), jamás consumido como reversión")
    func amazonMsiChargeIsNeverAReversal() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(institution: "American Express Mexico", type: .creditCard)
        context.insert(account)

        let cargo = tx(context, account, day: 10, amount: -1_333.56, descriptor: "Amazon MSI")
        let credito = tx(context, account, day: 12, amount: 1_333.56, descriptor: "Amazon MSI")

        let progress = run(msiDef(account: account), context, txs: [cargo, credito],
                           asOf: date(2026, 9, 30))

        func outcome(_ t: Transaction) -> PromotionProgress.RowOutcome {
            progress.rows.first { $0.transactionID == t.id }!
        }
        #expect(outcome(cargo).outcome == .review(direction: .couldAdd),
                "Cargo probable-cuota sin contador → por revisar, no firme (corrige a promo.py)")
        #expect(outcome(credito).outcome == .evidence)
        #expect(progress.eligibleFirm == 0)
    }

    @Test("Política MSI: excludeAll excluye cuotas; uncertain las manda a revisar")
    func msiPolicies() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(institution: "American Express Mexico", type: .creditCard)
        context.insert(account)

        let cuota = tx(context, account, day: 11, amount: -2_666.67,
                       descriptor: "MESES EN AUTOMÁTICO: VERSA 2/3")

        func runWith(_ kind: MsiPolicy.Kind) -> PromotionProgress {
            run(msiDef(account: account,
                       msi: MsiPolicy(kind: kind, reversalPatterns: ["(?i)MONTO A DIFERIR"],
                                      conversionRiskThreshold: nil)),
                context, txs: [cuota], asOf: date(2026, 9, 30))
        }
        #expect(runWith(.countPostedInstallments).rows.first?.outcome == .eligible)
        #expect(runWith(.excludeAll).rows.first?.outcome == .excluded)
        #expect(runWith(.uncertain).rows.first?.outcome == .review(direction: .couldAdd))
    }

    @Test("Cargo nacional ≥ umbral se señala como riesgo de conversión sin descontar del firme")
    func conversionRiskFlaggedWithoutDiscount() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(institution: "American Express Mexico", type: .creditCard)
        context.insert(account)

        let big = tx(context, account, day: 10, amount: -31_674, descriptor: "AEROMEXICO BOLETO")

        let progress = run(msiDef(account: account), context, txs: [big], asOf: date(2026, 9, 30))
        #expect(progress.rows.first?.outcome == .eligible,
                "El riesgo NO se descuenta del firme (doctrina promo.py)")
        #expect(progress.eligibleFirm == 31_674)
        #expect(progress.conversionRisks.count == 1, "Pero se señala visible")
        #expect(progress.conversionRisks.first?.transactionID == big.id)
    }

    @Test("Duplicados, cuotas fuera de ventana, moneda distinta y movimientos futuros no se reactivan")
    func invalidRowsStayExcludedBeforeInstallmentPolicy() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(institution: "American Express Mexico", type: .creditCard)
        context.insert(account)
        let duplicate = tx(context, account, day: 10, amount: -500, descriptor: "MSI 1/3")
        duplicate.isDuplicate = true
        let outside = tx(context, account, day: 20, amount: -600, descriptor: "MSI 1/3")
        let foreign = tx(context, account, day: 10, amount: -700, descriptor: "MSI 1/3")
        foreign.currency = "USD"
        let future = tx(context, account, day: 14, amount: -800, descriptor: "COMPRA FUTURA")

        let progress = run(msiDef(account: account), context, txs: [duplicate, outside, foreign, future],
                           asOf: date(2026, 9, 12))
        #expect(progress.eligibleFirm == 0)
        #expect(progress.rows.first { $0.transactionID == duplicate.id }?.reason == "duplicado")
        #expect(!progress.rows.contains { $0.transactionID == outside.id },
                "Las transacciones posteriores a asOf no entran en el cálculo ni en las filas")
        #expect(progress.rows.first { $0.transactionID == foreign.id }?.outcome == .excluded)
        #expect(!progress.rows.contains { $0.transactionID == future.id })
    }

    @Test("El crédito anterior no concilia ni consume una compra posterior")
    func creditBeforeChargeDoesNotReconcile() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(institution: "American Express Mexico", type: .creditCard)
        context.insert(account)
        let credit = tx(context, account, day: 9, amount: 8_000,
                        descriptor: "MONTO A DIFERIR", merchant: "Muebles")
        let charge = tx(context, account, day: 10, amount: -8_000,
                        descriptor: "COMPRA MUEBLES", merchant: "Muebles")
        let progress = run(msiDef(account: account), context, txs: [charge, credit], asOf: date(2026, 9, 30))
        #expect(progress.eligibleFirm == 8_000)
        #expect(progress.reconciliations.first?.status == .unmatched)
    }

    @Test("Original fuera de ventana sigue disponible para conciliar MSI")
    func originalOutsidePromotionWindowCanReconcile() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(institution: "American Express Mexico", type: .creditCard)
        context.insert(account)
        let original = tx(context, account, day: 5, amount: -8_000,
                          descriptor: "COMPRA MUEBLES", merchant: "Muebles")
        let reversal = tx(context, account, day: 20, amount: 8_000,
                          descriptor: "MONTO A DIFERIR", merchant: "Muebles")
        let def = msiDef(account: account, window: .fixed(start: "2026-09-10", end: "2026-09-15", provenance: "test"))
        let progress = run(def, context, txs: [original, reversal], asOf: date(2026, 9, 30))
        #expect(progress.reconciliations.first?.status == .matched)
        #expect(progress.rows.first { $0.transactionID == original.id }?.outcome == .excluded)
    }

    @Test("Promotions input order cannot change per-promotion reconciliation")
    func promotionOrderIsStable() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(institution: "American Express Mexico", type: .creditCard)
        context.insert(account)
        let charge = tx(context, account, day: 10, amount: -8_000,
                        descriptor: "COMPRA MUEBLES", merchant: "Muebles")
        let credit = tx(context, account, day: 20, amount: 8_000,
                        descriptor: "MONTO A DIFERIR", merchant: "Muebles")
        let first = msiDef(id: "first", account: account)
        let second = msiDef(id: "second", account: account)
        func evaluate(_ definitions: [PromotionDefinition]) -> [String: PromotionProgress] {
            Dictionary(uniqueKeysWithValues: PromotionEvaluator().evaluate(definitions: definitions,
                account: account, transactions: [credit, charge], channelTable: ChannelTable(entries: []),
                asOf: date(2026, 9, 30)).map { ($0.definitionID, $0) })
        }
        let forward = evaluate([first, second])
        let reverse = evaluate([second, first])
        #expect(forward == reverse)
    }

    @Test("Reversión marcada duplicada no concilia el cargo")
    func duplicateReversalCannotReconcile() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(institution: "American Express Mexico", type: .creditCard)
        context.insert(account)
        let charge = tx(context, account, day: 10, amount: -8_000,
                        descriptor: "COMPRA MUEBLES", merchant: "Muebles")
        let duplicate = tx(context, account, day: 20, amount: 8_000,
                           descriptor: "MONTO A DIFERIR", merchant: "Muebles")
        duplicate.isDuplicate = true
        let progress = run(msiDef(account: account), context, txs: [charge, duplicate],
                           asOf: date(2026, 9, 30))
        #expect(progress.eligibleFirm == 8_000)
        #expect(progress.reconciliations.isEmpty)
        #expect(progress.rows.first { $0.transactionID == duplicate.id }?.outcome == .excluded)
    }

    @Test("El orden de entrada no cambia el resultado ni la conciliación")
    func inputOrderDoesNotChangeResult() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(institution: "American Express Mexico", type: .creditCard)
        context.insert(account)
        let charge = tx(context, account, day: 10, amount: -8_000,
                        descriptor: "COMPRA MUEBLES", merchant: "Muebles")
        let credit = tx(context, account, day: 20, amount: 8_000,
                        descriptor: "MONTO A DIFERIR", merchant: "Muebles")
        let def = msiDef(account: account)
        let a = run(def, context, txs: [charge, credit], asOf: date(2026, 9, 30))
        let b = run(def, context, txs: [credit, charge], asOf: date(2026, 9, 30))
        #expect(a.eligibleFirm == b.eligibleFirm)
        #expect(a.reconciliations == b.reconciliations)
    }
}
