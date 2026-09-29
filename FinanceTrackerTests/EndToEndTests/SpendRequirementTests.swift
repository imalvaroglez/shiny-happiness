import Foundation
import Testing
@testable import FinanceTracker

@Suite("Gasto mínimo por ciclo")
struct SpendRequirementTests {
    private let asOf = Self.date("2026-09-24")

    private static func date(_ value: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = MexicoBankingCalendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)!
    }

    private func requirement(day: Int = 9, amount: Decimal = 3_500, adjusts: Bool = true) -> SpendRequirement {
        SpendRequirement(accountID: UUID(), name: "Gasto mínimo", amount: amount, currency: "MXN",
                         statementClosingDay: day, adjustToPreviousBusinessDay: adjusts)
    }

    @Test("Los dos cortes 2Now resuelven el ciclo esperado en CDMX")
    func twoNowCycles() throws {
        let mar = requirement(day: 11)
        let alvaro = requirement(day: 9)
        let marCycle = try #require(SpendRequirementCalculator.cycle(for: mar, asOf: asOf))
        let alvaroCycle = try #require(SpendRequirementCalculator.cycle(for: alvaro, asOf: asOf))
        #expect(marCycle.start == Self.date("2026-09-12"))
        #expect(marCycle.closingDate == Self.date("2026-10-09"))
        #expect(marCycle.nominalClosingDate == Self.date("2026-10-11"))
        #expect(marCycle.daysUntilClosing == 15)
        #expect(alvaroCycle.start == Self.date("2026-09-10"))
        #expect(alvaroCycle.closingDate == Self.date("2026-10-09"))
        #expect(alvaroCycle.daysUntilClosing == 15)
    }

    @Test("Cortes inhábiles avanzan al hábil anterior y esperan años sin cobertura")
    func holidayAndCoverage() throws {
        let holidayCut = requirement(day: 16)
        let cycle = try #require(SpendRequirementCalculator.cycle(for: holidayCut, asOf: Self.date("2026-09-10")))
        #expect(cycle.closingDate == Self.date("2026-09-15"))
        let weekendCut = requirement(day: 13)
        let weekend = try #require(SpendRequirementCalculator.cycle(for: weekendCut, asOf: Self.date("2026-09-10")))
        #expect(weekend.closingDate == Self.date("2026-09-11"))
        #expect(SpendRequirementCalculator.cycle(for: requirement(day: 9), asOf: Self.date("2027-01-04")) == nil)
    }

    @Test("Un corte movido al mes anterior no desplaza el ciclo al mes equivocado")
    func earlyMonthCutAdjustment() throws {
        let janCycle = try #require(SpendRequirementCalculator.cycle(for: requirement(day: 1),
                                                                       asOf: Self.date("2026-01-02")))
        #expect(janCycle.start == Self.date("2026-01-01"))
        #expect(janCycle.closingDate == Self.date("2026-01-30"))
        let augCycle = try #require(SpendRequirementCalculator.cycle(for: requirement(day: 1),
                                                                       asOf: Self.date("2026-08-05")))
        #expect(augCycle.start == Self.date("2026-08-01"))
        #expect(augCycle.closingDate == Self.date("2026-09-01"))
    }

    @Test("Los días 29–31 se ajustan al último día del mes")
    func monthEndClamping() throws {
        let leap = try #require(SpendRequirementCalculator.cycle(for: requirement(day: 31, adjusts: false),
                                                                  asOf: Self.date("2024-02-20")))
        #expect(leap.closingDate == Self.date("2024-02-29"))
        let shortMonth = try #require(SpendRequirementCalculator.cycle(for: requirement(day: 30, adjusts: false),
                                                                        asOf: Self.date("2026-04-10")))
        #expect(shortMonth.closingDate == Self.date("2026-04-30"))
    }

    @Test("El día de corte permanece abierto hasta medianoche y el nuevo ciclo inicia al día siguiente")
    func closingDayBoundary() throws {
        let req = requirement(day: 9)
        let cutoff = Self.date("2026-10-09")
        let movements = [
            SpendRequirementMovement(id: UUID(), date: cutoff.addingTimeInterval(16 * 60 * 60),
                                     amount: -3_500, currency: "MXN", kind: .purchase),
            SpendRequirementMovement(id: UUID(), date: cutoff.addingTimeInterval(24 * 60 * 60),
                                     amount: -700, currency: "MXN", kind: .purchase),
        ]
        guard case .available(let closingDay) = SpendRequirementCalculator.evaluate(
            requirement: req, movements: movements, asOf: cutoff.addingTimeInterval(23 * 60 * 60)
        ), case .available(let nextCycle) = SpendRequirementCalculator.evaluate(
            requirement: req, movements: movements, asOf: cutoff.addingTimeInterval(25 * 60 * 60)
        ) else {
            Issue.record("Expected available results for both cycles")
            return
        }
        #expect(closingDay.eligibleSpend == 3_500)
        #expect(closingDay.targetReached)
        #expect(nextCycle.cycle.start == cutoff.addingTimeInterval(24 * 60 * 60))
        #expect(nextCycle.eligibleSpend == 700)
    }

    @Test("El gasto suma mensualidades y aplica devoluciones en el ciclo del abono")
    func spendAndPostedRefunds() throws {
        let req = requirement()
        let movements = [
            SpendRequirementMovement(id: UUID(), date: Self.date("2026-09-10"), amount: -2_000, currency: "MXN", kind: .purchase),
            SpendRequirementMovement(id: UUID(), date: Self.date("2026-09-20"), amount: -1_500, currency: "MXN", kind: .purchase),
            SpendRequirementMovement(id: UUID(), date: Self.date("2026-09-21"), amount: 300, currency: "MXN", kind: .refund),
            SpendRequirementMovement(id: UUID(), date: Self.date("2026-10-10"), amount: 700, currency: "MXN", kind: .refund),
            SpendRequirementMovement(id: UUID(), date: Self.date("2026-09-22"), amount: -500, currency: "USD", kind: .purchase),
            SpendRequirementMovement(id: UUID(), date: Self.date("2026-09-22"), amount: -500, currency: "MXN", kind: .purchase, isDuplicate: true),
            SpendRequirementMovement(id: UUID(), date: Self.date("2026-09-25"), amount: -500, currency: "MXN", kind: .purchase),
        ]
        guard case .available(let progress) = SpendRequirementCalculator.evaluate(requirement: req, movements: movements, asOf: asOf) else {
            Issue.record("Expected an available result")
            return
        }
        #expect(progress.eligibleSpend == 3_200)
        #expect(progress.remaining == 300)
        #expect(!progress.targetReached)
    }

    @Test("El resultado contempla montos exactos, excedentes, negativos y abonos ambiguos")
    func thresholdsAndAmbiguity() throws {
        let req = requirement()
        func evaluate(_ entries: [(Decimal, SpendRequirementMovement.Kind)]) throws -> SpendRequirementProgress {
            let rows = entries.map { amount, kind in
                SpendRequirementMovement(id: UUID(), date: Self.date("2026-09-20"), amount: amount,
                                         currency: "MXN", kind: kind)
            }
            guard case .available(let progress) = SpendRequirementCalculator.evaluate(requirement: req, movements: rows, asOf: asOf) else {
                throw TestFailure.expectedAvailable
            }
            return progress
        }
        #expect(try evaluate([(-3_499, .purchase)]).remaining == 1)
        #expect(try evaluate([(-3_500, .purchase)]).targetReached)
        #expect(try evaluate([(-4_000, .purchase)]).progress == 4_000 / 3_500)
        let uncertain = try evaluate([(-3_500, .purchase), (100, .ambiguousCredit)])
        #expect(uncertain.isPotentiallyAmbiguous)
        #expect(!uncertain.targetReached)
        let negative = try evaluate([(-100, .purchase), (250, .refund)])
        #expect(negative.eligibleSpend == -150)
        #expect(negative.progress == 0)
    }

    @Test("La clasificación excluye pagos, fees, efectivo y compras MSI sintetizadas")
    func classification() {
        func classify(_ amount: Decimal, flow: TransactionFlowKind = .charge, description: String = "Compra",
                      treatment: TransactionTreatmentKind = .regular, synthesized: Bool = false) -> SpendRequirementMovement.Kind {
            SpendRequirementMovementClassifier.classify(amount: amount, flowKind: flow, treatment: treatment,
                description: description, category: "", isDuplicate: false, isDeleted: false, isTransfer: false,
                isPaymentCategory: false, isTransferCategory: false, isSynthesizedMSI: synthesized)
        }
        #expect(classify(-500) == .purchase)
        #expect(classify(-500, synthesized: true) == .excluded)
        #expect(classify(-500, description: "Comisión anual") == .excluded)
        #expect(classify(-500, description: "Interest Charges") == .excluded)
        #expect(classify(-500, description: "Disposición de efectivo") == .excluded)
        #expect(classify(-500, treatment: .fee) == .excluded)
        #expect(classify(500, flow: .payment) == .excluded)
        #expect(classify(500, flow: .cardCredit, description: "Devolución de compra") == .refund)
        #expect(classify(500, flow: .cardCredit) == .ambiguousCredit)
    }

    @Test("Los defaults se vinculan solo si la cuenta es única y las bajas sobreviven al merge")
    func storeBootstrapAndMerge() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spend-store-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("SpendRequirements.json")
        let mar = Account(institution: "HSBC", type: .creditCard, currency: "MXN", nickname: "2Now de Mar")
        let alvaro = Account(institution: "HSBC", type: .creditCard, currency: "MXN", nickname: "2Now de Álvaro")
        let initial = try SpendRequirementStore.bootstrapSuggestions(accounts: [mar, alvaro], fileURL: url)
        #expect(initial.requirements.count == 2)
        #expect(initial.requirements.first(where: { $0.accountID == mar.id })?.amount == 3_500)
        #expect(initial.requirements.first(where: { $0.accountID == alvaro.id })?.statementClosingDay == 9)

        let duplicate = Account(institution: "HSBC", type: .creditCard, currency: "MXN", nickname: "2Now de Mar")
        let ambiguousURL = root.appendingPathComponent("ambiguous.json")
        let ambiguous = try SpendRequirementStore.bootstrapSuggestions(accounts: [mar, duplicate], fileURL: ambiguousURL)
        #expect(ambiguous.requirements.isEmpty)

        var tombstone = initial.requirements[0]
        tombstone.enabled = false
        tombstone.lastModifiedAt = Date(timeIntervalSince1970: 2_000_000_000)
        try SpendRequirementStore.save(tombstone, to: url)
        let old = SpendRequirementSettings(updatedAt: .distantPast, requirements: initial.requirements)
        try SpendRequirementStore.merge(old, at: url)
        #expect(try SpendRequirementStore.read(fileURL: url).requirements.first(where: { $0.accountID == mar.id })?.enabled == false)

        let blockedParent = root.appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: blockedParent)
        #expect(throws: (any Error).self) {
            try SpendRequirementStore.save(requirement(), to: blockedParent.appendingPathComponent("settings.json"))
        }
    }

    @Test("El almacenamiento implícito de pruebas queda fuera del contenedor Dev")
    func testStoreUsesTemporaryDirectory() throws {
        #expect(try SpendRequirementStore.defaultURL().path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }
}

private enum TestFailure: Error { case expectedAvailable }
