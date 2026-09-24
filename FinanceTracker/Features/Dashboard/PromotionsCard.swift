import SwiftUI

/// Compact promotion preview; its button always opens the active list and history.
struct PromoSummaryLine: View {
    let promotions: [PromotionProgress]
    let currencyCode: String
    let accountName: String

    @AppStorage private var featuredPromotionID: String
    @State private var showList = false

    init(promotions: [PromotionProgress], currencyCode: String, accountName: String, accountID: UUID) {
        self.promotions = promotions
        self.currencyCode = currencyCode
        self.accountName = accountName
        self._featuredPromotionID = AppStorage(wrappedValue: "", "dashboard.featuredPromotion.\(accountID.uuidString)")
    }

    private var active: [PromotionProgress] {
        promotions.filter { $0.campaignPhase == .active }
    }

    private var featuredPromotion: PromotionProgress? {
        active.first { $0.definitionID == featuredPromotionID }
    }

    var body: some View {
        Button { showList = true } label: {
            HStack(spacing: 8) {
                if let featuredPromotion {
                    Circle()
                        .fill(promotionColor(featuredPromotion, section: .active))
                        .frame(width: 7, height: 7)
                    Text(summaryText(featuredPromotion))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(active.isEmpty ? "Promociones" : "Elige una promoción para destacar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text("\(active.count) activas")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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
            PromoListSheet(promotions: promotions, currencyCode: currencyCode, accountName: accountName,
                           featuredPromotionID: $featuredPromotionID)
        }
    }

    private func summaryText(_ promo: PromotionProgress) -> String {
        "\(promo.displayName): \(promotionProgressText(promo, currencyCode: currencyCode))"
    }
}

/// Modal with active promotions first and collapsed upcoming/finished sections.
struct PromoListSheet: View {
    let promotions: [PromotionProgress]
    let currencyCode: String
    let accountName: String
    @Binding var featuredPromotionID: String

    @Environment(\.dismiss) private var dismiss
    @State private var selected: PromotionProgress? = nil
    @State private var showUpcoming = false
    @State private var showFinished = false
    @State private var showUnclassified = true

    private var active: [PromotionProgress] {
        promotions.filter { $0.campaignPhase == .active }.sorted {
            if $0.deadlineDate != $1.deadlineDate {
                return ($0.deadlineDate ?? .distantFuture) < ($1.deadlineDate ?? .distantFuture)
            }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    private var upcoming: [PromotionProgress] {
        promotions.filter { $0.campaignPhase == .upcoming }.sorted {
            ($0.campaignStartDate ?? .distantFuture) < ($1.campaignStartDate ?? .distantFuture)
        }
    }

    private var finished: [PromotionProgress] {
        promotions.filter { $0.campaignPhase == .finished }.sorted {
            ($0.campaignEndDate ?? .distantPast) > ($1.campaignEndDate ?? .distantPast)
        }
    }

    private var unclassified: [PromotionProgress] {
        promotions.filter { $0.campaignPhase == nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Promociones de \(accountName)")
                        .font(.headline)
                        .lineLimit(2)
                    Text("\(active.count) activas")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cerrar") { dismiss() }
            }
            .padding()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Activas (\(active.count))")
                            .font(.subheadline.weight(.semibold))
                        if !active.isEmpty {
                            Text("Elige con la estrella cuál mostrar en el resumen.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if active.isEmpty {
                        Text("No hay promociones activas.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        promotionRows(active, section: .active)
                    }

                    if !unclassified.isEmpty {
                        DisclosureGroup("Por revisar (\(unclassified.count))", isExpanded: $showUnclassified) {
                            promotionRows(unclassified, section: .unclassified)
                                .padding(.top, 6)
                        }
                        .font(.subheadline.weight(.semibold))
                    }

                    if !upcoming.isEmpty {
                        DisclosureGroup("Próximas (\(upcoming.count))", isExpanded: $showUpcoming) {
                            promotionRows(upcoming, section: .upcoming)
                                .padding(.top, 6)
                        }
                        .font(.subheadline.weight(.semibold))
                    }

                    if !finished.isEmpty {
                        DisclosureGroup("Terminadas (\(finished.count))", isExpanded: $showFinished) {
                            promotionRows(finished, section: .finished)
                                .padding(.top, 6)
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .sheet(item: $selected) { promo in
            PromotionDetailSheet(promo: promo, currencyCode: currencyCode)
        }
    }

    private func promotionRows(_ items: [PromotionProgress], section: PromoRowSection) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, promo in
                HStack(spacing: 4) {
                    Button { selected = promo } label: {
                        PromoListRow(promo: promo, currencyCode: currencyCode, section: section)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    if section == .active {
                        let isFeatured = featuredPromotionID == promo.definitionID
                        Button {
                            featuredPromotionID = isFeatured ? "" : promo.definitionID
                        } label: {
                            Image(systemName: isFeatured ? "star.fill" : "star")
                                .foregroundStyle(isFeatured ? .yellow : .secondary)
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(isFeatured ? "Quitar del resumen" : "Mostrar en el resumen")
                        .accessibilityLabel(isFeatured ? "Quitar del resumen" : "Mostrar en el resumen")
                    }
                }
                if index < items.count - 1 { DashboardSeparator() }
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
}

private enum PromoRowSection: Equatable { case active, upcoming, finished, unclassified }

private struct PromoListRow: View {
    let promo: PromotionProgress
    let currencyCode: String
    let section: PromoRowSection

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(promotionColor(promo, section: section))
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(promo.displayName)
                    .font(.body)
                    .lineLimit(1)
                if section == .unclassified, case .notCalculable(let reason) = promo.calculability {
                    Text(reason).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(primaryText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let secondaryText {
                    Text(secondaryText)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var primaryText: String {
        switch section {
        case .active: return promotionProgressText(promo, currencyCode: currencyCode)
        case .upcoming: return "Próxima"
        case .finished: return finishedResult
        case .unclassified: return "No calculable"
        }
    }

    private var secondaryText: String? {
        switch section {
        case .active: return promo.deadlineDisplayText
        case .upcoming:
            return promo.campaignStartDate.map { "Inicia \(promotionDateLabel($0))" }
        case .finished: return nil
        case .unclassified: return nil
        }
    }

    private var finishedResult: String {
        guard !promotionNeedsReview(promo) else { return "Resultado por revisar" }
        switch promo.shapeSummary {
        case .spendThreshold:
            if case .expired(reachedPerRecords: true) = promo.displayState { return "Meta alcanzada según registros" }
            return "Venció sin alcanzar la meta"
        case .cashback(let earned, _, _):
            return earned > 0
                ? "Cashback acumulado \(MoneyFormat.string(code: currencyCode, earned))"
                : "Venció sin cashback"
        case .tieredPeriods(let periods, let earned, _):
            let won = periods.filter { $0.phase == .closedWon }.count
            return "\(won)/\(periods.count) periodos ganados · \(MoneyFormat.string(code: currencyCode, earned))"
        }
    }
}

private func promotionProgressText(_ promo: PromotionProgress, currencyCode: String) -> String {
    switch promo.shapeSummary {
    case .spendThreshold(let target, let remaining):
        let value = "\(MoneyFormat.string(code: currencyCode, promo.eligibleFirm)) / \(MoneyFormat.string(code: currencyCode, target))"
        return remaining == 0 && promo.currentGoalReached ? "\(value) ✓" : value
    case .cashback(let earned, let cap, _):
        return "\(MoneyFormat.string(code: currencyCode, earned)) / \(MoneyFormat.string(code: currencyCode, cap))"
    case .tieredPeriods(let periods, let earned, let cap):
        if let current = periods.first(where: { $0.phase == .current }) {
            let value = "\(MoneyFormat.string(code: currencyCode, current.firm)) / \(MoneyFormat.string(code: currencyCode, current.threshold))"
            return promo.currentGoalReached ? "\(value) ✓" : value
        }
        return "\(MoneyFormat.string(code: currencyCode, earned)) / \(MoneyFormat.string(code: currencyCode, cap))"
    }
}

private func promotionNeedsReview(_ promo: PromotionProgress) -> Bool {
    if !promo.knownUnknowns.isEmpty { return true }
    switch promo.displayState {
    case .thresholdSuspended, .provisional, .estimated, .expiredSuspended: return true
    default: return false
    }
}

private func promotionColor(_ promo: PromotionProgress, section: PromoRowSection) -> Color {
    switch section {
    case .upcoming: return .gray
    case .unclassified: return .orange
    case .active:
        if promotionNeedsReview(promo) { return .orange }
        return promo.currentGoalReached ? .green : .blue
    case .finished:
        if promotionNeedsReview(promo) { return .orange }
        switch promo.shapeSummary {
        case .spendThreshold:
            if case .expired(reachedPerRecords: true) = promo.displayState { return .green }
        case .cashback(let earned, _, _):
            if earned > 0 { return .green }
        case .tieredPeriods(let periods, _, _):
            if periods.contains(where: { $0.phase == .closedWon }) { return .green }
        }
        return .gray
    }
}

func promotionDateLabel(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "es_MX")
    formatter.timeZone = TimeZone(identifier: "America/Mexico_City")
    formatter.dateFormat = "d MMM"
    return formatter.string(from: date).replacingOccurrences(of: ".", with: "")
}

extension PromotionProgress {
    var deadlineDisplayText: String? {
        guard let deadlineDate else { return nil }
        let date = promotionDateLabel(deadlineDate)
        guard let daysRemaining else { return date }
        if daysRemaining == 0 { return "\(date) (vence hoy)" }
        if daysRemaining == 1 { return "\(date) (queda 1 día)" }
        return "\(date) (quedan \(daysRemaining) días)"
    }
}

extension PromotionProgress: Identifiable {
    var id: String { definitionID }
}

#Preview("Promoción activa") {
    PromoListRow(promo: promotionPreview(id: "active", name: "Everyday Value (Gold)",
        phase: .active, firm: 2_500, target: 5_000, state: .enCurso, goalReached: false),
        currencyCode: "MXN", section: .active)
        .padding().frame(width: 620)
}

#Preview("Meta alcanzada") {
    PromoListRow(promo: promotionPreview(id: "reached", name: "Bono de bienvenida Gold",
        phase: .active, firm: 100_000, target: 100_000, state: .thresholdReachedPerRecords, goalReached: true),
        currencyCode: "MXN", section: .active)
        .padding().frame(width: 620)
}

#Preview("Promoción terminada") {
    PromoListRow(promo: promotionPreview(id: "finished", name: "Cashback Supermercados",
        phase: .finished, firm: 20_000, target: 25_000, state: .expired(reachedPerRecords: false), goalReached: false),
        currencyCode: "MXN", section: .finished)
        .padding().frame(width: 620)
}

#Preview("Resultado por revisar") {
    var promo = promotionPreview(id: "review", name: "Cashback Casual Dining",
        phase: .active, firm: 5_100, target: 5_000, state: .thresholdSuspended, goalReached: false)
    promo.possibleNegativeAdjustment = 300
    return PromoListRow(promo: promo, currencyCode: "MXN", section: .active)
        .padding().frame(width: 620)
}

private func promotionPreview(id: String, name: String, phase: PromotionProgress.CampaignPhase,
                              firm: Decimal, target: Decimal, state: PromotionProgress.DisplayState,
                              goalReached: Bool) -> PromotionProgress {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Mexico_City")!
    let start = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1))!
    let end = calendar.date(from: DateComponents(year: 2026, month: 9, day: 30))!
    var promo = PromotionProgress(definitionID: id, displayName: name, calculability: .calculable,
                                  eligibleFirm: firm, rows: [])
    promo.campaignPhase = phase
    promo.campaignStartDate = start
    promo.campaignEndDate = end
    promo.deadlineDate = phase == .active ? end : nil
    promo.daysRemaining = phase == .active ? 8 : nil
    promo.currentGoalReached = goalReached
    promo.displayState = state
    promo.shapeSummary = .spendThreshold(target: target, remaining: max(0, target - firm))
    return promo
}
