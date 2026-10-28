import Foundation
import Testing
@testable import FinanceTracker

@Suite("Property management")
struct PropertyManagementTests {
    private func date(_ year: Int, _ month: Int, _ day: Int = 1) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func confirmedIncome(_ propertyID: UUID, _ residentID: UUID, _ month: Date,
                                 _ amount: Decimal) -> PropertyIncome {
        PropertyIncome(propertyID: propertyID, residentID: residentID, monthStart: month,
                       amount: amount, confirmedAt: date(2026, 10, 31))
    }

    @Test("Shared allocations prefer whole pesos, preserve cents, and use only selected residents")
    func proportionalAllocation() throws {
        let property = PropertyRecord(name: "Casa de prueba")
        let month = date(2026, 11)
        let alex = PropertyResident(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            propertyID: property.id, name: "Alex", activeFrom: month, referenceMonthlyIncome: 5_880)
        let fer = PropertyResident(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            propertyID: property.id, name: "Fer", activeFrom: month, referenceMonthlyIncome: 20_000)
        let sam = PropertyResident(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            propertyID: property.id, name: "Sam", activeFrom: month, referenceMonthlyIncome: 7_000)
        var ledger = PropertyLedger()
        ledger.properties = [property]
        ledger.residents = [alex, fer, sam]
        ledger.incomes = [confirmedIncome(property.id, alex.id, month, 5_880),
                          confirmedIncome(property.id, fer.id, month, 20_000),
                          confirmedIncome(property.id, sam.id, month, 7_000)]
        ledger.rents = [PropertyRentAgreement(propertyID: property.id, monthlyAmount: 4_167, effectiveMonth: month)]

        let report = PropertySettlementCalculator.report(propertyID: property.id, month: month,
            ledger: ledger, transactions: [])
        let rent = try #require(report.obligations.first(where: { $0.isRent }))
        #expect(rent.allocations[alex.id] == 745)
        #expect(rent.allocations[fer.id] == 2_535)
        #expect(rent.allocations[sam.id] == 887)
        #expect(rent.allocations.values.reduce(0, +) == 4_167)

        let cents = try #require(PropertySettlementCalculator.allocate(4_167.75,
            residentIDs: [alex.id, fer.id, sam.id], incomes: [5_880, 20_000, 7_000]))
        #expect(cents[alex.id] == 745.13)
        #expect(cents[fer.id] == 2_535.46)
        #expect(cents[sam.id] == 887.16)
        #expect(cents.values.reduce(0, +) == 4_167.75)

        let partial = try #require(PropertySettlementCalculator.allocate(500,
            residentIDs: [alex.id, sam.id], incomes: [5_880, 7_000]))
        #expect(Set(partial.keys) == [alex.id, sam.id])
        #expect(partial.values.reduce(0, +) == 500)
    }

    @Test("Zero income blocks closing; explicit zero is confirmed and future residents are month scoped")
    func zeroIncomeAndEffectiveResidents() {
        let property = PropertyRecord(name: "Casa de prueba")
        let november = date(2026, 11)
        let resident = PropertyResident(propertyID: property.id, name: "Alex", activeFrom: november)
        var ledger = PropertyLedger()
        ledger.properties = [property]
        ledger.residents = [resident]
        ledger.rents = [
            PropertyRentAgreement(propertyID: property.id, monthlyAmount: 1_300, effectiveMonth: date(2026, 10)),
            PropertyRentAgreement(propertyID: property.id, monthlyAmount: 3_000, effectiveMonth: november),
        ]
        var report = PropertySettlementCalculator.report(propertyID: property.id, month: november,
            ledger: ledger, transactions: [])
        #expect(report.rent == 3_000)
        #expect(!report.canClose)
        #expect(PropertySettlementCalculator.close(report) == nil)

        ledger.incomes = [confirmedIncome(property.id, resident.id, november, 0)]
        report = PropertySettlementCalculator.report(propertyID: property.id, month: november,
            ledger: ledger, transactions: [])
        #expect(report.residents.first?.confirmed == true)
        #expect(!report.canClose)
        #expect(report.warnings.contains { $0.contains("ingresos positivos") })

        let future = PropertyResident(propertyID: property.id, name: "Sam", activeFrom: date(2026, 12))
        ledger.residents.append(future)
        #expect(ledger.residents(for: property.id, month: november).map(\.id) == [resident.id])
        #expect(Set(ledger.residents(for: property.id, month: date(2026, 12)).map(\.id)) == [resident.id, future.id])
    }

    @Test("Service estimates never create charges; actual card expenses use the transaction month")
    func actualExpensesAndPeriodRent() {
        let property = PropertyRecord(name: "Casa de prueba")
        let november = date(2026, 11)
        let resident = PropertyResident(propertyID: property.id, name: "Alex", activeFrom: november,
                                        referenceMonthlyIncome: 10_000)
        var ledger = PropertyLedger()
        ledger.properties = [property]
        ledger.residents = [resident]
        ledger.rents = [
            PropertyRentAgreement(propertyID: property.id, monthlyAmount: 3_000, effectiveMonth: november),
            PropertyRentAgreement(propertyID: property.id, monthlyAmount: 3_000, effectiveMonth: date(2026, 12)),
        ]
        ledger.serviceBudgets = [PropertyServiceBudget(propertyID: property.id, name: "Luz",
            frequency: .monthly, monthlyReference: 450)]
        ledger.incomes = [confirmedIncome(property.id, resident.id, november, 10_000),
            confirmedIncome(property.id, resident.id, date(2026, 12), 10_000)]
        let novemberCharge = UUID()
        let decemberCharge = UUID()
        ledger.attributions = [
            PropertyTransactionAttribution(propertyID: property.id, transactionID: novemberCharge,
                kind: .operation, responsibility: .shared),
            PropertyTransactionAttribution(propertyID: property.id, transactionID: decemberCharge,
                kind: .operation, responsibility: .shared),
        ]
        let transactions = [
            PropertyTransactionInput(id: novemberCharge, amount: -450, postedAt: date(2026, 11, 18),
                description: "Electricidad", isCashAccount: false),
            PropertyTransactionInput(id: decemberCharge, amount: -1_450, postedAt: date(2026, 12, 4),
                description: "Servicios", isCashAccount: false),
        ]
        let nov = PropertySettlementCalculator.report(propertyID: property.id, month: november,
            ledger: ledger, transactions: transactions)
        let dec = PropertySettlementCalculator.report(propertyID: property.id, month: date(2026, 12),
            ledger: ledger, transactions: transactions)
        #expect(nov.rent + nov.expenses == 3_450)
        #expect(dec.rent + dec.expenses == 4_450)
        #expect(nov.obligations.filter { $0.transactionID == nil }.count == 1)
        #expect(dec.obligations.filter { $0.transactionID == nil }.count == 1)

        let individual = UUID()
        ledger.attributions.append(PropertyTransactionAttribution(propertyID: property.id,
            transactionID: individual, kind: .other, responsibility: .individual(residentID: resident.id)))
        let individualReport = PropertySettlementCalculator.report(propertyID: property.id, month: november,
            ledger: ledger, transactions: transactions + [PropertyTransactionInput(id: individual,
                amount: -500, postedAt: date(2026, 11, 22), description: "Gasto individual")])
        #expect(individualReport.residents.first?.individualExpenses == 500)
    }

    @Test("Foreign-currency movements stay out of MXN property reports and block reconciliation")
    func foreignCurrencyDoesNotEnterMXNReport() {
        let property = PropertyRecord(name: "Casa de prueba")
        let month = date(2026, 11)
        let resident = PropertyResident(propertyID: property.id, name: "Alex", activeFrom: month,
                                        referenceMonthlyIncome: 10_000)
        let expenseID = UUID()
        let paymentID = UUID()
        let rentID = UUID.deterministic(property.id, month, "rent")
        var ledger = PropertyLedger()
        ledger.properties = [property]
        ledger.residents = [resident]
        ledger.incomes = [confirmedIncome(property.id, resident.id, month, 10_000)]
        ledger.rents = [PropertyRentAgreement(propertyID: property.id, monthlyAmount: 3_000, effectiveMonth: month)]
        ledger.attributions = [PropertyTransactionAttribution(propertyID: property.id,
            transactionID: expenseID, kind: .operation, responsibility: .shared)]
        ledger.paymentApplications = [PropertyPaymentApplication(propertyID: property.id,
            paymentTransactionID: paymentID, obligationID: rentID, residentID: resident.id, amount: 500,
            sourceCurrencySnapshot: "MXN")]

        let report = PropertySettlementCalculator.report(propertyID: property.id, month: month, ledger: ledger,
            transactions: [
                PropertyTransactionInput(id: expenseID, amount: -100, postedAt: date(2026, 11, 10),
                    description: "Servicio en dólares", currencyCode: "USD"),
                PropertyTransactionInput(id: paymentID, amount: 500, postedAt: date(2026, 11, 12),
                    description: "Cobro en dólares", isCashAccount: true, currencyCode: "USD"),
            ])

        #expect(report.rent == 3_000)
        #expect(report.expenses == 0)
        #expect(report.collected == 0)
        #expect(report.cashCollected == 0)
        #expect(report.warnings.contains { $0.contains("requiere importes en MXN") })
        #expect(report.warnings.contains { $0.contains("no está en MXN") })
    }

    @Test("A property movement cannot also be counted by Household")
    func householdAndPropertyDestinationsAreExclusive() {
        let property = PropertyRecord(name: "Casa de prueba")
        let month = date(2026, 11)
        let resident = PropertyResident(propertyID: property.id, name: "Alex", activeFrom: month,
                                        referenceMonthlyIncome: 10_000)
        let expenseID = UUID()
        var ledger = PropertyLedger()
        ledger.properties = [property]
        ledger.residents = [resident]
        ledger.incomes = [confirmedIncome(property.id, resident.id, month, 10_000)]
        ledger.attributions = [PropertyTransactionAttribution(propertyID: property.id,
            transactionID: expenseID, kind: .operation, responsibility: .shared)]
        let input = PropertyTransactionInput(id: expenseID, amount: -500, postedAt: date(2026, 11, 10),
            description: "Compra compartida", isHouseholdAssigned: true)

        let report = PropertySettlementCalculator.report(propertyID: property.id, month: month,
            ledger: ledger, transactions: [input])
        #expect(report.expenses == 0)
        #expect(report.warnings.contains { $0.contains("también está asignado al hogar") })
        #expect(!report.canClose)
    }

    @Test("Unified property portfolio accumulates household and other-home expenses")
    func portfolioTotalsIncludeHouseholdAndProperties() {
        let report = PropertyMonthlyReport(propertyID: UUID(), monthStart: date(2026, 11),
            rent: 3_000, expenses: 500, collected: 2_000, cashCollected: 1_800,
            reimbursementsReceived: 200, priorBalance: 0, residents: [], obligations: [], warnings: [])

        let totals = PropertyPortfolioTotals.combine(householdExpenses: 1_100,
            amountToRecoverFromFer: 250, propertyReports: [report])

        #expect(totals.householdExpenses == 1_100)
        #expect(totals.propertyRent == 3_000)
        #expect(totals.propertyExpenses == 500)
        #expect(totals.accumulatedExpenses == 1_600)
        #expect(totals.propertyCollected == 1_800)
        #expect(totals.amountToRecoverFromFer == 250)
    }

    @Test("Attributed reimbursements improve operating result without reducing resident obligations")
    func reimbursementsAreReportedSeparately() throws {
        let property = PropertyRecord(name: "Casa de prueba")
        let month = date(2026, 11)
        let resident = PropertyResident(propertyID: property.id, name: "Alex", activeFrom: month,
                                        referenceMonthlyIncome: 10_000)
        let expenseID = UUID()
        let reimbursementID = UUID()
        var ledger = PropertyLedger()
        ledger.properties = [property]
        ledger.residents = [resident]
        ledger.incomes = [confirmedIncome(property.id, resident.id, month, 10_000)]
        ledger.attributions = [
            PropertyTransactionAttribution(propertyID: property.id, transactionID: expenseID,
                kind: .operation, responsibility: .shared, sourceAmountSnapshot: -1_000,
                sourcePostedAtSnapshot: date(2026, 11, 5), sourceCurrencySnapshot: "MXN",
                sourceDescriptionSnapshot: "Reparación"),
            PropertyTransactionAttribution(propertyID: property.id, transactionID: reimbursementID,
                kind: .reimbursement, responsibility: .owner, sourceAmountSnapshot: 250,
                sourcePostedAtSnapshot: date(2026, 11, 12), sourceCurrencySnapshot: "MXN",
                sourceDescriptionSnapshot: "Reembolso"),
        ]
        let transactions = [
            PropertyTransactionInput(id: expenseID, amount: -1_000, postedAt: date(2026, 11, 5),
                description: "Reparación"),
            PropertyTransactionInput(id: reimbursementID, amount: 250, postedAt: date(2026, 11, 12),
                description: "Reembolso", isCashAccount: true),
        ]

        let report = PropertySettlementCalculator.report(propertyID: property.id, month: month,
            ledger: ledger, transactions: transactions)
        #expect(report.expenses == 1_000)
        #expect(report.reimbursementsReceived == 250)
        #expect(report.residents.first?.sharedExpenses == 1_000)
        #expect(report.residents.first?.balance == 1_000)
        #expect(report.cashCollected == 0)
        #expect(report.operatingExpenses == 1_000)
        #expect(report.operatingResult == -750)

        let close = try #require(PropertySettlementCalculator.close(report))
        let changedReimbursement = PropertyTransactionInput(id: reimbursementID, amount: 200,
            postedAt: date(2026, 11, 12), description: "Reembolso", isCashAccount: true)
        let frozen = PropertySettlementCalculator.frozenReport(close, ledger: ledger,
            transactions: [transactions[0], changedReimbursement])
        #expect(frozen.reimbursementsReceived == 250)
        #expect(frozen.warnings.contains { $0.contains("cambió después del cierre") })

        ledger.rents = [PropertyRentAgreement(propertyID: property.id, monthlyAmount: 300, effectiveMonth: month)]
        ledger.paymentApplications = [PropertyPaymentApplication(propertyID: property.id,
            paymentTransactionID: reimbursementID, obligationID: UUID.deterministic(property.id, month, "rent"),
            residentID: resident.id, amount: 250)]
        let conflicted = PropertySettlementCalculator.report(propertyID: property.id, month: month,
            ledger: ledger, transactions: transactions)
        #expect(conflicted.reimbursementsReceived == 250)
        #expect(conflicted.collected == 0)
        #expect(conflicted.cashCollected == 0)
        #expect(conflicted.warnings.contains { $0.contains("reembolso y cobro") })
    }

    @Test("Open periods recalculate changed expenses and expose deleted or moved source movements")
    func openPeriodSourceChanges() {
        let property = PropertyRecord(name: "Casa de prueba")
        let november = date(2026, 11)
        let resident = PropertyResident(propertyID: property.id, name: "Alex", activeFrom: november,
                                        referenceMonthlyIncome: 10_000)
        let expenseID = UUID()
        var ledger = PropertyLedger()
        ledger.properties = [property]
        ledger.residents = [resident]
        ledger.incomes = [confirmedIncome(property.id, resident.id, november, 10_000)]
        ledger.attributions = [PropertyTransactionAttribution(propertyID: property.id, transactionID: expenseID,
            kind: .operation, responsibility: .shared, sourceAmountSnapshot: -100,
            sourcePostedAtSnapshot: date(2026, 11, 10), sourceCurrencySnapshot: "MXN",
            sourceDescriptionSnapshot: "Recibo original")]

        let changed = PropertyTransactionInput(id: expenseID, amount: -150, postedAt: date(2026, 11, 12),
            description: "Recibo corregido")
        let recalculated = PropertySettlementCalculator.report(propertyID: property.id, month: november,
            ledger: ledger, transactions: [changed])
        #expect(recalculated.expenses == 150)
        #expect(recalculated.warnings.contains { $0.contains("cambió desde que se atribuyó") })
        #expect(!recalculated.canClose)

        let movedToDecember = PropertyTransactionInput(id: expenseID, amount: -150, postedAt: date(2026, 12, 2),
            description: "Recibo corregido")
        let oldPeriod = PropertySettlementCalculator.report(propertyID: property.id, month: november,
            ledger: ledger, transactions: [movedToDecember])
        let newPeriod = PropertySettlementCalculator.report(propertyID: property.id, month: date(2026, 12),
            ledger: ledger, transactions: [movedToDecember])
        #expect(oldPeriod.expenses == 0)
        #expect(oldPeriod.warnings.contains { $0.contains("cambió desde que se atribuyó") })
        #expect(newPeriod.expenses == 150)
        #expect(newPeriod.warnings.contains { $0.contains("cambió desde que se atribuyó") })

        let deleted = PropertyTransactionInput(id: expenseID, amount: -100, postedAt: date(2026, 11, 10),
            description: "Recibo original", deletedAt: date(2026, 11, 20))
        let deletedReport = PropertySettlementCalculator.report(propertyID: property.id, month: november,
            ledger: ledger, transactions: [deleted])
        #expect(deletedReport.expenses == 0)
        #expect(deletedReport.warnings.contains { $0.contains("se eliminó") })
    }

    @Test("Closed obligations stay frozen while later cash changes collection and reports discrepancies")
    func immutableCloseAndLateCollection() throws {
        let property = PropertyRecord(name: "Casa de prueba")
        let november = date(2026, 11)
        let resident = PropertyResident(propertyID: property.id, name: "Alex", activeFrom: november,
                                        referenceMonthlyIncome: 1_000)
        var ledger = PropertyLedger()
        ledger.properties = [property]
        ledger.residents = [resident]
        ledger.incomes = [confirmedIncome(property.id, resident.id, november, 1_000),
                          confirmedIncome(property.id, resident.id, date(2026, 12), 1_000)]
        ledger.rents = [PropertyRentAgreement(propertyID: property.id, monthlyAmount: 100, effectiveMonth: november)]
        let original = PropertySettlementCalculator.report(propertyID: property.id, month: november,
            ledger: ledger, transactions: [])
        let close = try #require(PropertySettlementCalculator.close(original, at: date(2026, 12)))
        ledger.closes = [close]
        ledger.rents.append(PropertyRentAgreement(propertyID: property.id, monthlyAmount: 200, effectiveMonth: date(2026, 12)))

        let receiptID = UUID()
        let rentID = UUID.deterministic(property.id, november, "rent")
        ledger.paymentApplications = [
            PropertyPaymentApplication(propertyID: property.id, paymentTransactionID: receiptID,
                obligationID: rentID, residentID: resident.id, amount: 20,
                sourceAmountSnapshot: 30, sourcePostedAtSnapshot: date(2026, 12, 8)),
            PropertyPaymentApplication(propertyID: property.id, paymentTransactionID: receiptID,
                obligationID: rentID, residentID: resident.id, amount: 10,
                sourceAmountSnapshot: 30, sourcePostedAtSnapshot: date(2026, 12, 8)),
        ]
        let inputs = [PropertyTransactionInput(id: receiptID, amount: 30, postedAt: date(2026, 12, 8),
            description: "Renta recibida", isCashAccount: true)]
        let frozen = PropertySettlementCalculator.frozenReport(close, ledger: ledger, transactions: inputs)
        #expect(frozen.rent == 100)
        #expect(frozen.collected == 30)
        #expect(frozen.cashCollected == 0)
        #expect(frozen.residents.first?.rent == 100)
        #expect(frozen.residents.first?.adjustments == 0)
        #expect(frozen.residents.first?.balance == 70)

        let december = PropertySettlementCalculator.report(propertyID: property.id, month: date(2026, 12),
            ledger: ledger, transactions: inputs)
        #expect(december.rent == 200)
        #expect(december.priorBalance == 70)
        #expect(december.cashCollected == 30)

        let changed = PropertyTransactionInput(id: receiptID, amount: 31, postedAt: date(2026, 12, 8),
            description: "Renta recibida corregida", isCashAccount: true)
        let discrepancyReport = PropertySettlementCalculator.frozenReport(close, ledger: ledger,
            transactions: [changed])
        #expect(discrepancyReport.rent == 100)
        #expect(discrepancyReport.warnings.contains { $0.contains("cambió después del cierre") })
    }

    @Test("Unapplied cash remains available as an advance and never duplicates the receipt")
    func unappliedAdvanceAndNoDoubleApplication() throws {
        let property = PropertyRecord(name: "Casa de prueba")
        let month = date(2026, 11)
        let resident = PropertyResident(propertyID: property.id, name: "Alex", activeFrom: month,
                                        referenceMonthlyIncome: 1_000)
        let paymentID = UUID()
        let rentID = UUID.deterministic(property.id, month, "rent")
        let advanceID = PropertyPaymentAdvance.obligationID(propertyID: property.id,
                                                            paymentTransactionID: paymentID)
        var ledger = PropertyLedger()
        ledger.properties = [property]
        ledger.residents = [resident]
        ledger.incomes = [confirmedIncome(property.id, resident.id, month, 1_000)]
        ledger.rents = [PropertyRentAgreement(propertyID: property.id, monthlyAmount: 1_000, effectiveMonth: month)]
        ledger.paymentApplications = [
            PropertyPaymentApplication(propertyID: property.id, paymentTransactionID: paymentID,
                obligationID: rentID, residentID: resident.id, amount: 200),
            PropertyPaymentApplication(id: advanceID, propertyID: property.id, paymentTransactionID: paymentID,
                obligationID: advanceID, residentID: PropertyPaymentAdvance.placeholderResidentID(propertyID: property.id),
                amount: 400),
        ]
        let payment = PropertyTransactionInput(id: paymentID, amount: 1_000, postedAt: date(2026, 11, 20),
            description: "Cobro", isCashAccount: true)
        var report = PropertySettlementCalculator.report(propertyID: property.id, month: month,
            ledger: ledger, transactions: [payment])
        #expect(report.collected == 200)
        #expect(report.advanceAvailable == 400)
        #expect(report.cashCollected == 600)
        #expect(PropertyLedgerStore.validate(ledger).isEmpty)

        ledger.paymentApplications[1].amount = 300
        ledger.paymentApplications[1].updatedAt = date(2026, 11, 21)
        ledger.paymentApplications.append(PropertyPaymentApplication(propertyID: property.id,
            paymentTransactionID: paymentID, obligationID: rentID, residentID: resident.id, amount: 500))
        report = PropertySettlementCalculator.report(propertyID: property.id, month: month,
            ledger: ledger, transactions: [payment])
        #expect(report.collected == 700)
        #expect(report.advanceAvailable == 300)
        #expect(report.cashCollected == 1_000)
        #expect(report.warnings.isEmpty)

        ledger.paymentApplications.append(PropertyPaymentApplication(propertyID: property.id,
            paymentTransactionID: paymentID, obligationID: rentID, residentID: resident.id, amount: 200))
        report = PropertySettlementCalculator.report(propertyID: property.id, month: month,
            ledger: ledger, transactions: [payment])
        #expect(report.collected == 0)
        #expect(report.cashCollected == 0)
        #expect(report.advanceAvailable == 0)
        #expect(report.warnings.contains { $0.contains("superan su importe") })
    }

    @Test("Maintenance recovery uses actual owner investment, per-rent-month cap, and late collections")
    func maintenanceRecoveryAndReserve() {
        let property = PropertyRecord(name: "Casa de prueba")
        let starts = date(2026, 11)
        let ends = date(2027, 10)
        let program = PropertyMaintenanceProgram(propertyID: property.id, startsAt: starts, endsAt: ends)
        let resident = PropertyResident(propertyID: property.id, name: "Alex", activeFrom: starts,
                                        referenceMonthlyIncome: 10_000)
        let spendID = UUID()
        let receiptID = UUID()
        let lateMonth = date(2027, 10)
        let receiptDate = date(2028, 2)
        let lateReceiptID = UUID()
        var ledger = PropertyLedger()
        ledger.properties = [property]
        ledger.residents = [resident]
        ledger.maintenancePrograms = [program]
        ledger.attributions = [PropertyTransactionAttribution(propertyID: property.id,
            transactionID: spendID, kind: .maintenance, responsibility: .owner,
            maintenanceProgramID: program.id)]
        ledger.paymentApplications = [
            PropertyPaymentApplication(propertyID: property.id, paymentTransactionID: receiptID,
                obligationID: UUID.deterministic(property.id, starts, "rent"), residentID: resident.id, amount: 3_000),
            PropertyPaymentApplication(propertyID: property.id, paymentTransactionID: lateReceiptID,
                obligationID: UUID.deterministic(property.id, lateMonth, "rent"), residentID: resident.id, amount: 3_000),
        ]
        ledger.reserveMovements = [PropertyReserveMovement(id: UUID(), propertyID: property.id,
            amount: 600, reason: "Aportación manual", createdAt: starts)]
        let inputs = [
            PropertyTransactionInput(id: spendID, amount: -18_000, postedAt: date(2026, 11, 3),
                description: "Reparación", isCashAccount: false),
            PropertyTransactionInput(id: receiptID, amount: 3_000, postedAt: date(2026, 11, 20),
                description: "Renta", isCashAccount: true),
            PropertyTransactionInput(id: lateReceiptID, amount: 3_000, postedAt: receiptDate,
                description: "Renta atrasada", isCashAccount: true),
        ]
        let summary = PropertyMaintenanceCalculator.summary(program: program, ledger: ledger, transactions: inputs)
        #expect(summary.invested == 18_000)
        #expect(summary.budgetAvailable == 6_000)
        #expect(summary.recovered == 4_000)
        #expect(summary.capitalPending == 14_000)
        #expect(summary.reserveAvailable == 600)
    }

    @Test("Overallocated cash cannot fund maintenance recovery")
    func maintenanceRejectsOverallocatedRentReceipt() {
        let property = PropertyRecord(name: "Casa de prueba")
        let month = date(2026, 11)
        let program = PropertyMaintenanceProgram(propertyID: property.id, startsAt: month,
                                                 endsAt: date(2027, 10))
        let resident = PropertyResident(propertyID: property.id, name: "Alex", activeFrom: month,
                                        referenceMonthlyIncome: 10_000)
        let spendID = UUID()
        let receiptID = UUID()
        let rentID = UUID.deterministic(property.id, month, "rent")
        var ledger = PropertyLedger()
        ledger.properties = [property]
        ledger.residents = [resident]
        ledger.maintenancePrograms = [program]
        ledger.attributions = [PropertyTransactionAttribution(propertyID: property.id,
            transactionID: spendID, kind: .maintenance, responsibility: .owner,
            maintenanceProgramID: program.id)]
        ledger.paymentApplications = [
            PropertyPaymentApplication(propertyID: property.id, paymentTransactionID: receiptID,
                obligationID: rentID, residentID: resident.id, amount: 3_000),
            PropertyPaymentApplication(propertyID: property.id, paymentTransactionID: receiptID,
                obligationID: UUID(), residentID: resident.id, amount: 1),
        ]
        let inputs = [
            PropertyTransactionInput(id: spendID, amount: -1_000, postedAt: date(2026, 11, 3),
                description: "Reparación"),
            PropertyTransactionInput(id: receiptID, amount: 3_000, postedAt: date(2026, 11, 20),
                description: "Renta", isCashAccount: true),
        ]

        let summary = PropertyMaintenanceCalculator.summary(program: program, ledger: ledger, transactions: inputs)

        #expect(summary.invested == 1_000)
        #expect(summary.recovered == 0)
        #expect(summary.warnings.contains { $0.contains("superan su importe") })
    }

    @Test("Representative monthly calculation handles 1,000 real expenses within the response target")
    func representativeReportLatency() {
        let property = PropertyRecord(name: "Casa de prueba")
        let month = date(2026, 11)
        let residents = [
            PropertyResident(propertyID: property.id, name: "Alex", activeFrom: month, referenceMonthlyIncome: 5_880),
            PropertyResident(propertyID: property.id, name: "Fer", activeFrom: month, referenceMonthlyIncome: 20_000),
            PropertyResident(propertyID: property.id, name: "Sam", activeFrom: month, referenceMonthlyIncome: 7_000),
        ]
        var ledger = PropertyLedger()
        ledger.properties = [property]
        ledger.residents = residents
        ledger.incomes = residents.map { confirmedIncome(property.id, $0.id, month, $0.referenceMonthlyIncome) }
        ledger.rents = [PropertyRentAgreement(propertyID: property.id, monthlyAmount: 3_000, effectiveMonth: month)]
        var transactions: [PropertyTransactionInput] = []
        for index in 0..<1_000 {
            let id = UUID()
            transactions.append(PropertyTransactionInput(id: id, amount: -Decimal(index + 1),
                postedAt: Calendar.current.date(byAdding: .day, value: index % 28, to: month)!,
                description: "Gasto \(index)", isCashAccount: false))
            ledger.attributions.append(PropertyTransactionAttribution(propertyID: property.id,
                transactionID: id, kind: .operation, responsibility: .shared))
        }
        let start = ProcessInfo.processInfo.systemUptime
        let report = PropertySettlementCalculator.report(propertyID: property.id, month: month,
            ledger: ledger, transactions: transactions)
        let elapsedMilliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1_000
        print("Property report, 1,000 attributed expenses: \(elapsedMilliseconds) ms")
        #expect(report.expenses == (1...1_000).reduce(Decimal.zero) { $0 + Decimal($1) })
        #expect(elapsedMilliseconds < 100)
    }

    @Test("Property ledger persists atomically, merges newer edits, reports close conflicts, and rejects corruption")
    func persistenceMergeAndCorruption() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("property-ledger-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("PropertyLedger.json")
        let property = PropertyRecord(name: "Casa", createdAt: date(2026, 1), updatedAt: date(2026, 1))
        var local = PropertyLedger()
        local.properties = [property]
        try PropertyLedgerStore.replace(with: local, at: url, notify: false)

        var incoming = local
        incoming.properties[0].name = "Casa renovada"
        incoming.properties[0].updatedAt = date(2026, 2)
        let resident = PropertyResident(propertyID: property.id, name: "Alex", activeFrom: date(2026, 1))
        incoming.residents = [resident]
        let close = PropertySettlementClose(id: UUID(), propertyID: property.id, monthStart: date(2026, 1),
            closedAt: date(2026, 2), residents: [], obligations: [], totalObligations: 0, warnings: [])
        incoming.closes = [close]
        let warnings = try PropertyLedgerStore.merge(incoming, at: url, notify: false)
        #expect(try PropertyLedgerStore.read(fileURL: url).properties.first?.name == "Casa renovada")

        var conflict = incoming
        conflict.closes[0].totalObligations = 500
        let conflicts = try PropertyLedgerStore.merge(conflict, at: url, notify: false)
        #expect(conflicts.count == 1)
        #expect(warnings.isEmpty)

        let tombstoneURL = root.appendingPathComponent("tombstones/PropertyLedger.json")
        var active = PropertyLedger()
        var deletedProperty = property
        deletedProperty.name = "Casa eliminada"
        deletedProperty.updatedAt = date(2026, 3)
        deletedProperty.deletedAt = date(2026, 3)
        active.properties = [deletedProperty]
        try PropertyLedgerStore.replace(with: active, at: tombstoneURL, notify: false)
        var stale = PropertyLedger()
        stale.properties = [property]
        _ = try PropertyLedgerStore.merge(stale, at: tombstoneURL, notify: false)
        #expect(try PropertyLedgerStore.read(fileURL: tombstoneURL).activeProperties.isEmpty)

        let blocker = root.appendingPathComponent("not-a-directory")
        let originalBytes = Data("preserve".utf8)
        try originalBytes.write(to: blocker)
        #expect(throws: (any Error).self) {
            try PropertyLedgerStore.replace(with: local, at: blocker.appendingPathComponent("ledger.json"), notify: false)
        }
        #expect(try Data(contentsOf: blocker) == originalBytes)

        try Data("{not-json".utf8).write(to: url)
        #expect(throws: (any Error).self) { try PropertyLedgerStore.read(fileURL: url) }
    }

    @Test("Account detail scopes filter activity rows by identity")
    @MainActor
    func accountDetailScopesFilterByIdentity() throws {
        let property = PropertyRecord(name: "Casa de prueba")
        let october = date(2026, 10)
        let alex = PropertyResident(propertyID: property.id, name: "Alex", activeFrom: october,
                                    referenceMonthlyIncome: 1_000)
        let sam = PropertyResident(propertyID: property.id, name: "Sam", activeFrom: october,
                                   referenceMonthlyIncome: 1_000)
        let sharedID = UUID()
        let individualID = UUID()
        let reimbursementID = UUID()
        var ledger = PropertyLedger()
        ledger.properties = [property]
        ledger.residents = [alex, sam]
        ledger.incomes = [confirmedIncome(property.id, alex.id, october, 1_000),
                          confirmedIncome(property.id, sam.id, october, 1_000)]
        ledger.attributions = [
            PropertyTransactionAttribution(propertyID: property.id, transactionID: sharedID,
                kind: .operation, responsibility: .shared),
            PropertyTransactionAttribution(propertyID: property.id, transactionID: individualID,
                kind: .operation, responsibility: .individual(residentID: alex.id)),
            PropertyTransactionAttribution(propertyID: property.id, transactionID: reimbursementID,
                kind: .reimbursement, responsibility: .owner),
        ]
        let inputs = [
            PropertyTransactionInput(id: sharedID, amount: -600, postedAt: date(2026, 10, 15),
                description: "Compra compartida"),
            PropertyTransactionInput(id: individualID, amount: -250, postedAt: date(2026, 10, 20),
                description: "Gasto de Alex"),
            PropertyTransactionInput(id: reimbursementID, amount: 80, postedAt: date(2026, 10, 22),
                description: "Reembolso", isCashAccount: true),
        ]
        // The month is closed, so the report is frozen and its activity rows
        // render the concatenated split instead of "Shared".
        let original = PropertySettlementCalculator.report(propertyID: property.id, month: october,
            ledger: ledger, transactions: inputs)
        let close = try #require(PropertySettlementCalculator.close(original))
        ledger.closes = [close]
        let frozen = PropertySettlementCalculator.frozenReport(close, ledger: ledger, transactions: inputs)
        let rows = PropertyActivityPresenter.rows(propertyID: property.id, month: october, asOf: .distantFuture,
            filter: .linked, ledger: ledger, report: frozen, inputs: inputs)

        #expect(rows.count == 3)
        let shared = try #require(rows.first { $0.id == sharedID })
        let individual = try #require(rows.first { $0.id == individualID })
        let reimbursement = try #require(rows.first { $0.id == reimbursementID })
        #expect(shared.isClosed && individual.isClosed && reimbursement.isClosed)
        #expect(shared.responsibility.contains("·")) // Concatenated closed label, never "Shared".
        #expect(shared.identity == .shared)
        #expect(individual.identity == .individual(alex.id))
        #expect(reimbursement.identity == nil)

        let account = PropertyMemberAccount.account(propertyID: property.id, residentID: alex.id,
            report: frozen, ledger: ledger, inputs: inputs, asOf: .distantFuture,
            context: .init(canCalculate: true, isClosed: true, historical: false, includeCurrent: true))
        #expect(try #require(account.houseSharedTotal) == 600)
        #expect(try #require(account.individualCharges) == 250)

        let sharedScope = PropertyActivityColumnFilters(identities: [.shared]).apply(to: rows)
        #expect(sharedScope.map(\.id) == [sharedID])
        #expect(sharedScope.compactMap(\.amount).reduce(Decimal.zero, +) == account.houseSharedTotal)

        let memberScope = PropertyActivityColumnFilters(identities: [.individual(alex.id)]).apply(to: rows)
        #expect(memberScope.map(\.id) == [individualID])
        #expect(memberScope.compactMap(\.amount).reduce(Decimal.zero, +) == account.individualCharges)
    }

    @Test("A selected single-member scope stays shared")
    @MainActor
    func selectedSingleMemberStaysShared() throws {
        let property = PropertyRecord(name: "Casa de prueba")
        let november = date(2026, 11)
        let alex = PropertyResident(propertyID: property.id, name: "Alex", activeFrom: november,
                                    referenceMonthlyIncome: 1_000)
        let chargeID = UUID()
        var ledger = PropertyLedger()
        ledger.properties = [property]
        ledger.residents = [alex]
        ledger.incomes = [confirmedIncome(property.id, alex.id, november, 1_000)]
        ledger.attributions = [PropertyTransactionAttribution(propertyID: property.id,
            transactionID: chargeID, kind: .operation, responsibility: .selected(residentIDs: [alex.id]))]
        let inputs = [PropertyTransactionInput(id: chargeID, amount: -400, postedAt: date(2026, 11, 12),
            description: "Compra del grupo")]
        let report = PropertySettlementCalculator.report(propertyID: property.id, month: november,
            ledger: ledger, transactions: inputs)
        let rows = PropertyActivityPresenter.rows(propertyID: property.id, month: november, asOf: .distantFuture,
            filter: .linked, ledger: ledger, report: report, inputs: inputs)

        let row = try #require(rows.first { $0.id == chargeID })
        // The label collides with Alex's individual-scope label, but the
        // identity stays shared because houseSharedTotal counts `.selected`.
        #expect(row.responsibility == "Alex")
        #expect(row.identity == .shared)
        #expect(PropertyActivityColumnFilters(identities: [.individual(alex.id)]).apply(to: rows).isEmpty)

        let account = PropertyMemberAccount.account(propertyID: property.id, residentID: alex.id,
            report: report, ledger: ledger, inputs: inputs, asOf: .distantFuture,
            context: .init(canCalculate: true, isClosed: false, historical: false, includeCurrent: true))
        #expect(try #require(account.houseSharedTotal) == 400)
        #expect(try #require(account.individualCharges) == 0)
        let sharedScope = PropertyActivityColumnFilters(identities: [.shared]).apply(to: rows)
        #expect(sharedScope.map(\.id) == [chargeID])
        #expect(sharedScope.compactMap(\.amount).reduce(Decimal.zero, +) == account.houseSharedTotal)
    }

    // MARK: - Workspace model (moved from the former PropertyWorkspaceTests and
    // PropertyMonthlyRefactorTests suites). Pure ledger/workspace tests live here;
    // container-backed ones live in HouseholdSettlementReportTests.

    private var november2026: Date { YearMonth(year: 2026, month: 11).startDate }
    private var march2026: Date { YearMonth(year: 2026, month: 3).startDate }

    private actor DelayedRead {
        private var result: CheckedContinuation<PropertyLedger, Never>?
        private var started: CheckedContinuation<Void, Never>?

        func read() async -> PropertyLedger {
            await withCheckedContinuation { continuation in
                result = continuation
                started?.resume()
                started = nil
            }
        }

        func waitForStart() async {
            if result != nil { return }
            await withCheckedContinuation { started = $0 }
        }

        func finish(_ ledger: PropertyLedger) { result?.resume(returning: ledger); result = nil }
    }

    @Test("Navigation retains the month, observes renames, and falls back after removal")
    @MainActor
    func navigationAndInventory() {
        let workspace = PropertyWorkspaceModel(month: november2026, asOf: .distantFuture)
        var property = PropertyRecord(name: "Casa norte")
        var ledger = PropertyLedger()
        ledger.properties = [property]
        workspace.applyLedger(ledger)
        workspace.destination = .property(property.id)
        workspace.section = .configuration
        workspace.shiftMonth(-1)
        let selectedMonth = workspace.selectedMonth
        workspace.destination = .household
        #expect(workspace.selectedMonth == selectedMonth)
        #expect(workspace.section == .month)
        workspace.destination = .property(property.id)
        property.name = "Casa del norte"
        ledger.properties = [property]
        workspace.applyLedger(ledger)
        #expect(workspace.title == "Casa del norte")
        #expect(workspace.destination == .property(property.id))
        ledger.properties[0].deletedAt = november2026
        workspace.applyLedger(ledger)
        #expect(workspace.destination == .allHomes)
        #expect(workspace.selectedMonth == selectedMonth)
    }

    @Test("Navigation and reopening never seed or rewrite the ledger")
    @MainActor
    func readOnlyNavigation() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("PropertyLedger.json")
        var ledger = PropertyLedger()
        ledger.properties = [PropertyRecord(name: "Casa norte")]
        try PropertyLedgerStore.replace(with: ledger, at: url, notify: false)
        let before = try Data(contentsOf: url)
        let workspace = PropertyWorkspaceModel(month: november2026, asOf: .distantFuture, fileURL: url)
        await workspace.loadLedger()
        workspace.destination = .household
        workspace.shiftMonth(-1)
        workspace.destination = .allHomes
        #expect(try Data(contentsOf: url) == before)
        #expect(workspace.properties.count == 1)
        #expect(workspace.ledger.residents.isEmpty)
    }

    @Test("Corrupt reads and failed saves preserve the file and recoverable error")
    @MainActor
    func failedPersistence() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("PropertyLedger.json")
        let bad = Data("corrupt".utf8)
        try bad.write(to: url)
        let workspace = PropertyWorkspaceModel(month: november2026, asOf: .distantFuture, fileURL: url)
        await workspace.loadLedger()
        #expect(!workspace.ledgerAvailable)
        #expect(workspace.error != nil)
        #expect(!workspace.save())
        #expect(try Data(contentsOf: url) == bad)
        try PropertyLedgerStore.replace(with: PropertyLedger(), at: url, notify: false)
        await workspace.loadLedger()
        #expect(workspace.ledgerAvailable)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        workspace.ledger.properties = [PropertyRecord(name: "No guardada")]
        #expect(!workspace.save())
        #expect(workspace.ledger.properties.isEmpty)
        #expect(workspace.error != nil)
    }

    @Test("A delayed read cannot replace a newer successful edit")
    @MainActor
    func staleReadAfterSave() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("ledger.json")
        let old = PropertyLedger()
        try PropertyLedgerStore.replace(with: old, at: url, notify: false)
        let read = DelayedRead()
        let workspace = PropertyWorkspaceModel(month: november2026, asOf: .distantFuture, fileURL: url, readLedger: { _ in await read.read() })
        workspace.applyLedger(old)
        let loading = Task { await workspace.loadLedger() }
        await read.waitForStart()
        let property = PropertyRecord(name: "Casa norte")
        workspace.ledger.properties.append(property)
        #expect(workspace.save())
        await read.finish(old)
        await loading.value
        #expect(workspace.properties.map(\.id) == [property.id])
        #expect(try PropertyLedgerStore.read(fileURL: url).properties.map(\.id) == [property.id])
    }

    @Test("Reading v1 upgrades in memory without changing original bytes")
    func legacyReadIsNonMutating() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("property-ledger-v1-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var legacy = PropertyLedger(); legacy.schemaVersion = 1
        let bytes = try encoder.encode(legacy)
        try bytes.write(to: url)
        let read = try PropertyLedgerStore.read(fileURL: url)
        #expect(read.schemaVersion == 2)
        #expect(read.householdLink == nil)
        #expect(try Data(contentsOf: url) == bytes)
        try PropertyLedgerStore.replace(with: read, at: url, notify: false)
        #expect(try PropertyLedgerStore.read(fileURL: url).schemaVersion == 2)
    }

    @Test("Late real payments reduce their month; future payments and reused receipts do not")
    func asOfCollections() throws {
        let property = PropertyRecord(name: "Casa de prueba")
        let resident = PropertyResident(propertyID: property.id, name: "Integrante", activeFrom: march2026, referenceMonthlyIncome: 100)
        var ledger = PropertyLedger(); ledger.properties = [property]; ledger.residents = [resident]
        ledger.incomes = [PropertyIncome(propertyID: property.id, residentID: resident.id, monthStart: march2026, amount: 100, confirmedAt: march2026)]
        ledger.rents = [PropertyRentAgreement(propertyID: property.id, monthlyAmount: 1000, effectiveMonth: march2026)]
        let report = PropertySettlementCalculator.report(propertyID: property.id, month: march2026, ledger: ledger, transactions: [])
        let obligation = try #require(report.obligations.first)
        let late = Calendar.current.date(byAdding: .month, value: 1, to: march2026)!
        let future = Calendar.current.date(byAdding: .month, value: 2, to: march2026)!
        let receipt = PropertyTransactionInput(id: UUID(), amount: 600, postedAt: late, description: "Cobro tardío", isCashAccount: true)
        let futureReceipt = PropertyTransactionInput(id: UUID(), amount: 200, postedAt: future, description: "Cobro futuro", isCashAccount: true)
        ledger.paymentApplications = [receipt, futureReceipt].map {
            PropertyPaymentApplication(propertyID: property.id, paymentTransactionID: $0.id, obligationID: obligation.id, residentID: resident.id, amount: $0.amount)
        }
        let consulted = PropertySettlementCalculator.report(propertyID: property.id, month: march2026, ledger: ledger, transactions: [receipt, futureReceipt], asOf: late)
        #expect(consulted.collected == 600)
        #expect(consulted.residents.first?.balance == 400)
        let close = try #require(PropertySettlementCalculator.close(report))
        ledger.closes = [close]
        let frozen = PropertySettlementCalculator.frozenReport(close, ledger: ledger, transactions: [receipt, futureReceipt], asOf: late)
        #expect(frozen.collected == 600)
        #expect(frozen.residents.first?.balance == 400)
        let other = PropertyRecord(name: "Otra casa"); ledger.properties.append(other)
        let otherResident = PropertyResident(propertyID: other.id, name: "Otro", activeFrom: march2026)
        ledger.residents.append(otherResident)
        ledger.paymentApplications.append(PropertyPaymentApplication(propertyID: other.id, paymentTransactionID: receipt.id, obligationID: UUID(), residentID: otherResident.id, amount: 1))
        #expect(!PropertyLedgerStore.validate(ledger).isEmpty)
    }

    @Test("Participation stops from the later of the selected and actual current month")
    func participationBoundaries() {
        let today = YearMonth(year: 2026, month: 10).startDate
        #expect(PropertyParticipation.lastActiveMonth(selected: march2026, today: today) == date(2026, 9))
        let future = YearMonth(year: 2027, month: 2).startDate
        #expect(PropertyParticipation.lastActiveMonth(selected: future, today: today) == date(2027, 1))
    }
}
