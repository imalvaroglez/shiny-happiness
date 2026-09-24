import Foundation

/// Resultado del evaluador por promoción. Value type puro; se construye en @MainActor
/// con modelos vivos (molde AD-022 / HouseholdSettlementReport) y viaja al UI como valor.
struct PromotionProgress: Equatable {
    let definitionID: String
    let displayName: String

    enum Calculability: Equatable {
        case calculable
        /// Clase ①: falta un dato esencial — sin número de progreso, solo qué falta (spec C).
        case notCalculable(String)
    }
    let calculability: Calculability

    /// Suma de cargos elegibles firmes. Lo dudoso jamás se suma aquí (spec C).
    let eligibleFirm: Decimal

    struct RowOutcome: Equatable {
        enum Outcome: Equatable {
            case eligible
            case excluded
            /// Clase ③: identificada, fuera del firme, con dirección (sumar/restar).
            case review(direction: Direction)
            /// Crédito/reversión conservado como evidencia de conciliación (etapa a — spec G.1a).
            case evidence
            enum Direction: Equatable { case couldAdd, couldSubtract }
        }
        let transactionID: UUID
        let outcome: Outcome
        let reason: String
        // Material fuente embebido (patrón BreakdownSheet): la fila se explica sola en el UI.
        let amount: Decimal
        let descriptor: String
        let postedAt: Date
    }

    let rows: [RowOutcome]

    /// Cargo nacional ≥ umbral que el emisor puede convertir a MSI: se señala SIN descontar del firme.
    struct ConversionRisk: Equatable {
        let transactionID: UUID
        let amount: Decimal
    }

    var conversionRisks: [ConversionRisk] = []

    /// Banda de incertidumbre (v4-g): el firme es provisional cuando estas cifras pueden
    /// cambiar el desenlace. Nunca se suman al firme — se exhiben por separado.
    var possiblePositiveAddition: Decimal = 0   // filas ③ couldAdd
    var possibleNegativeAdjustment: Decimal = 0 // filas ③ couldSubtract + refunds ambiguos

    // MARK: Estados y resumen por forma (spec F/G-estados; «umbral alcanzado según registros»)

    enum DisplayState: Equatable {
        case enCurso
        /// «Umbral alcanzado según registros» — la calificación real la decide el emisor.
        case thresholdReachedPerRecords
        /// v4-g: ambigüedad pendiente que puede cambiar el desenlace — no se afirma «alcanzado».
        case thresholdSuspended
        case provisional
        case estimated
        case expired(reachedPerRecords: Bool)
        case expiredSuspended
    }

    enum CampaignPhase: Equatable { case upcoming, active, finished }

    struct PeriodOutcome: Equatable {
        let start: String
        let end: String
        enum Phase: Equatable { case closedWon, closedLost, provisional, current, future }
        let phase: Phase
        let firm: Decimal
        let threshold: Decimal
        /// En cerrados-ganados: min(recompensa, tope − ya devengado). En curso/futuro: 0 (sin anticipar).
        let rewardEarned: Decimal
    }

    enum ShapeSummary: Equatable {
        case spendThreshold(target: Decimal, remaining: Decimal)
        case cashback(devengado: Decimal, cap: Decimal, capRemaining: Decimal)
        case tieredPeriods(periods: [PeriodOutcome], earnedTotal: Decimal, annualCap: Decimal)
    }

    var displayState: DisplayState = .enCurso
    var daysRemaining: Int?
    var campaignPhase: CampaignPhase? = nil
    var campaignStartDate: Date? = nil
    var campaignEndDate: Date? = nil
    var deadlineDate: Date? = nil
    var currentGoalReached = false
    var shapeSummary: ShapeSummary = .spendThreshold(target: 0, remaining: 0)

    /// Otras promos de la cuenta que comparten transacciones candidatas (cruce de IDs en
    /// runtime, no intersección de regex — spec G-solapamiento). Advertencia, no resolución.
    var overlaps: [String] = []

    /// Créditos candidatos a recibo, listados SIN asignación (spec G-recibo: un matcher
    /// futuro exigiría resolución conjunta; una colisión permanece sin conciliar).
    struct ReceiptCandidate: Equatable {
        let transactionID: UUID
        let amount: Decimal
        let postedAt: Date
    }
    var receiptCandidates: [ReceiptCandidate] = []
    /// Supuestos declarados de la definición (spec C: se muestran, jamás se inventan).
    var knownUnknowns: [String] = []

    struct Reconciliation: Equatable {
        enum Kind: Equatable { case installmentReversal, refund }
        enum Status: Equatable { case matched, disputed, unmatched }
        let kind: Kind
        let creditTransactionID: UUID
        let candidateChargeIDs: [UUID]
        let amountApplied: Decimal
        let potentialAdjustment: Decimal
        let netContribution: Decimal?
        let status: Status
    }
    var reconciliations: [Reconciliation] = []
}

/// Evaluador de promociones: una pasada por cuenta, etapas explícitas (spec G):
/// a) movimientos válidos (deleted fuera; duplicados visibles-excluidos; créditos = evidencia)
/// b) exclusiones promocionales SOLO sobre cargos elegibles — jamás countsAsRegularExpense
/// c) conciliar MSI/refunds sobre el historial válido y después agregar.
@MainActor
struct PromotionEvaluator {

    private enum ChargeKind: Equatable { case regular, installment, probableInstallment }
    private struct Classified {
        let tx: Transaction
        var outcome: PromotionProgress.RowOutcome.Outcome
        var reason: String
        let chargeKind: ChargeKind?
    }

    func evaluate(definitions: [PromotionDefinition], account: Account,
                  transactions: [Transaction], channelTable: ChannelTable, asOf: Date,
                  channelTableAvailable: Bool = true) -> [PromotionProgress] {
        var results = definitions.map { evaluate($0, account: account, transactions: transactions,
                                                 channelTable: channelTable, asOf: asOf,
                                                 channelTableAvailable: channelTableAvailable) }
        // Solapamiento: cruce de IDs de candidatos (eligible + por revisar) entre promos de la cuenta.
        let candidateIDs: (Int) -> Set<UUID> = { i in
            Set(results[i].rows.compactMap { row -> UUID? in
                switch row.outcome {
                case .eligible, .review: return row.transactionID
                default: return nil
                }
            })
        }
        for i in results.indices {
            let mine = candidateIDs(i)
            var others: [String] = []
            for j in results.indices where j != i {
                if !mine.isDisjoint(with: candidateIDs(j)) {
                    others.append(results[j].definitionID)
                }
            }
            results[i].overlaps = others
        }
        return results
    }

    private func evaluate(_ def: PromotionDefinition, account: Account,
                          transactions: [Transaction], channelTable: ChannelTable, asOf: Date,
                          channelTableAvailable: Bool) -> PromotionProgress {
        // Calculabilidad (clase ①): sin vínculo UUID o sin ventana no hay número.
        guard let uuid = def.accountUUID, uuid == account.id else {
            return notCalculable(def, reason: "desvinculada — se requiere el UUID exacto de la cuenta")
        }
        guard let window = Self.resolveWindow(def.window) else {
            return notCalculable(def, reason: "ventana desconocida — falta definirla (T&C pendiente)")
        }
        let needsChannelTable = def.scope.excludeThirdParties
            || (def.scope.requireChannel == .physicalOnly && def.scope.merchants.contains { $0.channel == nil })
        let missingAggregatorRules = def.scope.excludeThirdParties
            && !channelTable.entries.contains { $0.channel == .aggregator && $0.pattern != nil }
        guard !needsChannelTable || (channelTableAvailable && !missingAggregatorRules) else {
            return notCalculable(def, reason: "tabla de canal ausente o inválida — revisar configuración")
        }

        // Etapas a/b: movimientos válidos → exclusiones solo sobre cargos.
        // Se clasifica en pares mutables (tx, outcome) para poder conciliar ANTES de agregar.
        var classified: [Classified] = []

        for tx in transactions.sorted(by: Self.transactionOrder) {
            guard tx.account?.id == account.id, tx.postedAt <= asOf, tx.deletedAt == nil else { continue }
            if tx.isDuplicate {
                classified.append(Classified(tx: tx, outcome: .excluded, reason: "duplicado", chargeKind: nil))
                continue
            }
            if tx.amount > 0 {
                let possibleReversal = def.msiPolicy.reversalPatterns.contains {
                    Self.matches($0, descriptor: tx.descriptionRaw)
                }
                if tx.flowKind == .cardCredit || possibleReversal {
                    classified.append(Classified(tx: tx, outcome: .evidence,
                                                  reason: "crédito/abono — evidencia", chargeKind: nil))
                } else {
                    classified.append(Classified(tx: tx, outcome: .excluded,
                        reason: "pago/transferencia — no es compra ni crédito de tarjeta", chargeKind: nil))
                }
                continue
            }
            let detectedKind = installmentKind(tx.descriptionRaw)
            let row = classifyCharge(tx, def: def, window: window, channelTable: channelTable, kind: detectedKind)
            let validOriginal = isStructurallyEligibleCharge(tx, def: def)
            classified.append(Classified(tx: tx, outcome: row.outcome, reason: row.reason,
                                          chargeKind: validOriginal ? detectedKind : nil))
        }

        // Política de cuotas MSI (spec G.4): aplica sobre cargos ya clasificados.
        applyInstallmentPolicy(&classified, policy: def.msiPolicy)

        // Etapa c: conciliar MSI ANTES de sumar (spec G.4) — corrige el doble conteo de raíz.
        var reconciliations: [PromotionProgress.Reconciliation] = []
        reconcileMsi(&classified, policy: def.msiPolicy, reconciliations: &reconciliations)

        // Etapa c (cont.): refunds — aplicar al cargo original, con tope = monto del cargo (spec G.5).
        var ambiguousRefundTotal: Decimal = 0
        let refundLedger = reconcileRefunds(&classified, def: def,
                                            asOf: asOf,
                                            ambiguousTotal: &ambiguousRefundTotal,
                                            reconciliations: &reconciliations)

        // Agregar: firme solo con eligible (neto de refunds); riesgos señalizados sin descontar;
        // banda de incertidumbre por clase ③.
        var eligibleFirm: Decimal = 0
        var risks: [PromotionProgress.ConversionRisk] = []
        var possibleAdd: Decimal = 0
        var possibleSub: Decimal = 0
        for item in classified {
            switch item.outcome {
            case .eligible:
                let refunded = refundLedger[item.tx.id] ?? 0
                eligibleFirm += max(0, abs(item.tx.amount) - refunded)
                if let threshold = def.msiPolicy.conversionRiskThreshold, abs(item.tx.amount) >= threshold {
                    risks.append(.init(transactionID: item.tx.id, amount: abs(item.tx.amount)))
                }
            case .review(direction: .couldAdd):
                possibleAdd += abs(item.tx.amount)
            case .review(direction: .couldSubtract):
                possibleSub += abs(item.tx.amount)
            default:
                break
            }
        }

        let rows = classified.map {
            PromotionProgress.RowOutcome(transactionID: $0.tx.id, outcome: $0.outcome, reason: $0.reason,
                                         amount: $0.tx.amount, descriptor: $0.tx.descriptionRaw,
                                         postedAt: $0.tx.postedAt)
        }
        let progress = PromotionProgress(
            definitionID: def.id, displayName: def.displayName,
            calculability: .calculable, eligibleFirm: eligibleFirm, rows: rows,
            conversionRisks: risks,
            possiblePositiveAddition: possibleAdd,
            possibleNegativeAdjustment: possibleSub + ambiguousRefundTotal,
            reconciliations: reconciliations)
        // (knownUnknowns se asignan tras summarize para viajar al UI)
        var summarized = summarize(progress, def: def, classified: classified, window: window,
                                   refundLedger: refundLedger, asOf: asOf)
        summarized.knownUnknowns = def.knownUnknowns
        summarized.reconciliations = reconciliations
        let evaluationDay = Self.calendar.startOfDay(for: asOf)
        summarized.campaignStartDate = window.lowerBound
        summarized.campaignEndDate = Self.calendar.date(byAdding: .day, value: -1, to: window.upperBound)
        if evaluationDay < window.lowerBound {
            summarized.campaignPhase = .upcoming
            summarized.deadlineDate = nil
            summarized.daysRemaining = nil
            summarized.currentGoalReached = false
        } else if evaluationDay >= window.upperBound {
            summarized.campaignPhase = .finished
            summarized.deadlineDate = summarized.campaignEndDate
            summarized.daysRemaining = nil
            summarized.currentGoalReached = false
        } else {
            summarized.campaignPhase = .active
        }
        // Candidatos de recibo: créditos con descriptor de recompensa hasta asOf (post-cierre
        // incluido — v4-i), listados sin asignación.
        summarized.receiptCandidates = classified.compactMap { item in
            guard item.outcome == .evidence, item.tx.amount > 0, item.tx.flowKind == .cardCredit,
                  !item.tx.isDuplicate, item.tx.postedAt <= asOf,
                  !def.reward.descriptorPatterns.isEmpty,
                  def.reward.descriptorPatterns.contains(where: { Self.matches($0, descriptor: item.tx.descriptionRaw) })
            else { return nil }
            return .init(transactionID: item.tx.id, amount: item.tx.amount, postedAt: item.tx.postedAt)
        }
        return summarized
    }

    /// Estados + resumen por forma. El estado mostrado es SIEMPRE el actual recalculado (v3-e)
    /// y «umbral alcanzado según registros» se suspende ante ambigüedad decisiva (v4-g).
    private func summarize(
        _ progress: PromotionProgress, def: PromotionDefinition,
        classified: [Classified],
        window: Range<Date>, refundLedger: [UUID: Decimal], asOf: Date
    ) -> PromotionProgress {
        var p = progress
        let evaluationDay = Self.calendar.startOfDay(for: asOf)
        let expired = evaluationDay >= window.upperBound
        let reached = { (target: Decimal) in p.eligibleFirm >= target }
        let mayReach = { (target: Decimal, possible: Decimal) in p.eligibleFirm < target && p.eligibleFirm + possible >= target }
        let assumptions = !def.knownUnknowns.isEmpty

        switch def.shape {
        case .spendThreshold(let target, _):
            let remaining = max(0, target - p.eligibleFirm)
            p.shapeSummary = .spendThreshold(target: target, remaining: remaining)
            let inclusiveEnd = Self.calendar.date(byAdding: .day, value: -1, to: window.upperBound)!
            p.deadlineDate = inclusiveEnd
            let negativeChanges = reached(target) && p.eligibleFirm - p.possibleNegativeAdjustment < target
            let positiveChanges = mayReach(target, p.possiblePositiveAddition)
            if expired {
                if negativeChanges {
                    p.displayState = .expiredSuspended
                } else if positiveChanges {
                    p.displayState = .provisional
                } else if assumptions {
                    p.displayState = .estimated
                } else {
                    p.displayState = .expired(reachedPerRecords: reached(target))
                }
            } else if negativeChanges {
                p.displayState = .thresholdSuspended
            } else if positiveChanges {
                p.displayState = .provisional
            } else if assumptions {
                p.displayState = .estimated
            } else if reached(target) {
                p.displayState = .thresholdReachedPerRecords
            } else {
                p.displayState = .enCurso
            }
            p.currentGoalReached = !expired && p.displayState == .thresholdReachedPerRecords
            p.daysRemaining = expired || evaluationDay < window.lowerBound ? nil : Self.days(from: evaluationDay, toInclusiveEnd: inclusiveEnd)

        case .cashbackCap(let ratePercent, let cap):
            let devengado = min(p.eligibleFirm * ratePercent / 100, cap)
            p.shapeSummary = .cashback(devengado: devengado, cap: cap, capRemaining: cap - devengado)
            let low = min(max(0, p.eligibleFirm - p.possibleNegativeAdjustment) * ratePercent / 100, cap)
            let high = min((p.eligibleFirm + p.possiblePositiveAddition) * ratePercent / 100, cap)
            let inclusiveEnd = Self.calendar.date(byAdding: .day, value: -1, to: window.upperBound)!
            p.deadlineDate = inclusiveEnd
            if low != high { p.displayState = .provisional }
            else if assumptions { p.displayState = .estimated }
            else { p.displayState = expired ? .expired(reachedPerRecords: devengado > 0) : .enCurso }
            p.currentGoalReached = !expired && !assumptions && low >= cap
            p.daysRemaining = expired || evaluationDay < window.lowerBound ? nil : Self.days(from: evaluationDay, toInclusiveEnd: inclusiveEnd)

        case .tieredPeriods(let periodSpecs, let threshold, let reward, let annualCap, let capScope):
            var periods: [PromotionProgress.PeriodOutcome] = []
            var earned: Decimal = 0
            var earnedByYear: [Int: Decimal] = [:]
            var currentPeriodEnd: Date?
            var currentPeriodGoalReached = false
            for spec in periodSpecs.sorted(by: { $0.start < $1.start }) {
                guard let range = Self.resolvePeriod(spec) else { continue }
                let firm = firm(in: range, classified: classified, refundLedger: refundLedger)
                let uncertainUp = possibleAddition(in: range, classified: classified)
                let uncertainDown = possibleNegative(in: range, classified: classified, reconciliations: p.reconciliations)
                let phase: PromotionProgress.PeriodOutcome.Phase
                var rewardEarned: Decimal = 0
                let year = Self.calendar.component(.year, from: range.lowerBound)
                let alreadyEarned = capScope == .calendarYear ? (earnedByYear[year] ?? 0) : earned
                if range.upperBound <= evaluationDay {
                    if (firm >= threshold && firm - uncertainDown < threshold)
                        || (firm < threshold && firm + uncertainUp >= threshold) {
                        phase = .provisional
                    } else if firm >= threshold {
                        rewardEarned = min(reward, max(0, annualCap - alreadyEarned))
                        earned += rewardEarned
                        earnedByYear[year, default: 0] += rewardEarned
                        phase = .closedWon
                    } else {
                        phase = .closedLost
                    }
                } else if range.contains(evaluationDay) {
                    phase = .current
                    currentPeriodEnd = Self.calendar.date(byAdding: .day, value: -1, to: range.upperBound)
                    currentPeriodGoalReached = firm >= threshold && uncertainDown == 0
                } else {
                    phase = .future
                }
                periods.append(.init(start: spec.start, end: spec.end, phase: phase,
                                     firm: firm, threshold: threshold, rewardEarned: rewardEarned))
            }
            p.shapeSummary = .tieredPeriods(periods: periods, earnedTotal: earned, annualCap: annualCap)
            if periods.contains(where: { $0.phase == .provisional }) { p.displayState = .provisional }
            else if assumptions { p.displayState = .estimated }
            else { p.displayState = expired ? .expired(reachedPerRecords: earned > 0) : .enCurso }
            let inclusiveEnd = Self.calendar.date(byAdding: .day, value: -1, to: window.upperBound)!
            p.deadlineDate = expired ? inclusiveEnd : (currentPeriodEnd ?? inclusiveEnd)
            p.currentGoalReached = !expired && !assumptions && !periods.contains(where: { $0.phase == .provisional })
                && currentPeriodGoalReached
            if expired {
                p.daysRemaining = nil
            } else if evaluationDay < window.lowerBound {
                p.daysRemaining = nil
            } else if let currentPeriodEnd {
                p.daysRemaining = Self.days(from: evaluationDay, toInclusiveEnd: currentPeriodEnd)
            } else {
                p.daysRemaining = Self.days(from: evaluationDay, toInclusiveEnd: inclusiveEnd)
            }
        }
        return p
    }

    private func firm(in range: Range<Date>,
                      classified: [Classified],
                      refundLedger: [UUID: Decimal]) -> Decimal {
        classified.reduce(Decimal(0)) { total, item in
            guard case .eligible = item.outcome, range.contains(item.tx.postedAt) else { return total }
            let refunded = refundLedger[item.tx.id] ?? 0
            return total + max(0, abs(item.tx.amount) - refunded)
        }
    }

    private func possibleAddition(in range: Range<Date>, classified: [Classified]) -> Decimal {
        classified.reduce(0) { total, item in
            guard case .review(direction: .couldAdd) = item.outcome, range.contains(item.tx.postedAt) else { return total }
            return total + abs(item.tx.amount)
        }
    }

    private func possibleNegative(in range: Range<Date>, classified: [Classified],
                                  reconciliations: [PromotionProgress.Reconciliation]) -> Decimal {
        var total = classified.reduce(Decimal(0)) { sum, item in
            guard case .review(direction: .couldSubtract) = item.outcome, range.contains(item.tx.postedAt) else { return sum }
            return sum + abs(item.tx.amount)
        }
        let eligibleDates = Dictionary(uniqueKeysWithValues: classified.compactMap { item -> (UUID, Date)? in
            guard case .eligible = item.outcome else { return nil }
            return (item.tx.id, item.tx.postedAt)
        })
        for relation in reconciliations where relation.status == .disputed && relation.kind == .refund {
            if relation.candidateChargeIDs.contains(where: { eligibleDates[$0].map(range.contains) ?? false }) {
                total += relation.potentialAdjustment
            }
        }
        return total
    }

    static func resolvePeriod(_ spec: PromotionPeriod) -> Range<Date>? {
        guard let s = parseDate(spec.start), let e = parseDate(spec.end),
              e >= s, let exclusiveEnd = calendar.date(byAdding: .day, value: 1, to: e),
              s < exclusiveEnd else { return nil }
        return s..<exclusiveEnd
    }

    private static func days(from: Date, toInclusiveEnd: Date) -> Int {
        max(0, calendar.dateComponents([.day], from: calendar.startOfDay(for: from),
                                       to: calendar.startOfDay(for: toInclusiveEnd)).day ?? 0)
    }

    // MARK: Cuotas MSI — doctrina resuelta del usuario (promo.py), parametrizada por promo

    /// Sintaxis del emisor (conocimiento general Amex-MX, no constante de promo):
    /// cuota con contador vs probable-cuota sin contador.
    private static let installmentWithCounter = [
        "(?i)MESES\\s+EN\\s+AUTOM[AÁ]TICO.*\\d{1,2}\\s*/\\s*\\d{1,2}",
        "(?i)\\bMSI\\s*\\d{1,2}\\s*/\\s*\\d{1,2}\\b",
    ]
    private static let probableInstallment = [
        "(?i)\\bAMAZON\\s+MSI\\b",
        "(?i)MESES\\s+EN\\s+AUTOM[AÁ]TICO",
    ]

    private func installmentKind(_ descriptor: String) -> ChargeKind? {
        if Self.installmentWithCounter.contains(where: { Self.matches($0, descriptor: descriptor) }) {
            return .installment
        }
        if Self.probableInstallment.contains(where: { Self.matches($0, descriptor: descriptor) }) {
            return .probableInstallment
        }
        return .regular
    }

    private func applyInstallmentPolicy(_ classified: inout [Classified], policy: MsiPolicy) {
        for i in classified.indices {
            guard case .eligible = classified[i].outcome, classified[i].tx.amount < 0 else { continue }
            switch classified[i].chargeKind {
            case .installment?:
                switch policy.kind {
                case .countPostedInstallments:
                    classified[i].outcome = .eligible
                    classified[i].reason = "cuota MSI publicada (patrón con contador)"
                case .excludeAll:
                    classified[i].outcome = .excluded
                    classified[i].reason = "cuota MSI excluida por política de la oferta"
                case .uncertain:
                    classified[i].outcome = .review(direction: .couldAdd)
                    classified[i].reason = "cuota MSI — política incierta en esta oferta"
                }
            case .probableInstallment?:
                classified[i].outcome = .review(direction: .couldAdd)
                classified[i].reason = "probable cuota MSI sin contador"
            case .regular?, nil:
                break
            }
        }
    }

    /// Busca en todo el historial hasta asOf. Importe genera candidatos; solo una identidad
    /// exacta de comercio permite neutralizar el cargo. Un crédito se consume una sola vez.
    private func reconcileMsi(
        _ classified: inout [Classified], policy: MsiPolicy,
        reconciliations: inout [PromotionProgress.Reconciliation]
    ) {
        let credits = classified.filter { item in
            item.tx.amount > 0 && item.outcome == .evidence
                && policy.reversalPatterns.contains { Self.matches($0, descriptor: item.tx.descriptionRaw) }
        }
        var consumedCharges: Set<UUID> = []
        for credit in credits {
            let candidates = classified.indices.filter { i in
                let item = classified[i]
                return item.tx.amount < 0 && item.tx.postedAt <= credit.tx.postedAt
                    && item.tx.currency == credit.tx.currency && item.tx.amount == -credit.tx.amount
                    && item.chargeKind == .regular
            }
            let identified = candidates.filter { Self.sameMerchant(classified[$0].tx, credit.tx) }
            if identified.count == 1 && !consumedCharges.contains(classified[identified[0]].tx.id) {
                let i = identified[0]
                consumedCharges.insert(classified[i].tx.id)
                if classified[i].outcome == .eligible
                    || classified[i].outcome == .review(direction: .couldAdd) {
                    classified[i].outcome = .excluded
                    classified[i].reason = "cargo neutralizado por reversión MSI conciliada"
                }
                reconciliations.append(.init(kind: .installmentReversal,
                    creditTransactionID: credit.tx.id, candidateChargeIDs: [classified[i].tx.id],
                    amountApplied: abs(credit.tx.amount), potentialAdjustment: 0,
                    netContribution: 0, status: .matched))
            } else if !candidates.isEmpty {
                let unresolved = candidates.filter { i in
                    guard !consumedCharges.contains(classified[i].tx.id) else { return false }
                    if case .eligible = classified[i].outcome { return true }
                    return false
                }
                for i in unresolved {
                    classified[i].outcome = .review(direction: .couldAdd)
                    classified[i].reason = "reversión MSI con identidad ambigua — fuera del firme"
                }
                reconciliations.append(.init(kind: .installmentReversal,
                    creditTransactionID: credit.tx.id,
                    candidateChargeIDs: candidates.map { classified[$0].tx.id }, amountApplied: 0,
                    potentialAdjustment: 0, netContribution: nil, status: .disputed))
            } else {
                reconciliations.append(.init(kind: .installmentReversal,
                    creditTransactionID: credit.tx.id, candidateChargeIDs: [], amountApplied: 0,
                    potentialAdjustment: 0, netContribution: nil, status: .unmatched))
            }
        }
    }

    // MARK: Refunds (spec G.5 + v4-g)

    /// Créditos candidatos a reembolso: tarjeta, hasta asOf, que NO matcheen descriptores de
    /// reversión MSI (arbitraje: un crédito MSI jamás es candidato a refund) NI la deny-list
    /// de recompensas («Bonificación» — patrón de la definición o default).
    private static let defaultRewardDenyPattern = "(?i)BONIFICACI"

    private func reconcileRefunds(
        _ classified: inout [Classified],
        def: PromotionDefinition,
        asOf: Date,
        ambiguousTotal: inout Decimal,
        reconciliations: inout [PromotionProgress.Reconciliation]
    ) -> [UUID: Decimal] {
        guard def.refundPolicy.kind == .subtract else { return [:] }
        let denyPatterns = def.reward.descriptorPatterns + [Self.defaultRewardDenyPattern]

        var refunded: [UUID: Decimal] = [:]

        func remainingEligibleSpend() -> Decimal {
            classified.reduce(Decimal(0)) { total, item in
                guard case .eligible = item.outcome else { return total }
                return total + max(0, abs(item.tx.amount) - (refunded[item.tx.id] ?? 0))
            }
        }

        let credits = classified.filter { $0.tx.amount > 0 && $0.tx.postedAt <= asOf
            && $0.outcome == .evidence && $0.tx.flowKind == .cardCredit }
        for item in credits {
            let descriptor = item.tx.descriptionRaw
            // Arbitraje: reversión MSI (consumida o no) y recompensas quedan fuera del pool.
            let isMsiCredit = def.msiPolicy.reversalPatterns.contains { Self.matches($0, descriptor: descriptor) }
            let isReward = denyPatterns.contains { Self.matches($0, descriptor: descriptor) }
            guard !isMsiCredit, !isReward else { continue }
            let identityCandidates = classified.indices.filter { i in
                let c = classified[i]
                let refundableKind = c.chargeKind == .regular
                    || (c.chargeKind == .installment && def.msiPolicy.kind == .countPostedInstallments)
                guard c.tx.amount < 0, c.tx.postedAt <= item.tx.postedAt,
                      c.tx.currency == item.tx.currency, refundableKind,
                      Self.sameMerchant(c.tx, item.tx) else { return false }
                let already = refunded[c.tx.id] ?? 0
                return already < abs(c.tx.amount)
            }
            let compatible = identityCandidates.filter { i in
                abs(item.tx.amount) <= abs(classified[i].tx.amount)
            }

            switch compatible.count {
            case 1:
                let i = compatible[0]
                let chargeAmount = abs(classified[i].tx.amount)
                let already = refunded[classified[i].tx.id] ?? 0
                let applied = min(abs(item.tx.amount), chargeAmount - already)
                refunded[classified[i].tx.id] = already + applied
                if already + applied >= chargeAmount, case .eligible = classified[i].outcome {
                    classified[i].outcome = .excluded
                    classified[i].reason = "reembolso completo aplicado al cargo"
                } else if case .eligible = classified[i].outcome {
                    classified[i].reason = "reembolso parcial aplicado: −\(applied)"
                }
                reconciliations.append(.init(kind: .refund, creditTransactionID: item.tx.id,
                    candidateChargeIDs: [classified[i].tx.id], amountApplied: applied,
                    potentialAdjustment: 0,
                    netContribution: max(0, chargeAmount - already - applied), status: .matched))
            case 2...:
                let eligibleCandidates = compatible.filter { i in
                    if case .eligible = classified[i].outcome { return true }
                    return false
                }
                let cap = eligibleCandidates.map {
                    abs(classified[$0].tx.amount) - (refunded[classified[$0].tx.id] ?? 0)
                }.max() ?? 0
                let potential = min(abs(item.tx.amount), min(cap,
                    max(0, remainingEligibleSpend() - ambiguousTotal)))
                ambiguousTotal += potential
                for i in eligibleCandidates { classified[i].reason = "reembolso ambiguo — no aplicado al firme" }
                reconciliations.append(.init(kind: .refund, creditTransactionID: item.tx.id,
                    candidateChargeIDs: compatible.map { classified[$0].tx.id }, amountApplied: 0,
                    potentialAdjustment: potential, netContribution: nil, status: .disputed))
            default:
                if !identityCandidates.isEmpty {
                    let eligibleCandidates = identityCandidates.filter { i in
                        if case .eligible = classified[i].outcome { return true }
                        return false
                    }
                    let cap = eligibleCandidates.map {
                        abs(classified[$0].tx.amount) - (refunded[classified[$0].tx.id] ?? 0)
                    }.max() ?? 0
                    let potential = min(abs(item.tx.amount), min(cap,
                        max(0, remainingEligibleSpend() - ambiguousTotal)))
                    ambiguousTotal += potential
                    reconciliations.append(.init(kind: .refund, creditTransactionID: item.tx.id,
                        candidateChargeIDs: identityCandidates.map { classified[$0].tx.id }, amountApplied: 0,
                        potentialAdjustment: potential, netContribution: nil, status: .disputed))
                } else {
                    reconciliations.append(.init(kind: .refund, creditTransactionID: item.tx.id,
                        candidateChargeIDs: [], amountApplied: 0, potentialAdjustment: 0,
                        netContribution: nil, status: .unmatched))
                }
            }
        }
        return refunded
    }

    private static func sameMerchant(_ lhs: Transaction, _ rhs: Transaction) -> Bool {
        func key(_ tx: Transaction) -> String {
            if tx.merchantNormalized.isEmpty {
                let descriptor = tx.descriptionRaw.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                                             locale: Locale(identifier: "es_MX"))
                if ["monto a diferir", "reverso", "reversion", "refund", "devolucion", "abono", "bonificacion"]
                    .contains(where: descriptor.localizedStandardContains) { return "" }
            }
            let value = tx.merchantNormalized.isEmpty ? tx.descriptionRaw : tx.merchantNormalized
            return value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es_MX"))
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }.joined(separator: " ")
        }
        let a = key(lhs), b = key(rhs)
        return !a.isEmpty && a == b
    }


    private static func row(_ tx: Transaction, _ outcome: PromotionProgress.RowOutcome.Outcome,
                            _ reason: String) -> PromotionProgress.RowOutcome {
        PromotionProgress.RowOutcome(transactionID: tx.id, outcome: outcome, reason: reason,
                                     amount: tx.amount, descriptor: tx.descriptionRaw,
                                     postedAt: tx.postedAt)
    }

    private func isStructurallyEligibleCharge(_ tx: Transaction, def: PromotionDefinition) -> Bool {
        guard tx.amount < 0, tx.currency == def.scope.currency,
              tx.flowKind == .charge || tx.flowKind == .expense,
              !tx.isTransfer, tx.category?.kind != .transfer,
              tx.category?.kind != .creditCardPayment else { return false }
        if let plan = tx.installmentPlan, abs(tx.amount) == abs(plan.originalAmount) { return false }
        return !(def.scope.excludeFees && isFee(tx))
    }

    private func isFee(_ tx: Transaction) -> Bool {
        if tx.treatmentKind == .fee { return true }
        let text = (tx.categoryName + " " + tx.descriptionRaw)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es_MX"))
        return ["interest", "interes", "fee", "comision", "commission", "cargo por pago tardio", "late fee",
                    "anualidad", "cuota anual", "retiro de efectivo", "retiro en cajero", "avance de efectivo", "cash advance"]
            .contains { text.localizedStandardContains($0) }
    }

    private func classifyCharge(_ tx: Transaction, def: PromotionDefinition,
                                window: Range<Date>, channelTable: ChannelTable,
                                kind: ChargeKind?) -> PromotionProgress.RowOutcome {
        guard tx.amount < 0 else {
            return Self.row(tx, .excluded, "importe cero — no es un cargo")
        }
        guard tx.flowKind == .charge || tx.flowKind == .expense else {
            return Self.row(tx, .excluded, "movimiento no clasificado como compra")
        }
        if tx.currency != def.scope.currency {
            return Self.row(tx, .excluded, "moneda \(tx.currency) ≠ \(def.scope.currency)")
        }
        if tx.isTransfer || tx.category?.kind == .transfer || tx.category?.kind == .creditCardPayment {
            return Self.row(tx, .excluded, "transferencia")
        }
        if let plan = tx.installmentPlan, abs(tx.amount) == abs(plan.originalAmount) {
            return Self.row(tx, .excluded, "original MSI sintetizado — cuentan las cuotas publicadas")
        }
        if def.scope.excludeFees && isFee(tx) {
            return Self.row(tx, .excluded, "comisión/interés (política de la oferta)")
        }
        if !window.contains(tx.postedAt) {
            return Self.row(tx, .excluded, "fuera de ventana")
        }
        let scoped = classifyScope(tx, scope: def.scope, channelTable: channelTable)
        if kind == .probableInstallment, case .eligible = scoped.outcome {
            return Self.row(tx, .review(direction: .couldAdd), "probable cuota MSI sin contador")
        }
        return scoped
    }

    /// Predicado de alcance (spec G.3): whitelist con alias, terceros/agregadores por tabla
    /// compartida, canal con default por revisar — nunca "ambos" por intuición.
    private func classifyScope(_ tx: Transaction, scope: PromotionScope,
                               channelTable: ChannelTable) -> PromotionProgress.RowOutcome {
        // Terceros/agregadores: derivables con certeza del descriptor.
        if scope.excludeThirdParties,
           channelTable.entries.contains(where: { entry in
               guard let pattern = entry.pattern, entry.channel == .aggregator else { return false }
               return Self.matches(pattern, descriptor: tx.descriptionRaw)
           }) {
            return Self.row(tx, .excluded, "tercero/agregador (tabla de canal)")
        }

        // Whitelist estricta: fuera de lista no es elegible (ni review).
        guard let merchant = scope.merchants.first(where: { entry in
            entry.patterns.contains { Self.matches($0, descriptor: tx.descriptionRaw) }
        }) else {
            if scope.merchants.isEmpty {
                return Self.row(tx, .eligible, "compra publicada en ventana (alcance abierto)")
            }
            return Self.row(tx, .excluded, "merchant fuera de whitelist")
        }

        // Canal: entrada de whitelist → tabla compartida por merchantID → desconocido.
        let channel = merchant.channel
            ?? channelTable.entries.first { $0.merchantID == merchant.id }?.channel
        switch scope.requireChannel {
        case .any:
            return Self.row(tx, .eligible, "compra publicada en ventana — \(merchant.id)")
        case .physicalOnly:
            switch channel {
            case .physical:
                return Self.row(tx, .eligible, "compra presencial en \(merchant.id)")
            case .online:
                return Self.row(tx, .excluded, "comercio online-only en promo presencial (\(merchant.id))")
            default:
                return Self.row(tx, .review(direction: .couldAdd), "canal no derivable del descriptor (\(merchant.id))")
            }
        }
    }

    private static func matches(_ pattern: String, descriptor: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(descriptor.startIndex..., in: descriptor)
        return regex.firstMatch(in: descriptor, options: [], range: range) != nil
    }

    private func notCalculable(_ def: PromotionDefinition, reason: String) -> PromotionProgress {
        PromotionProgress(definitionID: def.id, displayName: def.displayName,
                          calculability: .notCalculable(reason), eligibleFirm: 0, rows: [])
    }

    /// Ventana resuelta: fechas literales yyyy-MM-dd interpretadas a 00:00 CDMX (inicio)
    /// y fin exclusivo (end + 1 día para `fixed`; start + durationDays para `anchored`).
    static func resolveWindow(_ window: PromotionDefinition.PromotionWindow) -> Range<Date>? {
        switch window {
        case .fixed(let start, let end, _):
            guard let s = parseDate(start), let e = parseDate(end), e >= s,
                  let exclusiveEnd = calendar.date(byAdding: .day, value: 1, to: e), s < exclusiveEnd else { return nil }
            return s..<exclusiveEnd
        case .anchored(let start, let days, _):
            guard days > 0, let s = parseDate(start),
                  let end = calendar.date(byAdding: .day, value: days, to: s), s < end else { return nil }
            return s..<end
        case .unknown:
            return nil
        }
    }

    private static let timeZone = TimeZone(identifier: "America/Mexico_City")!
    private static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }

    private static func parseDate(_ s: String) -> Date? {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = timeZone
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.isLenient = false
        guard let date = fmt.date(from: s), fmt.string(from: date) == s else { return nil }
        return calendar.startOfDay(for: date)
    }

    private static func transactionOrder(_ lhs: Transaction, _ rhs: Transaction) -> Bool {
        lhs.postedAt == rhs.postedAt ? lhs.id.uuidString < rhs.id.uuidString : lhs.postedAt < rhs.postedAt
    }
}
