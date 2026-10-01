import SwiftUI
import SwiftData

// MARK: - Modelo de vista compartido

/// Carga el ledger y las transacciones vivas para que las vistas de promociones
/// calculen el avance en vivo. Se recarga al aparecer y con cada notificación
/// de escritura del store.
@MainActor
@Observable
final class PromotionLedgerViewModel {
    private(set) var ledger = PromotionLedger()
    private(set) var entries: [PromotionLedgerEntry] = []
    private(set) var loadError: String?

    func reload(context: ModelContext) {
        do {
            ledger = try PromotionLedgerStore.read()
            loadError = nil
        } catch {
            // Fail-visible: sin números inventados sobre un archivo dañado.
            ledger = PromotionLedger()
            loadError = error.localizedDescription
        }
        let descriptor = FetchDescriptor<Transaction>()
        entries = (try? context.fetch(descriptor)).map(Self.entries(from:)) ?? []
    }

    /// SwiftData → vista ligera de evaluación (testeable sin contenedor:
    /// los @Model no insertados funcionan como valores).
    nonisolated static func entries(from transactions: [Transaction]) -> [PromotionLedgerEntry] {
        transactions.map {
            PromotionLedgerEntry(id: $0.id, amount: $0.amount, currency: $0.currency,
                                 postedAt: $0.postedAt, deletedAt: $0.deletedAt,
                                 description: $0.descriptionRaw)
        }
    }

    var promotionCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }
}

// MARK: - Formato de ventana (es-MX)

extension PromotionWindowState {
    /// Etiqueta compacta de la ventana para cards y encabezados.
    var label: String? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es_MX")
        formatter.timeZone = MexicoBankingCalendar.timeZone
        formatter.dateFormat = "d MMM"
        switch self {
        case .none:
            return nil
        case .before(let start, let days):
            let text = formatter.string(from: start)
            return days == 1 ? "comienza el \(text) (mañana)" : "comienza el \(text) (en \(days) días)"
        case .during(let dayNumber, let totalDays, let daysRemaining):
            switch (dayNumber, totalDays, daysRemaining) {
            case (let day?, let total?, let remaining?):
                return "día \(day) de \(total) · quedan \(remaining)"
            case (let day?, _, _):
                return "día \(day)"
            case (_, _, let remaining?):
                return "quedan \(remaining) días"
            default:
                return nil
            }
        case .after(let end, _):
            return "ventana cerrada el \(formatter.string(from: end))"
        }
    }
}

// MARK: - Línea de resumen (dashboard de tarjeta)

/// Card compacta de promociones por adjudicación manual: el avance es
/// exactamente lo adjudicado por el dueño; la app informa, no deduce (AD-025).
struct PromotionsSummaryLine: View {
    let accountID: UUID

    @Environment(\.modelContext) private var modelContext
    @State private var model = PromotionLedgerViewModel()
    @State private var selected: PromotionRecord?

    var body: some View {
        let summaries = PromotionBoard.activeSummaries(ledger: model.ledger, anchoredTo: accountID,
                                                       transactions: model.entries, asOf: .now,
                                                       calendar: model.promotionCalendar)
        Group {
            if let loadError = model.loadError {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Promociones no disponibles")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(loadError)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else if !summaries.isEmpty {
                // Spec UI 1: fila por promo activa — nombre, avance/meta, día N/M,
                // marca de fuera de ventana; tap abre el drill-down.
                VStack(spacing: 0) {
                    ForEach(Array(summaries.enumerated()), id: \.element.id) { index, summary in
                        Button { selected = summary.record } label: {
                            PromotionRow(summary: summary)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                        if index < summaries.count - 1 { DashboardSeparator() }
                    }
                }
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
            }
        }
        .sheet(item: $selected) { record in
            ManualPromotionDetailSheet(recordID: record.id)
        }
        .task { model.reload(context: modelContext) }
        .onReceive(NotificationCenter.default.publisher(for: PromotionLedgerStore.didChangeNotification)) { _ in
            model.reload(context: modelContext)
        }
    }

}

// MARK: - Lista de promos de la cuenta

struct PromotionsListSheet: View {
    let accountID: UUID

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var model = PromotionLedgerViewModel()
    @State private var selected: PromotionRecord?
    @State private var showingEditor = false

    var body: some View {
        let calendar = model.promotionCalendar
        let active = PromotionBoard.activeSummaries(ledger: model.ledger, anchoredTo: accountID,
                                                    transactions: model.entries, asOf: .now,
                                                    calendar: calendar)
        let archived = model.ledger.promotions.filter {
            $0.accountID == accountID && $0.deletedAt == nil && $0.archivedAt != nil
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        VStack(spacing: 0) {
            HStack {
                Text("Promociones")
                    .font(.headline)
                Spacer()
                Button("Nueva promoción") { showingEditor = true }
                Button("Cerrar") { dismiss() }
            }
            .padding()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let loadError = model.loadError {
                        Text("No se pudo leer el ledger: \(loadError)")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if active.isEmpty && archived.isEmpty {
                        Text("Sin promociones para esta cuenta. Crea una para empezar a adjudicar transacciones.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        summaryRows(active)
                        if !archived.isEmpty {
                            DisclosureGroup("Archivadas (\(archived.count))") {
                                summaryRows(PromotionBoard.allSummaries(ledger: model.ledger,
                                                                        transactions: model.entries,
                                                                        asOf: .now, calendar: calendar)
                                    .filter { $0.record.archivedAt != nil && $0.record.accountID == accountID })
                                    .padding(.top, 6)
                            }
                            .font(.subheadline.weight(.semibold))
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .sheet(item: $selected) { record in
            ManualPromotionDetailSheet(recordID: record.id)
        }
        .sheet(isPresented: $showingEditor) {
            PromotionEditorSheet(existing: nil, anchorAccountID: accountID)
        }
        .task { model.reload(context: modelContext) }
        .onReceive(NotificationCenter.default.publisher(for: PromotionLedgerStore.didChangeNotification)) { _ in
            model.reload(context: modelContext)
        }
    }

    private func summaryRows(_ summaries: [ManualPromotionSummary]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(summaries.enumerated()), id: \.element.id) { index, summary in
                Button { selected = summary.record } label: {
                    PromotionRow(summary: summary)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                if index < summaries.count - 1 { DashboardSeparator() }
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
}

struct PromotionRow: View {
    let summary: ManualPromotionSummary

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.record.name)
                    .font(.body)
                    .lineLimit(1)
                if let reward = summary.record.rewardNote, !reward.isEmpty {
                    Text(reward)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(advanceText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let window = summary.progress.window.label {
                    Text(window)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if summary.progress.outOfWindowCount > 0 {
                    Text("\(summary.progress.outOfWindowCount) fuera de ventana")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var advanceText: String {
        var text = MoneyFormat.string(code: summary.record.currency, summary.progress.advance)
        if let target = summary.record.targetAmount {
            let reached = summary.progress.advance >= target
            text += " / " + MoneyFormat.string(code: summary.record.currency, target) + (reached ? " ✓" : "")
        }
        return text
    }

    private var dotColor: Color {
        if summary.progress.orphanCount > 0 { return .orange }
        guard let target = summary.record.targetAmount else { return .blue }
        return summary.progress.advance >= target ? .green : .blue
    }
}

// MARK: - Detalle (drill-down de adjudicaciones)

struct ManualPromotionDetailSheet: View {
    let recordID: UUID

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var model = PromotionLedgerViewModel()
    @State private var showingEditor = false
    @State private var confirmingDelete = false
    @State private var actionError: String?

    var body: some View {
        let calendar = model.promotionCalendar
        let summaries = PromotionBoard.allSummaries(ledger: model.ledger, transactions: model.entries,
                                                    asOf: .now, calendar: calendar)
        let summary = summaries.first { $0.record.id == recordID }

        VStack(spacing: 0) {
            if let summary {
                header(summary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if let loadError = model.loadError {
                            Text("No se pudo leer el ledger: \(loadError)")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        rows(for: summary, calendar: calendar)
                        if let error = actionError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        footnote
                    }
                    .padding()
                }
                footer(summary)
            } else {
                Text("Esta promoción ya no existe.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .sheet(isPresented: $showingEditor) {
            PromotionEditorSheet(existing: summary?.record, anchorAccountID: nil)
        }
        .confirmationDialog("¿Eliminar la promoción? Sus adjudicaciones quedarán como huérfanas visibles.",
                            isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Eliminar promoción", role: .destructive) {
                applyAction("eliminar") { try PromotionLedgerStore.deletePromotion(id: recordID) }
            }
        }
        .task { model.reload(context: modelContext) }
        .onReceive(NotificationCenter.default.publisher(for: PromotionLedgerStore.didChangeNotification)) { _ in
            model.reload(context: modelContext)
        }
    }

    private func header(_ summary: ManualPromotionSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(summary.record.name).font(.headline)
                    if let window = summary.progress.window.label {
                        Text(window).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let reward = summary.record.rewardNote, !reward.isEmpty {
                    Text(reward).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(MoneyFormat.string(code: summary.record.currency, summary.progress.advance)
                 + (summary.record.targetAmount.map { " de " + MoneyFormat.string(code: summary.record.currency, $0) } ?? ""))
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            if let target = summary.record.targetAmount {
                let capped = max(0, min(1, summary.progress.advance / target))
                let fraction = CGFloat(truncating: NSDecimalNumber(decimal: capped))
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(Color.blue).frame(width: proxy.size.width * fraction)
                    }
                }
                .frame(height: 4)
            }
        }
        .padding()
    }

    private func rows(for summary: ManualPromotionSummary, calendar: Calendar) -> some View {
        let rows = PromotionBoard.detailRows(promotionID: recordID, ledger: model.ledger,
                                             transactions: model.entries, calendar: calendar)
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                detailRow(row, currency: summary.record.currency)
                if index < rows.count - 1 { DashboardSeparator() }
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    private func detailRow(_ row: PromotionDetailRow, currency: String) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(row.excludedReason == nil ? (row.isOutOfWindow ? Color.orange : Color.blue) : Color.gray.opacity(0.4))
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.description.isEmpty ? row.excludedReason ?? "" : row.description)
                    .font(.callout)
                    .lineLimit(1)
                    .foregroundStyle(row.excludedReason == nil ? .primary : .secondary)
                if let date = row.date {
                    Text(promotionRowDateLabel(date))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            if let contribution = row.contribution {
                VStack(alignment: .trailing, spacing: 2) {
                    Text((contribution >= 0 ? "+" : "") + MoneyFormat.string(code: currency, contribution))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(contribution >= 0 ? .primary : .secondary)
                    if row.isOutOfWindow {
                        Text("fuera de ventana").font(.caption2).foregroundStyle(.orange)
                    }
                }
            } else {
                Text(row.excludedReason ?? "")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .opacity(row.excludedReason == nil ? 1 : 0.7)
    }

    private var footnote: some View {
        Text("El avance es exactamente lo que adjudicaste: los créditos restan y las filas fuera de ventana cuentan igual. El sistema no deduce elegibilidad ni evita duplicidad económica (una compra y sus cuotas pueden ambas estar adjudicadas).")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.top, 4)
    }

    private func footer(_ summary: ManualPromotionSummary) -> some View {
        HStack {
            Button("Editar") { showingEditor = true }
            Spacer()
            if summary.record.archivedAt == nil {
                Button("Archivar") {
                    var record = summary.record
                    record.archivedAt = .now
                    record.updatedAt = .now
                    applyAction("archivar") { try PromotionLedgerStore.save(promotion: record) }
                }
            } else {
                Button("Reactivar") {
                    var record = summary.record
                    record.archivedAt = nil
                    record.updatedAt = .now
                    applyAction("reactivar") { try PromotionLedgerStore.save(promotion: record) }
                }
            }
            Button("Eliminar…", role: .destructive) { confirmingDelete = true }
        }
        .padding()
    }

    private func applyAction(_ name: String, _ operation: () throws -> Void) {
        do {
            try operation()
            if name == "eliminar" { dismiss() }
        } catch {
            actionError = "No se pudo \(name) la promoción: \(error.localizedDescription)"
        }
    }
}

private func promotionRowDateLabel(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "es_MX")
    formatter.timeZone = MexicoBankingCalendar.timeZone
    formatter.dateFormat = "d MMM yyyy"
    return formatter.string(from: date)
}

// MARK: - Editor (crear / editar)

struct PromotionEditorSheet: View {
    let existing: PromotionRecord?
    /// Cuenta sugerida al crear desde el dashboard de una tarjeta.
    let anchorAccountID: UUID?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Account.nickname) private var accounts: [Account]

    @State private var name = ""
    @State private var accountID: UUID?
    @State private var currency = "MXN"
    @State private var hasWindow = false
    @State private var windowStart = Date.now
    @State private var windowEnd = Date.now
    @State private var targetText = ""
    @State private var rewardNote = ""
    @State private var notes = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 12) {
                fieldRow("Nombre") {
                    TextField("Platinum 90 días", text: $name)
                        .textFieldStyle(.roundedBorder)
                }
                fieldRow("Cuenta") {
                    Picker("", selection: $accountID) {
                        ForEach(accounts) { account in
                            Text(account.displayName).tag(Optional(account.id))
                        }
                    }
                    .labelsHidden()
                }
                fieldRow("Moneda") {
                    Picker("", selection: $currency) {
                        ForEach(availableCurrencies, id: \.self) { code in
                            Text(code).tag(code)
                        }
                    }
                    .labelsHidden()
                }
                fieldRow("Ventana") {
                    Toggle("", isOn: $hasWindow).labelsHidden()
                }
                if hasWindow {
                    fieldRow("Inicia") {
                        DatePicker("", selection: $windowStart, displayedComponents: .date)
                            .labelsHidden()
                    }
                    fieldRow("Termina") {
                        DatePicker("", selection: $windowEnd, displayedComponents: .date)
                            .labelsHidden()
                    }
                }
                fieldRow("Meta (\(currency))") {
                    TextField("100,000", text: $targetText)
                        .textFieldStyle(.roundedBorder)
                        .monospacedDigit()
                }
                fieldRow("Recompensa") {
                    TextField("15,000 MR / crédito en el estado", text: $rewardNote)
                        .textFieldStyle(.roundedBorder)
                }
                fieldRow("Notas") {
                    TextField("Notas", text: $notes, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...3)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("Cancelar") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(existing == nil ? "Crear" : "Guardar") { save() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || accountID == nil)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear { populate() }
        .onChange(of: accountID) {
            // Al crear, la moneda por defecto es la de la cuenta ancla (PA-05).
            guard existing == nil, let accountID,
                  let account = accounts.first(where: { $0.id == accountID }) else { return }
            currency = account.currency
        }
    }

    private var availableCurrencies: [String] {
        var codes = Set(accounts.map(\.currency))
        codes.insert(currency)
        return codes.sorted()
    }

    private func fieldRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.callout)
                .frame(width: 120, alignment: .leading)
            Spacer()
            content()
        }
    }

    private func populate() {
        guard accountID == nil else { return }
        if let existing {
            name = existing.name
            accountID = existing.accountID
            currency = existing.currency
            if let start = existing.windowStart {
                hasWindow = true
                windowStart = start
                windowEnd = existing.windowEnd ?? start
            }
            if let target = existing.targetAmount {
                targetText = MoneyFormat.string(code: existing.currency, target)
            }
            rewardNote = existing.rewardNote ?? ""
            notes = existing.notes ?? ""
        } else {
            accountID = anchorAccountID ?? accounts.first?.id
            if let anchored = accounts.first(where: { $0.id == anchorAccountID }) {
                currency = anchored.currency
            }
        }
    }

    private func save() {
        guard let accountID else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }
        let target = parseAmount(targetText)
        if let target, target <= 0 {
            errorMessage = "La meta debe ser mayor que cero."
            return
        }
        let now = Date.now
        let record = PromotionRecord(
            id: existing?.id ?? UUID(),
            name: trimmedName,
            accountID: accountID,
            currency: currency,
            windowStart: hasWindow ? windowStart : nil,
            windowEnd: hasWindow ? max(windowStart, windowEnd) : nil,
            targetAmount: target,
            rewardNote: rewardNote.trimmingCharacters(in: .whitespaces).isEmpty ? nil : rewardNote,
            notes: notes.trimmingCharacters(in: .whitespaces).isEmpty ? nil : notes,
            archivedAt: existing?.archivedAt,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now,
            deletedAt: existing?.deletedAt)
        do {
            try PromotionLedgerStore.save(promotion: record)
            dismiss()
        } catch {
            errorMessage = "No se pudo guardar la promoción: \(error.localizedDescription)"
        }
    }

    private func parseAmount(_ text: String) -> Decimal? {
        let cleaned = text
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }
        return Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX"))
            ?? Decimal(string: cleaned)
    }
}

// MARK: - Settings

/// Lista completa de promociones, independiente de cualquier cuenta: activas,
/// archivadas y con cuenta eliminada (re-anclables). Garantiza que ninguna
/// promo quede inaccesible.
struct PromotionSettingsSection: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Account.nickname) private var accounts: [Account]
    @State private var model = PromotionLedgerViewModel()
    @State private var selected: PromotionRecord?
    @State private var showingEditor = false

    var body: some View {
        let calendar = model.promotionCalendar
        let summaries = PromotionBoard.allSummaries(ledger: model.ledger, transactions: model.entries,
                                                    asOf: .now, calendar: calendar)
        let active = summaries.filter { $0.record.archivedAt == nil }
        let archived = summaries.filter { $0.record.archivedAt != nil }
        let accountNames = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.displayName) })

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Promociones por adjudicación manual")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("Nueva promoción") { showingEditor = true }
            }
            if let loadError = model.loadError {
                Text("No se pudo leer el ledger: \(loadError)")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            let repairNotes = PromotionLedgerStore.validate(model.ledger)
            if !repairNotes.isEmpty {
                Text(repairNotes.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            orphanedAttributionsSection
            if summaries.isEmpty {
                Text("Sin promociones. Crea una (p. ej. «Platinum 90 días») y adjudica transacciones desde su detalle.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(active) { summary in
                    settingsRow(summary, accountNames: accountNames)
                }
                if !archived.isEmpty {
                    DisclosureGroup("Archivadas (\(archived.count))") {
                        ForEach(archived) { summary in
                            settingsRow(summary, accountNames: accountNames)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .sheet(item: $selected) { record in
            ManualPromotionDetailSheet(recordID: record.id)
        }
        .sheet(isPresented: $showingEditor) {
            PromotionEditorSheet(existing: nil, anchorAccountID: nil)
        }
        .task { model.reload(context: modelContext) }
        .onReceive(NotificationCenter.default.publisher(for: PromotionLedgerStore.didChangeNotification)) { _ in
            model.reload(context: modelContext)
        }
    }

    /// PA-09: las adjudicaciones de promos eliminadas son huérfanas VISIBLES
    /// (no cuentan) y tienen camino de retiro.
    @ViewBuilder
    private var orphanedAttributionsSection: some View {
        let livePromotionIDs = Set(model.ledger.promotions.filter { $0.deletedAt == nil }.map(\.id))
        let orphans = model.ledger.attributions.filter {
            $0.deletedAt == nil && !livePromotionIDs.contains($0.promotionID)
        }
        if !orphans.isEmpty {
            DisclosureGroup("Adjudicaciones huérfanas (\(orphans.count))") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Pertenecen a promociones eliminadas; no cuentan en ningún avance.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ForEach(orphans) { orphan in
                        HStack {
                            Text("→ promo \(orphan.promotionID.uuidString.prefix(8)) · tx \(orphan.transactionID.uuidString.prefix(8))")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Retirar") {
                                try? PromotionLedgerStore.unattribute(transactionID: orphan.transactionID,
                                                                      promotionID: orphan.promotionID)
                            }
                            .font(.caption2)
                        }
                    }
                }
                .padding(.top, 4)
            }
            .font(.caption)
            .foregroundStyle(.orange)
        }
    }

    private func settingsRow(_ summary: ManualPromotionSummary, accountNames: [UUID: String]) -> some View {
        let accountName = accountNames[summary.record.accountID]
        return Button { selected = summary.record } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(summary.record.archivedAt == nil ? Color.blue : Color.gray.opacity(0.5))
                    .frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.record.name).font(.callout)
                    Text(accountName ?? "Cuenta eliminada — re-ancla o archiva")
                        .font(.caption2)
                        .foregroundStyle(accountName == nil ? Color.orange : .secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(MoneyFormat.string(code: summary.record.currency, summary.progress.advance))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
