import Testing
import Foundation
import SwiftData
@testable import FinanceTracker

/// Ciclo 2 (TDD): compuertas del evaluador — etapas a/b (movimientos válidos → exclusiones SOLO sobre
/// cargos elegibles), independencia de preferencias del dashboard, no calculable.
/// Spec G.1/G.2 y Hechos duros: jamás countsAsRegularExpense; soft-deleted fuera por fetch;
/// créditos conservados como evidencia (una reversión CCP-categorizada no se descarta).
@Suite("Promotion Evaluator Gates")
@MainActor
struct PromotionEvaluatorGatesTests {

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

    /// Definición mínima de umbral con ventana fija 1–30 sep 2026 y whitelist abierta.
    private func thresholdDef(id: String = "test-promo", accountUUID: UUID?,
                              window: PromotionDefinition.PromotionWindow = .fixed(
                                  start: "2026-09-01", end: "2026-09-30", provenance: "test"),
                              scope: PromotionScope = PromotionScope(
                                  currency: "MXN", merchants: [], requireChannel: .any, excludeFees: true, excludeThirdParties: false))
        -> PromotionDefinition {
        PromotionDefinition(id: id, displayName: id, accountUUID: accountUUID,
                            authoringNickname: nil, window: window,
                            shape: .spendThreshold(target: 100_000, reward: 15_000),
                            scope: scope,
                            refundPolicy: RefundPolicy(kind: .subtract),
                            msiPolicy: MsiPolicy(kind: .countPostedInstallments, reversalPatterns: [],
                                                 conversionRiskThreshold: nil),
                            reward: RewardSpec(expectedAmount: 15_000, descriptorPatterns: []),
                            knownUnknowns: [])
    }

    private func evaluate(_ def: PromotionDefinition, account: Account,
                          txs: [Transaction], asOf: Date = .distantFuture) -> PromotionProgress {
        let result = PromotionEvaluator().evaluate(
            definitions: [def], account: account, transactions: txs,
            channelTable: ChannelTable(entries: []), asOf: asOf)
        guard let progress = result.first else {
            Issue.record("El evaluador debe devolver un progress por definición");
            return PromotionProgress(definitionID: def.id, displayName: def.displayName,
                                     calculability: .calculable, eligibleFirm: 0, rows: [])
        }
        return progress
    }

    @Test("Sin UUID de cuenta la promo es no calculable (clase ①)")
    func unboundDefinitionIsNotCalculable() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(institution: "American Express Mexico", type: .creditCard)
        context.insert(account)

        let progress = evaluate(thresholdDef(accountUUID: nil), account: account, txs: [])
        guard case .notCalculable = progress.calculability else {
            Issue.record("Se esperaba notCalculable, fue \(progress.calculability)"); return
        }
    }

    @Test("UUID distinto al de la cuenta es no calculable (nunca revincula)")
    func mismatchedUUIDIsNotCalculable() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(institution: "American Express Mexico", type: .creditCard)
        context.insert(account)

        let other = UUID()
        let progress = evaluate(thresholdDef(accountUUID: other), account: account, txs: [])
        guard case .notCalculable = progress.calculability else {
            Issue.record("Se esperaba notCalculable, fue \(progress.calculability)"); return
        }
    }

    @Test("Ventana desconocida es no calculable")
    func unknownWindowIsNotCalculable() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(institution: "American Express Mexico", type: .creditCard)
        context.insert(account)

        let progress = evaluate(thresholdDef(accountUUID: account.id,
                                             window: .unknown(note: "T&C pendiente")),
                                account: account, txs: [])
        guard case .notCalculable = progress.calculability else {
            Issue.record("Se esperaba notCalculable, fue \(progress.calculability)"); return
        }
    }

    @Test("Compuertas: pago→evidencia, transferencia/fee/duplicado/USD/original-MSI→excluidos; cargo en ventana→elegible")
    func structuralGates() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(institution: "American Express Mexico", type: .creditCard)
        context.insert(account)
        let ccpCategory = FinanceTracker.Category(name: "Credit Card Payments", kind: .creditCardPayment)
        context.insert(ccpCategory)
        let feeCategory = FinanceTracker.Category(name: "Bank Fees", kind: .expense)
        context.insert(feeCategory)

        let plan = InstallmentPlan(originalAmount: 8_000, totalMonths: 3, currentMonth: 1,
                                   monthlyAmount: 2_666.67, firstChargeDate: date(2026, 9, 5),
                                   merchantDescription: "MUEBLES")
        context.insert(plan)

        let eligibleCharge = Transaction(account: account, postedAt: date(2026, 9, 10), amount: -1_200,
                                         descriptionRaw: "OXXO 123")
        let payment = Transaction(account: account, postedAt: date(2026, 9, 10), amount: 20_000,
                                  descriptionRaw: "GRACIAS POR SU PAGO EN LINEA", category: ccpCategory)
        let transfer = Transaction(account: account, postedAt: date(2026, 9, 11), amount: -500,
                                   descriptionRaw: "TRANSFER", isTransfer: true)
        let fee = Transaction(account: account, postedAt: date(2026, 9, 12), amount: -696,
                              descriptionRaw: "CARGO POR PAGO TARDÍO + IVA", category: feeCategory,
                              treatmentKindRaw: "fee")
        let duplicate = Transaction(account: account, postedAt: date(2026, 9, 13), amount: -300,
                                    descriptionRaw: "WALMART", isDuplicate: true)
        let usd = Transaction(account: account, postedAt: date(2026, 9, 14), amount: -100,
                              currency: "USD", descriptionRaw: "USD STORE")
        let msiOriginal = Transaction(account: account, postedAt: date(2026, 9, 15), amount: -8_000,
                                      descriptionRaw: "MUEBLES", installmentPlan: plan)
        let outside = Transaction(account: account, postedAt: date(2026, 10, 5), amount: -400,
                                  descriptionRaw: "OXXO 456")
        context.insert(eligibleCharge); context.insert(payment); context.insert(transfer)
        context.insert(fee); context.insert(duplicate); context.insert(usd)
        context.insert(msiOriginal); context.insert(outside)

        let progress = evaluate(thresholdDef(accountUUID: account.id), account: account,
                                txs: [eligibleCharge, payment, transfer, fee, duplicate, usd, msiOriginal, outside])

        func outcome(_ id: UUID) -> (PromotionProgress.RowOutcome.Outcome, String)? {
            progress.rows.first { $0.transactionID == id }.map { ($0.outcome, $0.reason) }
        }

        #expect(outcome(eligibleCharge.id)?.0 == .eligible)
        #expect(outcome(payment.id)?.0 == .evidence,
                "Un crédito/pago es EVIDENCIA, no se descarta en etapa a (spec G.1a)")
        #expect(outcome(transfer.id)?.0 == .excluded)
        #expect(outcome(fee.id)?.0 == .excluded, "Fees excluidos por política de oferta")
        #expect(outcome(duplicate.id)?.0 == .excluded)
        #expect(outcome(usd.id)?.0 == .excluded, "Moneda ≠ MXN excluida")
        #expect(outcome(msiOriginal.id)?.0 == .excluded, "Original MSI sintetizado no cuenta (cuentan las cuotas)")
        #expect(outcome(outside.id)?.0 == .excluded, "Fuera de ventana excluido")

        #expect(progress.eligibleFirm == 1_200)
    }

    @Test("Soft-deleted no aparece en filas (filtrado a nivel de evaluación, como HouseholdSettlement)")
    func softDeletedAbsent() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(institution: "American Express Mexico", type: .creditCard)
        context.insert(account)
        let deleted = Transaction(account: account, postedAt: date(2026, 9, 10), amount: -1_200,
                                  descriptionRaw: "OXXO 123")
        deleted.deletedAt = date(2026, 9, 20)
        context.insert(deleted)

        let progress = evaluate(thresholdDef(accountUUID: account.id), account: account, txs: [deleted])
        #expect(progress.rows.isEmpty)
        #expect(progress.eligibleFirm == 0)
    }

    @Test("Independencia del dashboard: includeInCashFlow NO cambia el progreso")
    func dashboardPreferenceIndependence() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(institution: "American Express Mexico", type: .creditCard)
        context.insert(account)
        let charge = Transaction(account: account, postedAt: date(2026, 9, 10), amount: -1_200,
                                 descriptionRaw: "OXXO 123")
        context.insert(charge)

        let withPreference = evaluate(thresholdDef(accountUUID: account.id), account: account, txs: [charge])
        account.includeInCashFlow = false
        let withoutPreference = evaluate(thresholdDef(accountUUID: account.id), account: account, txs: [charge])

        #expect(withPreference.eligibleFirm == withoutPreference.eligibleFirm)
        #expect(withPreference.rows == withoutPreference.rows,
                "Alternar includeInCashFlow no debe mover el progreso (spec G.1b)")
    }
}
