import SwiftUI

/// Drill-down de una promoción (patrón BreakdownSheet: material fuente embebido, cero fetches).
/// Desglose por clase de incertidumbre, periodos, fila por transacción con razón y dirección,
/// candidatos de recibo sin asignar, supuestos declarados (spec F "a un clic / en detalle").
struct PromotionDetailSheet: View {
    let promo: PromotionProgress
    let currencyCode: String
    @Environment(\.dismiss) private var dismiss

    private var eligibleRows: [PromotionProgress.RowOutcome] {
        promo.rows.filter { if case .eligible = $0.outcome { return true }; return false }
    }
    private var reviewRows: [PromotionProgress.RowOutcome] {
        promo.rows.filter { if case .review = $0.outcome { return true }; return false }
    }
    private var excludedRows: [PromotionProgress.RowOutcome] {
        promo.rows.filter { if case .excluded = $0.outcome { return true }; return false }
    }
    private var evidenceRows: [PromotionProgress.RowOutcome] {
        promo.rows.filter { if case .evidence = $0.outcome { return true }; return false }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                summary
                if case .calculable = promo.calculability {
                    periodsSection
                    reviewSection
                    eligibleSection
                    conversionRisksSection
                    receiptCandidatesSection
                    excludedSection
                    evidenceSection
                }
                assumptionsSection
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 480, minHeight: 420)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(promo.displayName).font(.title2.bold())
                Spacer()
                Button("Cerrar") { dismiss() }
            }
            if case .notCalculable(let reason) = promo.calculability {
                Text("No calculable — \(reason)")
                    .font(.body).foregroundStyle(.orange)
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Avance firme: \(MoneyFormat.string(code: currencyCode, promo.eligibleFirm))")
                .font(.title3.monospacedDigit())
            if promo.possiblePositiveAddition > 0 || promo.possibleNegativeAdjustment > 0 {
                Text("± \(MoneyFormat.string(code: currencyCode, promo.possiblePositiveAddition)) por revisar · posible ajuste −\(MoneyFormat.string(code: currencyCode, promo.possibleNegativeAdjustment)) — provisional")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let days = promo.daysRemaining {
                Text("Quedan \(days) días (contra la fecha de evaluación)").font(.caption).foregroundStyle(.secondary)
            }
            if !promo.overlaps.isEmpty {
                Text("Comercios compartidos con: \(promo.overlaps.joined(separator: ", ")) — conteo único no confirmado por el emisor")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var periodsSection: some View {
        if case .tieredPeriods(let periods, let earned, let cap) = promo.shapeSummary {
            Section(title: "Periodos — devengado \(MoneyFormat.string(code: currencyCode, earned)) de \(MoneyFormat.string(code: currencyCode, cap))") {
                ForEach(periods, id: \.start) { p in
                    HStack {
                        Text("\(p.start) → \(p.end)").font(.caption.monospacedDigit())
                        Spacer()
                        Text(phaseLabel(p.phase)).font(.caption2).foregroundStyle(.secondary)
                        Text("\(MoneyFormat.string(code: currencyCode, p.firm)) / \(MoneyFormat.string(code: currencyCode, p.threshold))")
                            .font(.caption.monospacedDigit())
                        if p.rewardEarned > 0 {
                            Text("+\(MoneyFormat.string(code: currencyCode, p.rewardEarned))")
                                .font(.caption2.monospacedDigit()).foregroundStyle(.green)
                        }
                    }
                }
                Text("Resultados de periodos cerrados son finales salvo statements importados tarde.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

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
        Section(title: "Excluidas (\(excludedRows.count))") {
            ForEach(excludedRows, id: \.transactionID) { row in
                rowView(row, badge: nil)
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
        if !promo.conversionRisks.isEmpty {
            Section(title: "Riesgo de conversión MSI (no se descuenta del firme)") {
                ForEach(promo.conversionRisks, id: \.transactionID) { risk in
                    Text("Cargo ≥ \(MoneyFormat.string(code: currencyCode, risk.amount)) puede convertirse a MSI — si el emisor lo convierte, contarían solo las cuotas que se publiquen.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder
    private var receiptCandidatesSection: some View {
        if !promo.receiptCandidates.isEmpty {
            Section(title: "Créditos candidatos a recibo (sin asignar)") {
                ForEach(promo.receiptCandidates, id: \.transactionID) { c in
                    HStack {
                        Text(c.postedAt.formatted(date: .abbreviated, time: .omitted)).font(.caption.monospacedDigit())
                        Spacer()
                        Text(MoneyFormat.string(code: currencyCode, c.amount)).font(.caption.monospacedDigit())
                    }
                }
                Text("Posible recompensa recibida — confirmación humana pendiente (V1 no asigna automáticamente).")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var assumptionsSection: some View {
        Section(title: "Supuestos declarados (knownUnknowns)") {
            ForEach(promo.knownUnknowns, id: \.self) { s in
                Text("· \(s)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - helpers

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
        case .current: return "actual"
        case .future: return "futuro"
        }
    }
}

private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
