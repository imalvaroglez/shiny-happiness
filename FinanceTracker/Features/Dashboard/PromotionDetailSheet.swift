import SwiftUI

/// Drill-down de una promoción (patrón BreakdownSheet: material fuente embebido, cero fetches).
/// Minimalista (feedback 2026-09-22): una línea de periodo actual + resumen; tablas y listas
/// completas colapsadas por defecto; nada vacío se pinta; filas de $0 omitidas.
struct PromotionDetailSheet: View {
    let promo: PromotionProgress
    let currencyCode: String
    @Environment(\.dismiss) private var dismiss

    @State private var showAllPeriods = false
    @State private var showExcluded = false
    @State private var showAssumptions = false

    private var eligibleRows: [PromotionProgress.RowOutcome] {
        promo.rows.filter { if case .eligible = $0.outcome { return true }; return false }
    }
    private var reviewRows: [PromotionProgress.RowOutcome] {
        promo.rows.filter { if case .review = $0.outcome { return true }; return false }
    }
    private var excludedRows: [PromotionProgress.RowOutcome] {
        promo.rows.filter {
            guard abs($0.amount) > 0 else { return false }  // $0 = ruido (opening balance)
            if case .excluded = $0.outcome { return true }
            return false
        }
    }
    private var evidenceRows: [PromotionProgress.RowOutcome] {
        promo.rows.filter { if case .evidence = $0.outcome { return true }; return false }
    }

    private var deadlineLabel: String {
        if promo.campaignPhase == .finished { return "Vigencia terminó" }
        if case .tieredPeriods = promo.shapeSummary { return "Cierre del periodo actual" }
        return "Fecha límite"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if case .calculable = promo.calculability {
                    summary
                    currentPeriodLine
                    if !reviewRows.isEmpty { reviewSection }
                    eligibleSection
                    if !promo.conversionRisks.isEmpty { conversionRisksSection }
                    if !promo.receiptCandidates.isEmpty { receiptCandidatesSection }
                    if !promo.reconciliations.isEmpty { reconciliationsSection }
                    excludedSection
                    if !evidenceRows.isEmpty { evidenceSection }
                }
                assumptionsSection
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 460, minHeight: 380)
    }

    private var header: some View {
        HStack {
            Text(promo.displayName).font(.title2.bold())
            Spacer()
            Button("Cerrar") { dismiss() }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            let underAssumptions = !promo.knownUnknowns.isEmpty
            Text("\(underAssumptions ? "Estimación bajo supuestos" : "Avance firme"): \(MoneyFormat.string(code: currencyCode, headlineAmount))")
                .font(.title3.monospacedDigit())
            if promo.possiblePositiveAddition > 0 || promo.possibleNegativeAdjustment > 0 {
                Text("± \(MoneyFormat.string(code: currencyCode, promo.possiblePositiveAddition)) por revisar · posible ajuste −\(MoneyFormat.string(code: currencyCode, promo.possibleNegativeAdjustment))")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let deadline = promo.deadlineDisplayText {
                Text("\(deadlineLabel): \(deadline)").font(.caption).foregroundStyle(.secondary)
            } else if promo.campaignPhase == .upcoming, let start = promo.campaignStartDate {
                Text("Inicia \(promotionDateLabel(start))").font(.caption).foregroundStyle(.secondary)
            }
            if !promo.overlaps.isEmpty {
                Text("También cuenta en: \(promo.overlaps.joined(separator: ", ")) — conteo único no confirmado")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Cifra principal según la forma: avance del umbral/periodo actual o el devengo del cashback.
    private var headlineAmount: Decimal {
        switch promo.shapeSummary {
        case .spendThreshold:
            return promo.eligibleFirm
        case .cashback(let devengado, _, _):
            return devengado
        case .tieredPeriods(let periods, let earnedTotal, _):
            if let current = periods.first(where: { $0.phase == .current }) {
                return current.firm
            }
            return earnedTotal > 0 ? earnedTotal : promo.eligibleFirm
        }
    }

    // MARK: Periodo actual + resumen (la tabla completa va colapsada)

    @ViewBuilder
    private var currentPeriodLine: some View {
        switch promo.shapeSummary {
        case .spendThreshold(let target, let remaining):
            HStack {
                Text("Meta \(MoneyFormat.string(code: currencyCode, target))").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if remaining > 0 {
                    Text("falta \(MoneyFormat.string(code: currencyCode, remaining))")
                        .font(.caption.monospacedDigit())
                }
            }
        case .cashback(_, let cap, let capRemaining):
            HStack {
                Text("Tope \(MoneyFormat.string(code: currencyCode, cap))").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("disponible \(MoneyFormat.string(code: currencyCode, capRemaining))")
                    .font(.caption.monospacedDigit())
            }
        case .tieredPeriods(let periods, let earned, let cap):
            VStack(alignment: .leading, spacing: 6) {
                if let current = periods.first(where: { $0.phase == .current }) {
                    HStack {
                        Text("Periodo actual: \(shortDate(current.start)) → \(shortDate(current.end))")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(MoneyFormat.string(code: currencyCode, current.firm)) / \(MoneyFormat.string(code: currencyCode, current.threshold))")
                            .font(.caption.monospacedDigit())
                    }
                }
                HStack {
                    Text("\(periods.filter { $0.phase == .closedWon }.count)/\(periods.count) periodos ganados")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("devengado \(MoneyFormat.string(code: currencyCode, earned)) / \(MoneyFormat.string(code: currencyCode, cap))")
                        .font(.caption.monospacedDigit())
                }
                DisclosureGroup("Ver \(periods.count) periodos", isExpanded: $showAllPeriods) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(periods, id: \.start) { p in
                            HStack {
                                Text("\(p.start) → \(p.end)").font(.caption2.monospacedDigit())
                                Spacer()
                                Text(phaseLabel(p.phase)).font(.caption2).foregroundStyle(.secondary)
                                Text("\(MoneyFormat.string(code: currencyCode, p.firm)) / \(MoneyFormat.string(code: currencyCode, p.threshold))")
                                    .font(.caption2.monospacedDigit())
                                if p.rewardEarned > 0 {
                                    Text("+\(MoneyFormat.string(code: currencyCode, p.rewardEarned))")
                                        .font(.caption2.monospacedDigit()).foregroundStyle(.green)
                                }
                            }
                        }
                        Text("Los periodos cerrados se recalculan al importar movimientos tardíos.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
                .font(.caption)
                .foregroundStyle(.blue)
            }
        }
    }

    // MARK: Filas

    private var reviewSection: some View {
        Section(title: "Por revisar (\(reviewRows.count)) — fuera del firme") {
            ForEach(reviewRows, id: \.transactionID) { row in
                rowView(row, badge: directionBadge(row))
            }
        }
    }

    private var eligibleSection: some View {
        Section(title: "Contribuyen (\(eligibleRows.count))") {
            ForEach(eligibleRows, id: \.transactionID) { row in
                rowView(row, badge: nil)
            }
        }
    }

    private var excludedSection: some View {
        Group {
            if !excludedRows.isEmpty {
                Section(title: "") {
                    DisclosureGroup("Excluidas (\(excludedRows.count))", isExpanded: $showExcluded) {
                        ForEach(excludedRows, id: \.transactionID) { row in
                            rowView(row, badge: nil)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var evidenceSection: some View {
        Section(title: "Evidencia de conciliación (\(evidenceRows.count))") {
            ForEach(evidenceRows, id: \.transactionID) { row in
                rowView(row, badge: nil)
            }
        }
    }

    @ViewBuilder
    private var conversionRisksSection: some View {
        Section(title: "Riesgo de conversión MSI") {
            ForEach(promo.conversionRisks, id: \.transactionID) { risk in
                Text("Cargo de \(MoneyFormat.string(code: currencyCode, risk.amount)) puede convertirse a MSI — contarían solo las cuotas publicadas.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var receiptCandidatesSection: some View {
        Section(title: "Posible recompensa recibida (sin asignar)") {
            ForEach(promo.receiptCandidates, id: \.transactionID) { c in
                HStack {
                    Text(c.postedAt.formatted(date: .abbreviated, time: .omitted)).font(.caption.monospacedDigit())
                    Spacer()
                    Text(MoneyFormat.string(code: currencyCode, c.amount)).font(.caption.monospacedDigit())
                }
            }
            Text("Confirmación pendiente — V1 no asigna automáticamente.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var reconciliationsSection: some View {
        Section(title: "Conciliación") {
            ForEach(Array(promo.reconciliations.enumerated()), id: \.offset) { entry in
                let relation = entry.element
                let credit = promo.rows.first { $0.transactionID == relation.creditTransactionID }
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(relation.kind == .refund ? "Refund" : "Reversión MSI") · \(credit?.descriptor ?? "crédito") · \(reconciliationStatus(relation.status))")
                        .font(.caption)
                    if relation.amountApplied > 0 {
                        Text("Aplicado \(MoneyFormat.string(code: currencyCode, relation.amountApplied))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if relation.potentialAdjustment > 0 {
                        Text("Posible ajuste −\(MoneyFormat.string(code: currencyCode, relation.potentialAdjustment))")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    private var assumptionsSection: some View {
        Group {
            if !promo.knownUnknowns.isEmpty {
                DisclosureGroup("Supuestos declarados (\(promo.knownUnknowns.count))", isExpanded: $showAssumptions) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(promo.knownUnknowns, id: \.self) { s in
                            Text("· \(s)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 4)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: helpers

    private func rowView(_ row: PromotionProgress.RowOutcome, badge: Text?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.descriptor).font(.caption).lineLimit(1)
                Text(row.reason).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if let badge { badge }
            Text(row.postedAt.formatted(date: .abbreviated, time: .omitted)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            Text(MoneyFormat.string(code: currencyCode, abs(row.amount)))
                .font(.caption.monospacedDigit())
        }
        .padding(.vertical, 2)
    }

    private func directionBadge(_ row: PromotionProgress.RowOutcome) -> Text {
        guard case .review(let direction) = row.outcome else { return Text("") }
        switch direction {
        case .couldAdd: return Text("podría sumar").font(.caption2).foregroundStyle(.orange)
        case .couldSubtract: return Text("podría restar").font(.caption2).foregroundStyle(.orange)
        }
    }

    private func phaseLabel(_ phase: PromotionProgress.PeriodOutcome.Phase) -> String {
        switch phase {
        case .closedWon: return "ganado"
        case .closedLost: return "perdido"
        case .provisional: return "provisional"
        case .current: return "actual"
        case .future: return "futuro"
        }
    }

    private func reconciliationStatus(_ status: PromotionProgress.Reconciliation.Status) -> String {
        switch status {
        case .matched: return "aplicado"
        case .disputed: return "en disputa"
        case .unmatched: return "sin par"
        }
    }

    private func shortDate(_ iso: String) -> String {
        // "2026-09-22" → "22 sep"
        let parts = iso.split(separator: "-")
        guard parts.count == 3 else { return iso }
        let months = ["", "ene", "feb", "mar", "abr", "may", "jun",
                      "jul", "ago", "sep", "oct", "nov", "dic"]
        let monthIndex = Int(parts[1]) ?? 0
        let month = months.indices.contains(monthIndex) ? months[monthIndex] : String(parts[1])
        return "\(parts[2]) \(month)"
    }
}

private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !title.isEmpty {
                Text(title).font(.headline)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
