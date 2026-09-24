import Testing
import Foundation
import SwiftData
@testable import FinanceTracker

/// Ciclo 5 (TDD): política de refunds (spec G.5 + v4-g).
/// Aplicar al cargo original; parciales/múltiples con tope = monto del cargo; post-ventana;
/// deny-list «Bonificación»; crédito MSI jamás candidato a refund; ambiguo → provisional
/// con posible ajuste negativo (suspensión de estado llega con las formas, ciclo 6).
@Suite("Promotion Refunds")
@MainActor
struct PromotionRefundTests {

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

    private func def(account: Account) -> PromotionDefinition {
        PromotionDefinition(id: "refund-promo", displayName: "Refund Promo", accountUUID: account.id,
                            authoringNickname: nil,
                            window: .fixed(start: "2026-09-01", end: "2026-09-15", provenance: "test"),
                            shape: .spendThreshold(target: 100_000, reward: 15_000),
                            scope: PromotionScope(currency: "MXN", merchants: [], requireChannel: .any,
                                                  excludeFees: true, excludeThirdParties: false),
                            refundPolicy: RefundPolicy(kind: .subtract),
                            msiPolicy: MsiPolicy(kind: .countPostedInstallments,
                                                 reversalPatterns: ["(?i)MONTO A DIFERIR"],
                                                 conversionRiskThreshold: nil),
                            reward: RewardSpec(expectedAmount: 15_000, descriptorPatterns: []),
                            knownUnknowns: [])
    }

    /// Helper: construye las tx sobre una cuenta y evalúa.
    private func run(_ context: ModelContext, account: Account,
                     txs: [(day: Int, amount: Decimal, descriptor: String)]) -> PromotionProgress {
        let created = txs.map { spec in
            let t = Transaction(account: account, postedAt: date(2026, 9, spec.day),
                                amount: spec.amount, descriptionRaw: spec.descriptor)
            context.insert(t)
            return t
        }
        return PromotionEvaluator().evaluate(definitions: [def(account: account)], account: account,
                                             transactions: created, channelTable: ChannelTable(entries: []),
                                             asOf: date(2026, 9, 30)).first!
    }

    @Test("Refund identificado aplica al cargo original aunque llegue tras el cierre")
    func identifiedRefundAppliesToOriginalCharge() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(institution: "American Express Mexico", type: .creditCard)
        context.insert(account)

        // Compra 10-sep (ventana hasta 15); reembolso 20-sep (post-cierre) alcanza al cargo.
        let progress = run(context, account: account, txs: [
            (10, -4_500, "WALMART SUPER"),
            (12, -300, "OXXO"),
            (20, 4_500, "WALMART SUPER"),  // reembolso fuera de ventana, mismo descriptor
        ])
        #expect(progress.eligibleFirm == 300,
                "El reembolso aplica a su cargo original aunque llegue tras el cierre (spec v3-d)")
        let walmartRow = progress.rows.first { $0.reason.contains("reembolso") }
        #expect(walmartRow != nil, "La fila del cargo explica el reembolso aplicado")
    }

    @Test("Reembolsos parciales y múltiples con tope = monto del cargo")
    func partialAndMultipleRefundsCappedAtChargeAmount() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(institution: "American Express Mexico", type: .creditCard)
        context.insert(account)

        // Cargo -500; tres reembolsos de +200 (total 600 > 500) → tope: solo 500 restan.
        let progress = run(context, account: account, txs: [
            (10, -500, "TIENDA XYZ"),
            (11, 200, "TIENDA XYZ"),
            (12, 200, "TIENDA XYZ"),
            (13, 200, "TIENDA XYZ"),
        ])
        #expect(progress.eligibleFirm == 0,
                "Nunca se descuenta más que el cargo asociado (600 > 500 → tope en 500, floor 0)")
    }

    @Test("Deny-list: «Bonificación X» jamás es candidato a reembolso (es recompensa)")
    func bonificacionIsNeverARefund() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(institution: "American Express Mexico", type: .creditCard)
        context.insert(account)

        let progress = run(context, account: account, txs: [
            (10, -150, "WALMART"),
            (11, -4_500, "WALMART SUPER"),
            (14, 150, "BONIFICACION WALMART SUPER"),  // recompensa, no reembolso
        ])
        #expect(progress.eligibleFirm == 4_650,
                "El crédito «Bonificación» no resta del avance (colisión real de descriptores)")
    }

    @Test("Crédito de reversión MSI consumido por conciliación jamás es candidato a refund")
    func msiCreditNeverBecomesRefund() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(institution: "American Express Mexico", type: .creditCard)
        context.insert(account)

        // Original -8000 neutralizado por su reversión; el MISMO crédito no puede además
        // "reembolsar" otra compra de otro importe, y el original ya no cuenta.
        let progress = run(context, account: account, txs: [
            (10, -8_000, "MUEBLES XL"),
            (11, -2_666.67, "MESES EN AUTOMÁTICO: MUEBLES 1/3"),
            (20, 8_000, "MONTO A DIFERIR MESES EN AUTOMÁTICO"),
            (12, -1_000, "SILLA"),
        ])
        #expect(progress.eligibleFirm == 2_666.67 + 1_000,
                "La reversión se consume una sola vez (arbitraje MSI vs refund)")
    }

    @Test("Refund ambiguo: el importe queda provisional con posible ajuste negativo (v4-g)")
    func ambiguousRefundMakesProvisional() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(institution: "American Express Mexico", type: .creditCard)
        context.insert(account)

        // Caso del spec: $5,100 contabilizados; posible reembolso $300 asociado ambiguamente.
        let progress = run(context, account: account, txs: [
            (10, -4_500, "COMPRA GRANDE"),
            (11, -300, "TIENDA"),
            (12, -300, "TIENDA"),
            (13, 300, "TIENDA"),  // ¿reembolsa A o B? Ambiguo.
        ])
        #expect(progress.eligibleFirm == 5_100, "El firme conserva el importe — provisional")
        #expect(progress.possibleNegativeAdjustment == 300,
                "El posible ajuste negativo se exhibe (banda $4,800–$5,100)")
        #expect(progress.possiblePositiveAddition == 0)
    }

    @Test("Refund duplicado y crédito previo a la compra no se aplican")
    func invalidRefundEvidenceIsIgnored() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(institution: "American Express Mexico", type: .creditCard)
        context.insert(account)
        let before = Transaction(account: account, postedAt: date(2026, 9, 9), amount: 300,
                                 descriptionRaw: "TIENDA XYZ")
        let charge = Transaction(account: account, postedAt: date(2026, 9, 10), amount: -500,
                                 descriptionRaw: "TIENDA XYZ")
        let duplicate = Transaction(account: account, postedAt: date(2026, 9, 11), amount: 500,
                                    descriptionRaw: "TIENDA XYZ")
        duplicate.isDuplicate = true
        [before, charge, duplicate].forEach { context.insert($0) }
        let progress = PromotionEvaluator().evaluate(definitions: [def(account: account)], account: account,
            transactions: [before, charge, duplicate], channelTable: ChannelTable(entries: []),
            asOf: date(2026, 9, 30)).first!
        #expect(progress.eligibleFirm == 500)
        #expect(progress.reconciliations.allSatisfy { $0.status == .unmatched })
    }

    @Test("Refund superior al saldo del cargo queda disputado, sin sobreaplicar")
    func oversizedRefundIsDisputed() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(institution: "American Express Mexico", type: .creditCard)
        context.insert(account)
        let progress = run(context, account: account, txs: [
            (10, -100, "TIENDA XYZ"),
            (11, 150, "TIENDA XYZ"),
        ])
        #expect(progress.eligibleFirm == 100)
        #expect(progress.possibleNegativeAdjustment == 100)
        #expect(progress.reconciliations.first?.status == .disputed)
    }

    @Test("Refunds ambiguos múltiples no pueden descontar más que los cargos candidatos")
    func ambiguousRefundsShareTheRemainingChargeCap() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(institution: "American Express Mexico", type: .creditCard)
        context.insert(account)
        let progress = run(context, account: account, txs: [
            (10, -250, "TIENDA XYZ"),
            (11, -250, "TIENDA XYZ"),
            (12, 300, "TIENDA XYZ"),
            (13, 300, "TIENDA XYZ"),
        ])
        #expect(progress.eligibleFirm == 500)
        #expect(progress.possibleNegativeAdjustment == 500)
        #expect(progress.reconciliations.filter { $0.status == .disputed }
            .reduce(Decimal(0)) { $0 + $1.potentialAdjustment } == 500)
    }
}
