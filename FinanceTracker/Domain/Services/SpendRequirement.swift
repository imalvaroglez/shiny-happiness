import Foundation

struct SpendRequirement: Codable, Equatable, Identifiable {
    let accountID: UUID
    var name: String
    var amount: Decimal
    var currency: String
    var statementClosingDay: Int
    var adjustToPreviousBusinessDay: Bool
    var additionalNonBusinessDates: [String] = []
    var enabled = true
    var lastModifiedAt = Date.now

    var id: UUID { accountID }

    func validate() -> [String] {
        var issues: [String] = []
        if amount <= 0 { issues.append("El importe debe ser mayor que cero.") }
        if !(1...31).contains(statementClosingDay) { issues.append("El día de corte debe estar entre 1 y 31.") }
        if currency.count != 3 { issues.append("La moneda debe ser un código de tres letras.") }
        if additionalNonBusinessDates.contains(where: { !MexicoBankingCalendar.isISODate($0) }) {
            issues.append("Hay una fecha inhábil adicional inválida.")
        }
        return issues
    }

    static func suggested(for account: Account) -> SpendRequirement? {
        guard account.type == .creditCard,
              account.institution.localizedCaseInsensitiveCompare("HSBC") == .orderedSame,
              account.currency == "MXN" else { return nil }
        let name = account.nickname.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es_MX"))
        let day: Int
        if name == "2now de mar" { day = 11 }
        else if name == "2now de alvaro" { day = 9 }
        else { return nil }
        return SpendRequirement(accountID: account.id, name: "Gasto mínimo", amount: 3_500,
                                currency: "MXN", statementClosingDay: day,
                                adjustToPreviousBusinessDay: true)
    }
}

struct SpendRequirementCycle: Equatable {
    let start: Date
    let closingDate: Date
    let nominalClosingDate: Date
    let daysUntilClosing: Int
}

struct SpendRequirementMovement: Equatable {
    enum Kind: Equatable {
        case purchase
        case refund
        case ambiguousCredit
        case excluded
    }

    let id: UUID
    let date: Date
    let amount: Decimal
    let currency: String
    let kind: Kind
    var isDeleted = false
    var isDuplicate = false
}

struct SpendRequirementProgress: Equatable {
    let requirement: SpendRequirement
    let cycle: SpendRequirementCycle
    let eligibleSpend: Decimal
    let ambiguousCreditTotal: Decimal
    let reviewMovementIDs: [UUID]

    var remaining: Decimal { max(requirement.amount - eligibleSpend, 0) }
    var progress: Decimal { max(eligibleSpend / requirement.amount, 0) }
    var isPotentiallyAmbiguous: Bool {
        ambiguousCreditTotal > 0 && eligibleSpend >= requirement.amount
            && eligibleSpend - ambiguousCreditTotal < requirement.amount
    }
    var targetReached: Bool { eligibleSpend >= requirement.amount && !isPotentiallyAmbiguous }
}

enum SpendRequirementCalculation: Equatable {
    case available(SpendRequirementProgress)
    case unavailable(String)
}

struct MexicoBankingCalendar {
    static let timeZone = TimeZone(identifier: "America/Mexico_City")!
    static let officialSources: [Int: String] = [
        2025: "https://sidof.segob.gob.mx/notas/5746258",
        2026: "https://sidof.segob.gob.mx/notas/5775684",
    ]

    private static let officialHolidays: [Int: Set<String>] = [
        2025: ["2025-01-01", "2025-02-03", "2025-03-17", "2025-04-17", "2025-04-18",
               "2025-05-01", "2025-09-16", "2025-11-02", "2025-11-17", "2025-12-12", "2025-12-25"],
        2026: ["2026-01-01", "2026-02-02", "2026-03-16", "2026-04-02", "2026-04-03",
               "2026-05-01", "2026-09-16", "2026-11-02", "2026-11-16", "2026-12-12", "2026-12-25"],
    ]

    let additionalDates: Set<String>

    init(additionalDates: [String] = []) {
        self.additionalDates = Set(additionalDates.filter(Self.isISODate))
    }

    static func isISODate(_ value: String) -> Bool {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter.date(from: value).map { formatter.string(from: $0) == value } ?? false
    }

    func isBusinessDay(_ date: Date, calendar: Calendar) -> Bool? {
        let weekday = calendar.component(.weekday, from: date)
        if weekday == 1 || weekday == 7 { return false }
        let year = calendar.component(.year, from: date)
        guard let holidays = Self.officialHolidays[year] else { return nil }
        let key = Self.isoDate(date, calendar: calendar)
        return !holidays.contains(key) && !additionalDates.contains(key)
    }

    static func isoDate(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

enum SpendRequirementCalculator {
    static func cycle(for requirement: SpendRequirement, asOf: Date,
                      bankingCalendar: MexicoBankingCalendar = .init()) -> SpendRequirementCycle? {
        guard requirement.validate().isEmpty else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = MexicoBankingCalendar.timeZone
        let today = calendar.startOfDay(for: asOf)
        guard let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: today)) else { return nil }
        let scheduledCuts = (-1...2).compactMap { offset -> ClosingCut? in
            guard let month = calendar.date(byAdding: .month, value: offset, to: monthStart) else { return nil }
            return closingDate(year: calendar.component(.year, from: month),
                               month: calendar.component(.month, from: month), requirement: requirement,
                               calendar: calendar, bankingCalendar: bankingCalendar)
        }
        var nominalDatesByClosingDate: [Date: Date] = [:]
        for cut in scheduledCuts { nominalDatesByClosingDate[cut.applied] = cut.nominal }
        let cuts = nominalDatesByClosingDate.keys.sorted()
        guard let closingIndex = cuts.firstIndex(where: { $0 >= today }), closingIndex > 0,
              let start = calendar.date(byAdding: .day, value: 1, to: cuts[closingIndex - 1]) else { return nil }
        let end = cuts[closingIndex]
        let days = calendar.dateComponents([.day], from: today, to: end).day ?? 0
        return SpendRequirementCycle(start: start, closingDate: end,
                                     nominalClosingDate: nominalDatesByClosingDate[end] ?? end,
                                     daysUntilClosing: days)
    }

    static func evaluate(requirement: SpendRequirement, movements: [SpendRequirementMovement],
                         asOf: Date, bankingCalendar: MexicoBankingCalendar = .init()) -> SpendRequirementCalculation {
        guard requirement.enabled else { return .unavailable("El seguimiento está desactivado.") }
        let issues = requirement.validate()
        guard issues.isEmpty else { return .unavailable(issues.joined(separator: " ")) }
        guard let cycle = cycle(for: requirement, asOf: asOf, bankingCalendar: bankingCalendar) else {
            return .unavailable("Calendario pendiente de actualizar o configuración inválida.")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = MexicoBankingCalendar.timeZone
        guard let cycleEndExclusive = calendar.date(byAdding: .day, value: 1, to: cycle.closingDate) else {
            return .unavailable("No se pudo determinar el cierre del ciclo.")
        }
        let relevant = movements.filter {
            !$0.isDeleted && !$0.isDuplicate && $0.currency == requirement.currency
                && $0.date >= cycle.start && $0.date <= asOf && $0.date < cycleEndExclusive
        }
        let purchases = relevant.filter { $0.kind == .purchase }.reduce(Decimal.zero) { $0 + abs($1.amount) }
        let refunds = relevant.filter { $0.kind == .refund }.reduce(Decimal.zero) { $0 + abs($1.amount) }
        let uncertain = relevant.filter { $0.kind == .ambiguousCredit }
        let progress = SpendRequirementProgress(
            requirement: requirement,
            cycle: cycle,
            eligibleSpend: purchases - refunds,
            ambiguousCreditTotal: uncertain.reduce(Decimal.zero) { $0 + abs($1.amount) },
            reviewMovementIDs: uncertain.map(\.id)
        )
        return .available(progress)
    }

    private struct ClosingCut {
        let nominal: Date
        let applied: Date
    }

    private static func closingDate(year: Int, month: Int, requirement: SpendRequirement,
                                    calendar: Calendar, bankingCalendar: MexicoBankingCalendar) -> ClosingCut? {
        var parts = DateComponents(year: year, month: month, day: 1)
        guard let first = calendar.date(from: parts),
              let range = calendar.range(of: .day, in: .month, for: first) else { return nil }
        parts.day = min(requirement.statementClosingDay, range.count)
        guard let nominalDate = calendar.date(from: parts) else { return nil }
        var date = calendar.startOfDay(for: nominalDate)
        guard requirement.adjustToPreviousBusinessDay else {
            return ClosingCut(nominal: date, applied: date)
        }
        while true {
            guard let isBusinessDay = bankingCalendar.isBusinessDay(date, calendar: calendar) else { return nil }
            if isBusinessDay { return ClosingCut(nominal: calendar.startOfDay(for: nominalDate), applied: date) }
            guard let previous = calendar.date(byAdding: .day, value: -1, to: date) else { return nil }
            date = previous
        }
    }
}

enum SpendRequirementMovementClassifier {
    private static let refunds = ["refund", "reversal", "returned merchandise", "devolucion", "devolucion compra", "reembolso", "anulacion", "cancelacion compra"]
    private static let rewards = ["cashback", "cash back", "recompensa", "rewards", "bonificacion", "bonificacion puntos"]
    private static let excluded = ["interes", "interest", "finance charge", "comision", "commission", "bank fee", "fees & charges", "anualidad", "annual fee", "membresia", "cuota anual", "cargo por pago tardio", "late fee", "retiro de efectivo", "retiro efectivo", "cash withdrawal", "atm withdrawal", "avance de efectivo", "cash advance", "disposicion de efectivo", "disposicion efectivo"]

    static func classify(amount: Decimal, flowKind: TransactionFlowKind, treatment: TransactionTreatmentKind,
                         description: String, category: String, isDuplicate: Bool, isDeleted: Bool,
                         isTransfer: Bool, isPaymentCategory: Bool, isTransferCategory: Bool,
                         isSynthesizedMSI: Bool) -> SpendRequirementMovement.Kind {
        guard !isDuplicate, !isDeleted, !isTransfer, !isPaymentCategory, !isTransferCategory,
              treatment == .regular else { return .excluded }
        let text = normalized(description + " " + category)
        if excluded.contains(where: { text.contains($0) }) { return .excluded }
        if amount < 0 {
            guard (flowKind == .charge || flowKind == .expense), !isSynthesizedMSI else { return .excluded }
            return .purchase
        }
        guard amount > 0 && (flowKind == .cardCredit || flowKind == .income) else { return .excluded }
        if rewards.contains(where: { text.contains($0) }) { return .excluded }
        if refunds.contains(where: { text.contains($0) }) { return .refund }
        return .ambiguousCredit
    }

    static func classify(_ transaction: Transaction) -> SpendRequirementMovement.Kind {
        let category = transaction.category
        return classify(amount: transaction.amount, flowKind: transaction.flowKind,
                        treatment: transaction.treatmentKind,
                        description: transaction.descriptionRaw, category: category?.name ?? "",
                        isDuplicate: transaction.isDuplicate, isDeleted: transaction.deletedAt != nil,
                        isTransfer: transaction.isTransfer,
                        isPaymentCategory: category?.kind == .creditCardPayment,
                        isTransferCategory: category?.kind == .transfer,
                        isSynthesizedMSI: TransactionClassifier.isSynthesizedMSIPurchase(transaction))
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es_MX"))
    }
}
