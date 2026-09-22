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
        case expired(reachedPerRecords: Bool)
        case expiredSuspended
    }

    struct PeriodOutcome: Equatable {
        let start: String
        let end: String
        enum Phase: Equatable { case closedWon, closedLost, current, future }
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
}

/// Evaluador de promociones: una pasada por cuenta, etapas explícitas (spec G):
/// a) movimientos válidos (deleted fuera; duplicados visibles-excluidos; créditos = evidencia)
/// b) exclusiones promocionales SOLO sobre cargos elegibles — jamás countsAsRegularExpense
/// c) conciliar y después agregar (conciliación MSI/refunds llega en ciclos siguientes).
@MainActor
struct PromotionEvaluator {

    func evaluate(definitions: [PromotionDefinition], account: Account,
                  transactions: [Transaction], channelTable: ChannelTable, asOf: Date) -> [PromotionProgress] {
        var results = definitions.map { evaluate($0, account: account, transactions: transactions,
                                                 channelTable: channelTable, asOf: asOf) }
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
                          transactions: [Transaction], channelTable: ChannelTable, asOf: Date) -> PromotionProgress {
        // Calculabilidad (clase ①): sin vínculo UUID o sin ventana no hay número.
        guard let uuid = def.accountUUID, uuid == account.id else {
            return notCalculable(def, reason: "desvinculada — se requiere el UUID exacto de la cuenta")
        }
        guard let window = Self.resolveWindow(def.window) else {
            return notCalculable(def, reason: "ventana desconocida — falta definirla (T&C pendiente)")
        }

        // Etapas a/b: movimientos válidos → exclusiones solo sobre cargos.
        // Se clasifica en pares mutables (tx, outcome) para poder conciliar ANTES de agregar.
        var classified: [(tx: Transaction, outcome: PromotionProgress.RowOutcome.Outcome, reason: String)] = []

        for tx in transactions {
            if tx.deletedAt != nil { continue }
            if tx.isDuplicate {
                classified.append((tx, .excluded, "duplicado"))
                continue
            }
            // Créditos = EVIDENCIA: jamás se descartan (spec G.1a) — una reversión MSI puede
            // vivir categorizada como Credit Card Payments.
            if tx.amount > 0 {
                classified.append((tx, .evidence, "crédito/abono"))
                continue
            }
            let row = classifyCharge(tx, def: def, window: window, channelTable: channelTable)
            classified.append((tx, row.outcome, row.reason))
        }

        // Política de cuotas MSI (spec G.4): aplica sobre cargos ya clasificados.
        applyInstallmentPolicy(&classified, policy: def.msiPolicy)

        // Etapa c: conciliar MSI ANTES de sumar (spec G.4) — corrige el doble conteo de raíz.
        reconcileMsi(&classified, window: window, asOf: asOf, policy: def.msiPolicy)

        // Etapa c (cont.): refunds — aplicar al cargo original, con tope = monto del cargo (spec G.5).
        var ambiguousRefundTotal: Decimal = 0
        let refundLedger = reconcileRefunds(&classified, window: window, asOf: asOf, def: def,
                                            ambiguousTotal: &ambiguousRefundTotal)

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
            possibleNegativeAdjustment: possibleSub + ambiguousRefundTotal)
        // (knownUnknowns se asignan tras summarize para viajar al UI)
        var summarized = summarize(progress, def: def, classified: classified, window: window,
                                   refundLedger: refundLedger, asOf: asOf)
        summarized.knownUnknowns = def.knownUnknowns
        // Candidatos de recibo: créditos con descriptor de recompensa hasta asOf (post-cierre
        // incluido — v4-i), listados sin asignación.
        summarized.receiptCandidates = classified.compactMap { item in
            guard item.tx.amount > 0, item.tx.postedAt <= asOf,
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
        classified: [(tx: Transaction, outcome: PromotionProgress.RowOutcome.Outcome, reason: String)],
        window: Range<Date>, refundLedger: [UUID: Decimal], asOf: Date
    ) -> PromotionProgress {
        var p = progress
        let expired = asOf >= window.upperBound
        let decisiveAmbiguity = possibleNegativeDecision(
            firm: p.eligibleFirm, negative: p.possibleNegativeAdjustment, shape: def.shape)

        switch def.shape {
        case .spendThreshold(let target, _):
            let remaining = max(0, target - p.eligibleFirm)
            p.shapeSummary = .spendThreshold(target: target, remaining: remaining)
            if expired {
                if p.eligibleFirm >= target {
                    p.displayState = decisiveAmbiguity ? .expiredSuspended : .expired(reachedPerRecords: true)
                } else {
                    p.displayState = .expired(reachedPerRecords: false)
                }
            } else if p.eligibleFirm >= target {
                p.displayState = decisiveAmbiguity ? .thresholdSuspended : .thresholdReachedPerRecords
            } else {
                p.displayState = .enCurso
            }
            p.daysRemaining = expired ? nil : Self.days(from: asOf,
                toInclusiveEnd: Self.calendar.date(byAdding: .day, value: -1, to: window.upperBound)!)

        case .cashbackCap(let ratePercent, let cap):
            let devengado = min(p.eligibleFirm * ratePercent / 100, cap)
            p.shapeSummary = .cashback(devengado: devengado, cap: cap, capRemaining: cap - devengado)
            p.displayState = expired ? .expired(reachedPerRecords: devengado > 0) : .enCurso
            p.daysRemaining = expired ? nil : Self.days(from: asOf,
                toInclusiveEnd: Self.calendar.date(byAdding: .day, value: -1, to: window.upperBound)!)

        case .tieredPeriods(let periodSpecs, let threshold, let reward, let annualCap, _):
            var periods: [PromotionProgress.PeriodOutcome] = []
            var earned: Decimal = 0
            for spec in periodSpecs {
                guard let range = Self.resolvePeriod(spec) else { continue }
                let firm = firm(in: range, classified: classified, refundLedger: refundLedger)
                let phase: PromotionProgress.PeriodOutcome.Phase
                var rewardEarned: Decimal = 0
                if range.upperBound <= asOf {
                    if firm >= threshold {
                        rewardEarned = min(reward, max(0, annualCap - earned))
                        earned += rewardEarned
                        phase = .closedWon
                    } else {
                        phase = .closedLost
                    }
                } else if range.contains(asOf) {
                    phase = .current
                } else {
                    phase = .future
                }
                periods.append(.init(start: spec.start, end: spec.end, phase: phase,
                                     firm: firm, threshold: threshold, rewardEarned: rewardEarned))
            }
            p.shapeSummary = .tieredPeriods(periods: periods, earnedTotal: earned, annualCap: annualCap)
            p.displayState = expired ? .expired(reachedPerRecords: earned > 0) : .enCurso
            if expired {
                p.daysRemaining = nil
            } else if let currentSpec = periodSpecs.first(where: { Self.resolvePeriod($0)?.contains(asOf) == true }),
                      let currentRange = Self.resolvePeriod(currentSpec),
                      let inclusiveEnd = Self.calendar.date(byAdding: .day, value: -1, to: currentRange.upperBound) {
                p.daysRemaining = Self.days(from: asOf, toInclusiveEnd: inclusiveEnd)
            }
        }
        return p
    }

    /// ¿La incertidumbre pendiente puede cambiar el desenlace del umbral? (v4-g)
    private func possibleNegativeDecision(firm: Decimal, negative: Decimal,
                                          shape: PromotionDefinition.PromotionShape) -> Bool {
        switch shape {
        case .spendThreshold(let target, _):
            return firm >= target && (firm - negative) < target
        default:
            return false
        }
    }

    private func firm(in range: Range<Date>,
                      classified: [(tx: Transaction, outcome: PromotionProgress.RowOutcome.Outcome, reason: String)],
                      refundLedger: [UUID: Decimal]) -> Decimal {
        classified.reduce(Decimal(0)) { total, item in
            guard case .eligible = item.outcome, range.contains(item.tx.postedAt) else { return total }
            let refunded = refundLedger[item.tx.id] ?? 0
            return total + max(0, abs(item.tx.amount) - refunded)
        }
    }

    static func resolvePeriod(_ spec: PromotionPeriod) -> Range<Date>? {
        guard let s = parseDate(spec.start), let e = parseDate(spec.end),
              let exclusiveEnd = calendar.date(byAdding: .day, value: 1, to: e) else { return nil }
        return s..<exclusiveEnd
    }

    private static func days(from: Date, toInclusiveEnd: Date) -> Int {
        max(0, calendar.dateComponents([.day], from: from, to: toInclusiveEnd).day ?? 0)
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

    private func applyInstallmentPolicy(
        _ classified: inout [(tx: Transaction, outcome: PromotionProgress.RowOutcome.Outcome, reason: String)],
        policy: MsiPolicy
    ) {
        for i in classified.indices {
            let descriptor = classified[i].tx.descriptionRaw
            guard classified[i].tx.amount < 0 else { continue }
            if Self.installmentWithCounter.contains(where: { Self.matches($0, descriptor: descriptor) }) {
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
            } else if Self.probableInstallment.contains(where: { Self.matches($0, descriptor: descriptor) }) {
                classified[i].outcome = .review(direction: .couldAdd)
                classified[i].reason = "probable cuota MSI sin contador (Inferido)"
            }
        }
    }

    /// Conciliación MSI: candidatos por SIGNO Y FUNCIÓN primero (la reversión es un crédito
    /// positivo con descriptor de reversión; un cargo «Amazon MSI» jamás se consume como tal).
    /// Match por monto exacto contra cargos elegibles en ventana; la reversión se busca en el
    /// historial completo hasta asOf (puede llegar fuera de ventana — spec v3-d).
    /// Correspondencia inequívoca → neutraliza el original. Disputa → fuera del firme (clase ③).
    private func reconcileMsi(
        _ classified: inout [(tx: Transaction, outcome: PromotionProgress.RowOutcome.Outcome, reason: String)],
        window: Range<Date>, asOf: Date, policy: MsiPolicy
    ) {
        // Créditos candidatos a reversión (signo positivo + descriptor de la política).
        let reversalCredits = classified.filter { item in
            item.tx.amount > 0 && item.tx.postedAt <= asOf
                && policy.reversalPatterns.contains { Self.matches($0, descriptor: item.tx.descriptionRaw) }
        }
        guard !reversalCredits.isEmpty else { return }

        for credit in reversalCredits {
            // Originales posibles: cargos elegibles en ventana con el mismo monto exacto
            // (no cuotas: sus montos difieren y su razón ya lo dice).
            let candidates = classified.indices.filter { i in
                classified[i].tx.amount < 0 && classified[i].tx.amount == -credit.tx.amount
                    && window.contains(classified[i].tx.postedAt)
                    && (isPlainEligibleCharge(classified[i]))
            }
            switch candidates.count {
            case 1:
                let i = candidates[0]
                classified[i].outcome = .excluded
                classified[i].reason = "conciliado con reversión MSI — cuentan solo las cuotas publicadas"
            case 2...:
                // Disputa: la contribución sale del firme con dirección couldSubtract.
                for i in candidates {
                    classified[i].outcome = .review(direction: .couldSubtract)
                    classified[i].reason = "disputa de reversión MSI: \(candidates.count) compras del mismo importe"
                }
            default:
                break  // reversión sin original en ventana: queda como evidencia, sin efecto
            }
        }
    }

    private func isPlainEligibleCharge(
        _ item: (tx: Transaction, outcome: PromotionProgress.RowOutcome.Outcome, reason: String)
    ) -> Bool {
        guard case .eligible = item.outcome else { return false }
        // Las cuotas ya clasificadas como tales no son originales candidatos.
        return !item.reason.contains("cuota MSI")
    }

    // MARK: Refunds (spec G.5 + v4-g)

    /// Créditos candidatos a reembolso: positivos, ≤ asOf, que NO matcheen descriptores de
    /// reversión MSI (arbitraje: un crédito MSI jamás es candidato a refund) NI la deny-list
    /// de recompensas («Bonificación» — patrón de la definición o default).
    private static let defaultRewardDenyPattern = "(?i)BONIFICACI"

    private func reconcileRefunds(
        _ classified: inout [(tx: Transaction, outcome: PromotionProgress.RowOutcome.Outcome, reason: String)],
        window: Range<Date>, asOf: Date, def: PromotionDefinition,
        ambiguousTotal: inout Decimal
    ) -> [UUID: Decimal] {
        guard def.refundPolicy.kind == .subtract else { return [:] }
        let denyPatterns = def.reward.descriptorPatterns.isEmpty
            ? [Self.defaultRewardDenyPattern] : def.reward.descriptorPatterns

        var refunded: [UUID: Decimal] = [:]

        for (index, item) in classified.enumerated() where item.tx.amount > 0 && item.tx.postedAt <= asOf {
            let descriptor = item.tx.descriptionRaw
            // Arbitraje: reversión MSI (consumida o no) y recompensas quedan fuera del pool.
            let isMsiCredit = def.msiPolicy.reversalPatterns.contains { Self.matches($0, descriptor: descriptor) }
            let isReward = denyPatterns.contains { Self.matches($0, descriptor: descriptor) }
            guard !isMsiCredit, !isReward else { continue }

            // Cargos originales candidatos: elegibles en ventana, mismo descriptor (contención),
            // monto del crédito ≤ monto del cargo, con margen aún no reembolsado.
            let candidates = classified.indices.filter { i in
                let c = classified[i]
                guard c.tx.amount < 0, window.contains(c.tx.postedAt),
                      case .eligible = c.outcome else { return false }
                let already = refunded[c.tx.id] ?? 0
                guard already < abs(c.tx.amount) else { return false }  // margen restante > 0
                return Self.descriptorOverlap(credit: descriptor, charge: c.tx.descriptionRaw)
            }

            switch candidates.count {
            case 1:
                let i = candidates[0]
                let chargeAmount = abs(classified[i].tx.amount)
                let already = refunded[classified[i].tx.id] ?? 0
                let applied = min(abs(item.tx.amount), chargeAmount - already)
                refunded[classified[i].tx.id] = already + applied
                if already + applied >= chargeAmount {
                    classified[i].outcome = .excluded
                    classified[i].reason = "reembolso aplicado a este cargo (tope = monto del cargo)"
                } else {
                    classified[i].reason = "compra — reembolso parcial −\(applied) aplicado"
                }
            case 2...:
                // Ambiguo (v4-g): el firme conserva el importe; el posible ajuste negativo se exhibe.
                let cap = candidates.reduce(Decimal(0)) { $0 + abs(classified[$1].tx.amount) }
                ambiguousTotal += min(abs(item.tx.amount), cap)
                for i in candidates where classified[i].outcome != .excluded {
                    classified[i].reason = "compra — reembolso posible en disputa (no aplicado)"
                }
            default:
                break  // crédito sin cargo par: queda como evidencia, sin efecto ni silencio
            }
        }
        return refunded
    }

    private static func descriptorOverlap(credit: String, charge: String) -> Bool {
        let c = credit.lowercased().trimmingCharacters(in: .whitespaces)
        let h = charge.lowercased().trimmingCharacters(in: .whitespaces)
        guard !c.isEmpty else { return false }
        return h.contains(c) || c.contains(h)
    }


    private static func row(_ tx: Transaction, _ outcome: PromotionProgress.RowOutcome.Outcome,
                            _ reason: String) -> PromotionProgress.RowOutcome {
        PromotionProgress.RowOutcome(transactionID: tx.id, outcome: outcome, reason: reason,
                                     amount: tx.amount, descriptor: tx.descriptionRaw,
                                     postedAt: tx.postedAt)
    }

    private func classifyCharge(_ tx: Transaction, def: PromotionDefinition,
                                window: Range<Date>, channelTable: ChannelTable) -> PromotionProgress.RowOutcome {
        if tx.currency != def.scope.currency {
            return Self.row(tx, .excluded, "moneda \(tx.currency) ≠ \(def.scope.currency)")
        }
        if tx.isTransfer {
            return Self.row(tx, .excluded, "transferencia")
        }
        if let plan = tx.installmentPlan, abs(tx.amount) == abs(plan.originalAmount) {
            return Self.row(tx, .excluded, "original MSI sintetizado — cuentan las cuotas publicadas")
        }
        if def.scope.excludeFees, let raw = tx.treatmentKindRaw,
           TransactionTreatmentKind(rawValue: raw) == .fee {
            return Self.row(tx, .excluded, "comisión/interés (política de la oferta)")
        }
        if !window.contains(tx.postedAt) {
            return Self.row(tx, .excluded, "fuera de ventana")
        }
        return classifyScope(tx, scope: def.scope, channelTable: channelTable)
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
            guard let s = parseDate(start), let e = parseDate(end) else { return nil }
            guard let exclusiveEnd = calendar.date(byAdding: .day, value: 1, to: e) else { return nil }
            return s..<exclusiveEnd
        case .anchored(let start, let days, _):
            guard let s = parseDate(start),
                  let end = calendar.date(byAdding: .day, value: days, to: s) else { return nil }
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
        return fmt.date(from: s)
    }
}
