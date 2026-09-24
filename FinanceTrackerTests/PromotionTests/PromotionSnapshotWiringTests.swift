import Testing
import Foundation
import SwiftData
@testable import FinanceTracker

/// Ciclo 9 (TDD): el snapshot de liability incluye el progreso de promociones evaluado sobre
/// el HISTORIAL COMPLETO de la cuenta (no solo el periodo visible del dashboard).
@Suite("Promotion Snapshot Wiring")
@MainActor
struct PromotionSnapshotWiringTests {

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

    @Test("LiabilityAccountSnapshot evalúa promociones sobre el historial completo")
    func liabilitySnapshotIncludesPromotions() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let platinum = Account(institution: "American Express Mexico", type: .creditCard)
        platinum.id = UUID(uuidString: "98635015-070A-4EB5-9050-3268FB4B49FA")!
        platinum.nickname = "The Platinum Credit Card"
        context.insert(platinum)

        // Transacción FUERA del periodo del dashboard (hace 8 meses) pero DENTRO de la
        // ventana de la promo (anclada 2026-09-09, hoy ~2026-09): debe contar igual.
        let inWindow = Transaction(account: platinum, postedAt: date(2026, 9, 10),
                                   amount: -1_200, descriptionRaw: "OXXO 123")
        context.insert(inWindow)

        let viewModel = DashboardViewModel()
        viewModel.dateRange = DateRange(start: date(2026, 9, 20), end: date(2026, 9, 21))
        viewModel.scope = .account(platinum.id)
        viewModel.configure(context: context)

        guard case .liability(let snap) = viewModel.snapshot else {
            Issue.record("Se esperaba snapshot liability, fue \(viewModel.snapshot)"); return
        }
        let promo = snap.promotions.first { $0.definitionID == "amex-platinum-bienvenida-2026" }
        #expect(promo != nil, "La promo A (bundle real) aparece en el snapshot de la Platinum")
        #expect(promo?.eligibleFirm == 1_200, "La tx en ventana cuenta aunque esté fuera del periodo del dashboard")
        // E (Gold) está en el bundle pero desvinculada: no debe evaluarse contra la Platinum.
        #expect(snap.promotions.allSatisfy { $0.definitionID != "amex-gold-everyday-value" || $0.calculability != .calculable })
    }
}
