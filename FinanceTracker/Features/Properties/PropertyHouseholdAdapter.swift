import Foundation

@MainActor
enum PropertyHouseholdAdapter {
    // Stable role identities, independent of names, income, and local device.
    static let link = PropertyHouseholdLink(
        propertyID: UUID(uuidString: "CB4E0746-1E54-5F81-95DD-A844285389B0")!,
        userID: UUID(uuidString: "39D8FC02-CE45-54B7-B594-243A9D100B11")!,
        partnerID: UUID(uuidString: "A684A056-044A-51BE-9726-729D66E8CB32")!, updatedAt: .distantPast)

    static func activeMemberIDs(ledger: PropertyLedger, month: Date) -> Set<UUID> {
        let roles = ledger.householdLink ?? link
        let active = Set(ledger.residents(for: roles.propertyID, month: month).map(\.id))
        return Set([roles.userID, roles.partnerID].filter { id in
            !ledger.residents.contains(where: { $0.id == id }) || active.contains(id)
        })
    }

    static func report(_ source: HouseholdSettlementReport, ledger: PropertyLedger,
                       transactions: [PropertyTransactionInput], asOf: Date) -> PropertyMonthlyReport {
        let roles = ledger.householdLink ?? link
        let activeIDs = activeMemberIDs(ledger: ledger, month: source.monthStart)
        let config = ledger.householdMonths?.first { $0.monthStart == source.monthStart && $0.deletedAt == nil }
        let existingClose = ledger.closes.first { $0.propertyID == roles.propertyID && $0.monthStart == source.monthStart }
        let obligations =
            source.sharedRows.map { row in
                obligation(row, monthStart: source.monthStart, responsibility: .shared,
                    allocations: [roles.userID: row.userShare, roles.partnerID: row.partnerShare])
            }
            + source.ferRows.map { row in
                obligation(row, monthStart: source.monthStart,
                    responsibility: .individual(residentID: roles.partnerID),
                    allocations: [roles.partnerID: row.amount])
            }
            + source.userRows.map { row in
                obligation(row, monthStart: source.monthStart,
                    responsibility: .individual(residentID: roles.userID),
                    allocations: [roles.userID: row.amount])
            }
        let members = [
            PropertyResidentSnapshot(id: roles.userID, name: ledger.residents.first { $0.id == roles.userID }?.name ?? String(localized: "You"), income: source.userSalaryIncome,
                share: source.userIncomeShare, obligation: source.userFairShare + source.userOnlyTotal, paid: 0),
            PropertyResidentSnapshot(id: roles.partnerID, name: ledger.residents.first { $0.id == roles.partnerID }?.name ?? "Fer", income: source.partnerIncomeEstimate,
                share: source.partnerIncomeShare, obligation: source.amountToRecoverFromPartner, paid: 0)
        ]
        let snapshot = existingClose ?? PropertySettlementClose(id: .deterministic(roles.propertyID, source.monthStart, "household-preview"),
            propertyID: roles.propertyID, monthStart: source.monthStart, closedAt: asOf, residents: members,
            obligations: obligations, totalObligations: members.reduce(0) { $0 + $1.obligation }, warnings: [])
        var adaptedLedger = ledger
        adaptedLedger.householdLink = roles
        var report = PropertySettlementCalculator.frozenReport(snapshot, ledger: adaptedLedger, transactions: transactions, asOf: asOf)
        // A source expense was paid by the user when it was recorded. Do not request it a second time.
        if let index = report.residents.firstIndex(where: { $0.id == roles.userID }) {
            let paidDirectly = existingClose?.residents.first { $0.id == roles.userID }?.directContribution
                ?? max(0, report.residents[index].sharedExpenses + report.residents[index].individualExpenses)
            report.residents[index].directContribution = paidDirectly
            if existingClose == nil { report.residents[index].paid += paidDirectly }
        }
        if existingClose == nil {
            report.residents = report.residents.map { row in
                var row = row
                row.confirmed = !activeIDs.contains(row.id) || (row.id == roles.userID ? config?.userConfirmedAt != nil : config?.partnerConfirmedAt != nil)
                return row
            }
            for obligation in obligations where obligation.allocations.contains(where: { !activeIDs.contains($0.key) && $0.value > 0 }) {
                report.warnings.append(String(format: String(localized: "Assignment needs review: %@. A member no longer participates in this period."), obligation.title))
            }
            if !activeIDs.contains(roles.partnerID) {
                for row in source.deferredFerRows {
                    report.warnings.append(String(format: String(localized: "Assignment needs review: %@. A member no longer participates in this period."), row.transaction.descriptionRaw))
                }
            }
            if activeIDs.isEmpty { report.warnings.append(String(localized: "There are no active members in this period.")) }
            else if !source.splitAvailable { report.warnings.append("Confirma los ingresos para calcular el reparto.") }
            if report.residents.contains(where: { !$0.confirmed }) { report.warnings.append("Hay ingresos por confirmar en la tabla.") }
        }
        return report
    }

    /// One household row as a property obligation. The deterministic id, title,
    /// kind, amount, transaction link, and source snapshots never vary — only
    /// the responsibility and allocations do, per source list. The shared pot
    /// (monthly split and custom amounts) stays `.shared`; a one-member row is
    /// an individual charge of exactly that member, keeping the allocation sum
    /// each resident already had so balances and obligations cannot move.
    private static func obligation(_ row: HouseholdSettlementRow, monthStart: Date,
                                   responsibility: PropertyResponsibility,
                                   allocations: [UUID: Decimal]) -> PropertyObligationSnapshot {
        PropertyObligationSnapshot(id: .deterministic(row.id, monthStart, "household-obligation"),
            title: row.transaction.descriptionRaw, kind: .operation, amount: row.amount,
            allocations: allocations, transactionID: row.id, responsibility: responsibility,
            sourcePostedAt: row.transaction.postedAt, sourceCurrencyCode: row.transaction.currency)
    }

    static func closedSummary(_ close: PropertySettlementClose) -> String {
        var lines = ["\(PropertyDestination.householdName) — \(propertyMonthText(close.monthStart))",
                     String(localized: "Calculation closed"), "", String(localized: "Monthly obligations")]
        for member in close.residents {
            lines.append(String(format: String(localized: "%@: income %@ · obligation %@"),
                member.name, propertyMoneyText(member.income), propertyMoneyText(member.obligation)))
        }
        lines.append("")
        lines.append(String(localized: "Linked transactions"))
        for obligation in close.obligations { lines.append("\(obligation.title): \(propertyMoneyText(obligation.amount))") }
        return lines.joined(separator: "\n")
    }
}
