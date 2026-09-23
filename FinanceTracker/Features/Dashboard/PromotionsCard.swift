import SwiftUI

/// Card «Promociones» para LiabilityAccountDashboard (spec F):
/// una fila por promo activa con la consecuencia de su clase de incertidumbre;
/// ausente con 0 promos; terminadas colapsadas al fondo. Solo mide, nunca recomienda gasto.
struct PromotionsCard: View {
    let promotions: [PromotionProgress]
    let currencyCode: String

    @State private var selected: PromotionProgress? = nil
    @State private var showFinished = false

    private var active: [PromotionProgress] {
        promotions.filter {
            if case .expired = $0.displayState { return false }
            if case .expiredSuspended = $0.displayState { return false }
            return true
        }
    }

    private var finished: [PromotionProgress] {
        promotions.filter { !active.contains($0) }
    }

    var body: some View {
        ChartCard(title: "Promociones") {
            ForEach(active) { promo in
                Button { selected = promo } label: { row(promo) }
                    .buttonStyle(.plain)
                if promo.id != active.last?.id { Divider() }
            }
            if !finished.isEmpty {
                DisclosureGroup("Terminadas (\(finished.count))", isExpanded: $showFinished) {
                    ForEach(finished) { promo in
                        Button { selected = promo } label: { row(promo) }
                            .buttonStyle(.plain)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .sheet(item: $selected) { promo in
            PromotionDetailSheet(promo: promo, currencyCode: currencyCode)
        }
    }

    // MARK: - Fila por promo (número principal degradado según clase de incertidumbre)

    @ViewBuilder
    private func row(_ promo: PromotionProgress) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(promo.displayName).font(.body).lineLimit(1)
                Spacer()
                stateChip(promo)
            }

            switch promo.calculability {
            case .notCalculable(let reason):
                // Clase ①: sin número — solo qué falta.
                Text("Pendiente: \(reason)")
                    .font(.caption).foregroundStyle(.secondary)
            case .calculable:
                progressContent(promo)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func progressContent(_ promo: PromotionProgress) -> some View {
        switch promo.shapeSummary {
        case .spendThreshold(let target, let remaining):
            bar(value: promo.eligibleFirm, total: max(target, 1))
            let labels = [
                remaining > 0 ? "falta \(MoneyFormat.string(code: currencyCode, remaining))" : nil,
                promo.knownUnknowns.isEmpty ? nil : "estimación bajo supuestos",
            ].compactMap { $0 }
            amountLine(firm: promo.eligibleFirm, total: target,
                       suffix: labels.isEmpty ? nil : "· " + labels.joined(separator: " · "),
                       promo: promo)

        case .cashback(let devengado, let cap, _):
            bar(value: devengado, total: max(cap, 1))
            let label = promo.knownUnknowns.isEmpty ? "cashback según registros" : "estimación bajo supuestos"
            amountLine(firm: devengado, total: cap, suffix: label, promo: promo)

        case .tieredPeriods(let periods, let earned, let cap):
            if let current = periods.first(where: { $0.phase == .current }) {
                bar(value: current.firm, total: max(current.threshold, 1))
                let earnedLabel = promo.knownUnknowns.isEmpty ? "según registros" : "estimación bajo supuestos"
                amountLine(firm: current.firm, total: current.threshold,
                           suffix: "· \(wonCount(periods))/\(periods.count) periodos · \(earnedLabel) \(MoneyFormat.string(code: currencyCode, earned))/\(MoneyFormat.string(code: currencyCode, cap))",
                           promo: promo)
            } else {
                let earnedLabel = promo.knownUnknowns.isEmpty ? "según registros" : "estimación bajo supuestos"
                Text("\(wonCount(periods))/\(periods.count) periodos · \(earnedLabel) \(MoneyFormat.string(code: currencyCode, earned))/\(MoneyFormat.string(code: currencyCode, cap))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }

        // Banda de incertidumbre (clase ③): identificada y separada, jamás sumada al firme.
        if promo.possiblePositiveAddition > 0 || promo.possibleNegativeAdjustment > 0 {
            Text("± \(MoneyFormat.string(code: currencyCode, promo.possiblePositiveAddition)) por revisar · posible ajuste −\(MoneyFormat.string(code: currencyCode, promo.possibleNegativeAdjustment))")
                .font(.caption2).foregroundStyle(.orange)
        }
        if !promo.overlaps.isEmpty {
            Text("También cuenta en: \(promo.overlaps.joined(separator: ", ")) — conteo único no confirmado")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func amountLine(firm: Decimal, total: Decimal, suffix: String?, promo: PromotionProgress) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("\(MoneyFormat.string(code: currencyCode, firm)) / \(MoneyFormat.string(code: currencyCode, total))")
                .font(.caption.monospacedDigit())
            if let suffix {
                Text(suffix).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if let days = promo.daysRemaining {
                Text("quedan \(days)d").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private func bar(value: Decimal, total: Decimal) -> some View {
        let v = (value as NSDecimalNumber).doubleValue
        let t = (total as NSDecimalNumber).doubleValue
        return ProgressView(value: min(v / max(t, 1), 1))
            .progressViewStyle(.linear)
            .tint(.blue)
    }

    private func stateChip(_ promo: PromotionProgress) -> some View {
        let text: String
        let color: Color
        switch promo.displayState {
        case .enCurso: text = "En curso"; color = .blue
        case .thresholdReachedPerRecords: text = "Umbral alcanzado —según registros—"; color = .green
        case .thresholdSuspended: text = "Suspendido —ambigüedad—"; color = .orange
        case .provisional: text = "Provisional —por revisar—"; color = .orange
        case .estimated: text = "Estimación bajo supuestos"; color = .orange
        case .expiredSuspended: text = "Cerrada —pendiente de resolver—"; color = .orange
        case .expired(true): text = "Cerrada —con avance—"; color = .secondary
        case .expired(false): text = "Cerrada —sin alcanzar—"; color = .secondary
        }
        return Text(text)
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private func wonCount(_ periods: [PromotionProgress.PeriodOutcome]) -> Int {
        periods.filter { $0.phase == .closedWon }.count
    }
}

extension PromotionProgress: Identifiable {
    var id: String { definitionID }
}

#Preview("Promotions — estimate under assumptions") {
    var promo = PromotionProgress(definitionID: "gold", displayName: "Gold everyday value",
                                  calculability: .calculable, eligibleFirm: 6_200, rows: [])
    promo.displayState = .estimated
    promo.knownUnknowns = ["PostedAt se aproxima a la fecha de facturación."]
    return PromotionsCard(promotions: [promo], currencyCode: "MXN").frame(width: 480)
}

#Preview("Promotions — closed periods") {
    var promo = PromotionProgress(definitionID: "gold", displayName: "Gold everyday value",
                                  calculability: .calculable, eligibleFirm: 12_000, rows: [])
    promo.displayState = .expired(reachedPerRecords: true)
    promo.shapeSummary = .tieredPeriods(periods: [
        .init(start: "2026-09-22", end: "2026-09-30", phase: .closedWon,
              firm: 5_200, threshold: 5_000, rewardEarned: 1_000),
        .init(start: "2026-10-01", end: "2026-12-31", phase: .closedLost,
              firm: 4_000, threshold: 5_000, rewardEarned: 0),
    ], earnedTotal: 1_000, annualCap: 4_000)
    return PromotionsCard(promotions: [promo], currencyCode: "MXN").frame(width: 480)
}

#Preview("Promotion detail — empty / not calculable") {
    PromotionDetailSheet(promo: PromotionProgress(definitionID: "unbound", displayName: "Gold promotion",
        calculability: .notCalculable("UUID de cuenta pendiente"), eligibleFirm: 0, rows: []),
        currencyCode: "MXN")
}
