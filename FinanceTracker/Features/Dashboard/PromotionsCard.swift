import SwiftUI

/// Línea promo sutil para LiabilityAccountDashboard (feedback 2026-09-22):
/// una sola línea bajo el header; click → lista compacta → drill-down.
/// Solo mide, nunca recomienda gasto.
struct PromoSummaryLine: View {
    let promotions: [PromotionProgress]
    let currencyCode: String

    @State private var showList = false

    /// La promo más relevante: la del plazo más corto entre las activas con avance;
    /// si ninguna tiene avance, la del plazo más corto (urgencia).
    private var headline: PromotionProgress? {
        let active = promotions.filter {
            if case .expired = $0.displayState { return false }
            if case .expiredSuspended = $0.displayState { return false }
            return true
        }
        guard !active.isEmpty else { return nil }
        let withProgress = active.filter { $0.eligibleFirm > 0 }
        let pool = withProgress.isEmpty ? active : withProgress
        return pool.min { (a, b) in
            (a.daysRemaining ?? Int.max) < (b.daysRemaining ?? Int.max)
        }
    }

    var body: some View {
        if let promo = headline {
            Button { showList = true } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(stateColor(promo))
                        .frame(width: 7, height: 7)
                    Text(summaryText(promo))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    if promotions.count > 1 {
                        Text("\(promotions.count) promos")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showList) {
                PromoListSheet(promotions: promotions, currencyCode: currencyCode)
            }
        }
    }

    private func summaryText(_ promo: PromotionProgress) -> String {
        let name = promo.displayName
        let amount: String
        switch promo.shapeSummary {
        case .spendThreshold:
            amount = "\(MoneyFormat.string(code: currencyCode, promo.eligibleFirm)) / \(targetText(promo))"
        case .cashback(let devengado, _, _):
            amount = MoneyFormat.string(code: currencyCode, devengado)
        case .tieredPeriods(let periods, _, _):
            if let current = periods.first(where: { $0.phase == .current }) {
                amount = "\(MoneyFormat.string(code: currencyCode, current.firm)) / \(MoneyFormat.string(code: currencyCode, current.threshold))"
            } else {
                amount = MoneyFormat.string(code: currencyCode, promo.eligibleFirm)
            }
        }
        let days = promo.daysRemaining.map { " · quedan \($0)d" } ?? ""
        return "\(name): \(amount)\(days)"
    }

    private func targetText(_ promo: PromotionProgress) -> String {
        switch promo.shapeSummary {
        case .spendThreshold(let target, _): return MoneyFormat.string(code: currencyCode, target)
        default: return ""
        }
    }

    private func stateColor(_ promo: PromotionProgress) -> Color {
        switch promo.displayState {
        case .enCurso: return .blue
        case .thresholdReachedPerRecords: return .green
        case .thresholdSuspended, .provisional, .estimated: return .orange
        case .expiredSuspended: return .orange
        case .expired: return .gray
        }
    }
}

/// Lista compacta de todas las promos (una línea por promo, tap → detalle).
struct PromoListSheet: View {
    let promotions: [PromotionProgress]
    let currencyCode: String
    @Environment(\.dismiss) private var dismiss
    @State private var selected: PromotionProgress? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Promociones (\(promotions.count))").font(.headline)
                Spacer()
                Button("Cerrar") { dismiss() }
            }
            .padding()

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(promotions) { promo in
                        Button { selected = promo } label: { listRow(promo) }
                            .buttonStyle(.plain)
                        if promo.id != promotions.last?.id {
                            DashboardSeparator()
                        }
                    }
                }
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
                .padding(.horizontal)
                .padding(.bottom)
            }
        }
        .frame(minWidth: 420, minHeight: 320)
        .sheet(item: $selected) { promo in
            PromotionDetailSheet(promo: promo, currencyCode: currencyCode)
        }
    }

    private func listRow(_ promo: PromotionProgress) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(stateColor(promo))
                .frame(width: 6, height: 6)
            Text(promo.displayName)
                .font(.body)
                .lineLimit(1)
            Spacer()
            Text(amountText(promo))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if let days = promo.daysRemaining {
                Text("· \(days)d")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func amountText(_ promo: PromotionProgress) -> String {
        switch promo.shapeSummary {
        case .spendThreshold(_, let remaining):
            return remaining > 0
                ? MoneyFormat.string(code: currencyCode, promo.eligibleFirm)
                : "\(MoneyFormat.string(code: currencyCode, promo.eligibleFirm)) ✓"
        case .cashback(let devengado, _, _):
            return MoneyFormat.string(code: currencyCode, devengado)
        case .tieredPeriods(let periods, let earned, let cap):
            if let current = periods.first(where: { $0.phase == .current }) {
                return "\(MoneyFormat.string(code: currencyCode, current.firm)) / \(MoneyFormat.string(code: currencyCode, current.threshold))"
            }
            return "\(MoneyFormat.string(code: currencyCode, earned)) / \(MoneyFormat.string(code: currencyCode, cap))"
        }
    }

    private func stateColor(_ promo: PromotionProgress) -> Color {
        switch promo.displayState {
        case .enCurso: return .blue
        case .thresholdReachedPerRecords: return .green
        case .thresholdSuspended, .provisional, .estimated: return .orange
        case .expiredSuspended: return .orange
        case .expired: return .gray
        }
    }
}

extension PromotionProgress: Identifiable {
    var id: String { definitionID }
}
