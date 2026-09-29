import SwiftUI

struct PromotionHealthSection: View {
    let accounts: [Account]
    let catalog: PromotionCatalog?
    let onEdit: (PromotionDefinition, Bool) -> Void
    let onCatalogChanged: () -> Void

    @State private var deletingDefinition: PromotionDefinition?
    @State private var status = ""

    var body: some View {
        SectionCard(title: "Promotions") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Administra las promociones por tarjeta. Los resultados del Dashboard se calculan con los movimientos disponibles.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Agregar promoción", systemImage: "plus") {
                        onEdit(Self.newDefinition(), true)
                    }
                    .buttonStyle(.borderedProminent)
                }

                if let catalog {
                    if !catalog.warnings.isEmpty {
                        ForEach(catalog.warnings, id: \.message) { warning in
                            Label(warning.message, systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }

                    if catalog.definitions.isEmpty {
                        ContentUnavailableView("No hay promociones", systemImage: "tag",
                                               description: Text("Agrega una promoción para darle seguimiento en el Dashboard."))
                    } else {
                        ForEach(promotionGroups(catalog)) { group in
                            Text(group.accountName)
                                .font(.subheadline.weight(.semibold))
                                .padding(.top, 5)
                            ForEach(group.definitions, id: \.id) { definition in
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(definition.displayName).font(.body.weight(.medium))
                                        Text(phaseLabel(for: definition))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("Editar") { onEdit(definition, false) }
                                    Button("Eliminar", role: .destructive) { deletingDefinition = definition }
                                }
                                .padding(.vertical, 5)
                                if definition.id != group.definitions.last?.id { Divider() }
                            }
                        }
                    }
                } else {
                    ProgressView("Cargando promociones…")
                        .frame(maxWidth: .infinity, minHeight: 100)
                }
                if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(16)
        }
        .confirmationDialog("¿Eliminar promoción?", isPresented: Binding(
            get: { deletingDefinition != nil }, set: { if !$0 { deletingDefinition = nil } }
        )) {
            Button("Eliminar promoción", role: .destructive) { deletePromotion() }
            Button("Cancelar", role: .cancel) { deletingDefinition = nil }
        } message: {
            Text("Se eliminará de la administración y del resumen. Los movimientos y abonos no cambian.")
        }
    }

    private func promotionGroups(_ catalog: PromotionCatalog) -> [PromotionAccountGroup] {
        Dictionary(grouping: catalog.definitions, by: { $0.accountUUID?.uuidString ?? "unlinked" })
            .map { key, definitions in
                PromotionAccountGroup(
                    key: key,
                    accountName: accountName(for: definitions[0]),
                    definitions: definitions.sorted {
                        let left = campaignRank($0)
                        let right = campaignRank($1)
                        if left != right { return left < right }
                        return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                    }
                )
            }
            .sorted { $0.accountName.localizedStandardCompare($1.accountName) == .orderedAscending }
    }

    private func campaignRank(_ definition: PromotionDefinition) -> Int {
        switch PromotionDate.phase(definition.window) {
        case .active: 0
        case .upcoming: 1
        case .finished: 2
        case .review: 3
        }
    }

    private func phaseLabel(for definition: PromotionDefinition) -> String {
        switch PromotionDate.phase(definition.window) {
        case .active: "Vigente"
        case .upcoming: "Próxima"
        case .finished: "Terminada"
        case .review: "Por revisar: vigencia desconocida"
        }
    }

    private func accountName(for definition: PromotionDefinition) -> String {
        guard let id = definition.accountUUID else { return "Sin cuenta vinculada" }
        return accounts.first { $0.id == id }?.displayName ?? "Cuenta inexistente"
    }

    private func deletePromotion() {
        guard let deletingDefinition else { return }
        do {
            try PromotionStore.delete(id: deletingDefinition.id)
            self.deletingDefinition = nil
            onCatalogChanged()
            status = "Promoción eliminada."
        } catch {
            status = "No se pudo eliminar la promoción: \(error.localizedDescription)"
            self.deletingDefinition = nil
        }
    }

    private static func newDefinition() -> PromotionDefinition {
        let start = Date.now
        let end = Calendar.mexicoCity.date(byAdding: .day, value: 30, to: start) ?? start
        return PromotionDefinition(
            id: "personal-\(UUID().uuidString)", displayName: "Nueva promoción",
            accountUUID: nil, authoringNickname: nil,
            window: .fixed(start: PromotionDate.string(start), end: PromotionDate.string(end), provenance: "Definida por el usuario"),
            shape: .spendThreshold(target: 5_000, reward: 500),
            scope: PromotionScope(currency: "MXN", merchants: [], requireChannel: .any,
                                  excludeFees: true, excludeThirdParties: false),
            refundPolicy: RefundPolicy(kind: .subtract),
            msiPolicy: MsiPolicy(kind: .uncertain, reversalPatterns: [], conversionRiskThreshold: nil),
            reward: RewardSpec(expectedAmount: 500, descriptorPatterns: []), knownUnknowns: []
        )
    }
}

private struct PromotionAccountGroup: Identifiable {
    let key: String
    let accountName: String
    let definitions: [PromotionDefinition]
    var id: String { key }
}

enum PromotionEditorShape: String, CaseIterable, Identifiable {
    case spendThreshold, cashbackCap, tieredPeriods
    var id: String { rawValue }
    var title: String {
        switch self {
        case .spendThreshold: "Meta de gasto"
        case .cashbackCap: "Reembolso con tope"
        case .tieredPeriods: "Metas por periodo"
        }
    }
}

private enum PromotionDate {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "America/Mexico_City")
        f.dateFormat = "yyyy-MM-dd"
        f.isLenient = false
        return f
    }()
    static func string(_ date: Date) -> String { formatter.string(from: date) }
    static func parse(_ value: String) -> Date? {
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else { return nil }
        return date
    }

    enum Phase { case upcoming, active, finished, review }

    static func phase(_ window: PromotionDefinition.PromotionWindow) -> Phase {
        let start: Date
        let endExclusive: Date
        switch window {
        case .fixed(let startText, let endText, _):
            guard let parsedStart = parse(startText), let parsedEnd = parse(endText),
                  let exclusive = Calendar.mexicoCity.date(byAdding: .day, value: 1, to: parsedEnd) else { return .review }
            start = parsedStart
            endExclusive = exclusive
        case .anchored(let startText, let days, _):
            guard days > 0, let parsedStart = parse(startText),
                  let exclusive = Calendar.mexicoCity.date(byAdding: .day, value: days, to: parsedStart) else { return .review }
            start = parsedStart
            endExclusive = exclusive
        case .unknown:
            return .review
        }
        let today = Calendar.mexicoCity.startOfDay(for: .now)
        if today < start { return .upcoming }
        return today < endExclusive ? .active : .finished
    }
}

private extension Calendar {
    static var mexicoCity: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Mexico_City")!
        return calendar
    }
}

struct PromotionEditorDraft {
    let id: String
    var name: String
    var accountID: UUID?
    var authoringNickname: String?
    var windowKind: String
    var startDate: Date
    var endDate: Date
    var durationDays: Int
    var provenance: String
    var shape: PromotionEditorShape
    var amount1: String
    var amount2: String
    var amount3: String
    var periods: String
    var currency: String
    var merchants: String
    var channel: String
    var excludeFees: Bool
    var excludeThirdParties: Bool
    var refundKind: String
    var msiKind: String
    var msiPatterns: String
    var conversionRisk: String
    var capScope: RewardCapScope
    var expectedReward: String
    var rewardPatterns: String
    var knownUnknowns: String

    init(_ definition: PromotionDefinition) {
        id = definition.id
        name = definition.displayName
        accountID = definition.accountUUID
        authoringNickname = definition.authoringNickname
        provenance = "Definida por el usuario"
        switch definition.window {
        case .fixed(let start, let end, let source):
            windowKind = "fixed"
            startDate = PromotionDate.parse(start) ?? .now
            endDate = PromotionDate.parse(end) ?? .now
            durationDays = 30
            provenance = source
        case .anchored(let start, let days, let source):
            windowKind = "anchored"
            startDate = PromotionDate.parse(start) ?? .now
            endDate = Calendar.mexicoCity.date(byAdding: .day, value: days, to: startDate) ?? startDate
            durationDays = days
            provenance = source
        case .unknown(let note):
            windowKind = "unknown"
            startDate = .now
            endDate = Calendar.mexicoCity.date(byAdding: .day, value: 30, to: .now) ?? .now
            durationDays = 30
            provenance = note ?? ""
        }
        switch definition.shape {
        case .spendThreshold(let target, let reward):
            shape = .spendThreshold
            amount1 = NSDecimalNumber(decimal: target).stringValue
            amount2 = NSDecimalNumber(decimal: reward).stringValue
            amount3 = "0"
            periods = ""
        case .cashbackCap(let rate, let cap):
            shape = .cashbackCap
            amount1 = NSDecimalNumber(decimal: rate).stringValue
            amount2 = NSDecimalNumber(decimal: cap).stringValue
            amount3 = "0"
            periods = ""
        case .tieredPeriods(let values, let threshold, let reward, let cap, _):
            shape = .tieredPeriods
            amount1 = NSDecimalNumber(decimal: threshold).stringValue
            amount2 = NSDecimalNumber(decimal: reward).stringValue
            amount3 = NSDecimalNumber(decimal: cap).stringValue
            periods = values.map { "\($0.start),\($0.end)" }.joined(separator: "\n")
        }
        if case .tieredPeriods(_, _, _, _, let existingScope) = definition.shape {
            capScope = existingScope
        } else {
            capScope = .promoLifetime
        }
        currency = definition.scope.currency
        merchants = definition.scope.merchants.map { merchant in
            "\(merchant.id)|\(merchant.patterns.joined(separator: ";"))|\(merchant.channel?.rawValue ?? "")"
        }.joined(separator: "\n")
        channel = definition.scope.requireChannel.rawValue
        excludeFees = definition.scope.excludeFees
        excludeThirdParties = definition.scope.excludeThirdParties
        refundKind = definition.refundPolicy.kind.rawValue
        msiKind = definition.msiPolicy.kind.rawValue
        msiPatterns = definition.msiPolicy.reversalPatterns.joined(separator: "\n")
        conversionRisk = definition.msiPolicy.conversionRiskThreshold.map { NSDecimalNumber(decimal: $0).stringValue } ?? ""
        expectedReward = NSDecimalNumber(decimal: definition.reward.expectedAmount).stringValue
        rewardPatterns = definition.reward.descriptorPatterns.joined(separator: "\n")
        knownUnknowns = definition.knownUnknowns.joined(separator: "\n")
    }

    func definition() throws -> PromotionDefinition {
        guard accountID != nil else { throw PromotionEditorError.accountRequired }
        func decimal(_ value: String) -> Decimal? { Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) }
        guard let amount1 = decimal(amount1), let amount2 = decimal(amount2),
              let amount3 = decimal(amount3), let expectedReward = decimal(expectedReward) else {
            throw PromotionEditorError.invalidAmount
        }
        let window: PromotionDefinition.PromotionWindow
        switch windowKind {
        case "fixed":
            window = .fixed(start: PromotionDate.string(startDate), end: PromotionDate.string(endDate), provenance: provenance)
        case "anchored":
            window = .anchored(start: PromotionDate.string(startDate), durationDays: durationDays, provenance: provenance)
        default:
            window = .unknown(note: provenance.isEmpty ? nil : provenance)
        }
        let shape: PromotionDefinition.PromotionShape
        switch self.shape {
        case .spendThreshold: shape = .spendThreshold(target: amount1, reward: amount2)
        case .cashbackCap: shape = .cashbackCap(ratePercent: amount1, cap: amount2)
        case .tieredPeriods:
            let parsedPeriods = try periods.split(whereSeparator: \.isNewline).map { row -> PromotionPeriod in
                let parts = row.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 2, PromotionDate.parse(parts[0]) != nil, PromotionDate.parse(parts[1]) != nil else {
                    throw PromotionEditorError.invalidPeriods
                }
                return PromotionPeriod(start: parts[0], end: parts[1])
            }
            shape = .tieredPeriods(periods: parsedPeriods, threshold: amount1, reward: amount2,
                                   annualCap: amount3, capScope: capScope)
        }
        let entries = try merchants.split(whereSeparator: \.isNewline).map { row -> MerchantEntry in
            let parts = row.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3 else { throw PromotionEditorError.invalidMerchants }
            let channel = parts[2].isEmpty ? nil : MerchantChannel(rawValue: parts[2])
            guard parts[2].isEmpty || channel != nil else { throw PromotionEditorError.invalidMerchants }
            return MerchantEntry(id: parts[0], patterns: parts[1].split(separator: ";").map(String.init), channel: channel)
        }
        guard let restriction = ChannelRestriction(rawValue: channel),
              let refund = RefundPolicy.Kind(rawValue: refundKind), let msi = MsiPolicy.Kind(rawValue: msiKind) else {
            throw PromotionEditorError.invalidConditions
        }
        let risk = conversionRisk.isEmpty ? nil : decimal(conversionRisk)
        if !conversionRisk.isEmpty && risk == nil { throw PromotionEditorError.invalidAmount }
        return PromotionDefinition(
            id: id, displayName: name.trimmingCharacters(in: .whitespacesAndNewlines),
            accountUUID: accountID, authoringNickname: authoringNickname, window: window, shape: shape,
            scope: PromotionScope(currency: currency.trimmingCharacters(in: .whitespacesAndNewlines),
                                  merchants: entries, requireChannel: restriction,
                                  excludeFees: excludeFees, excludeThirdParties: excludeThirdParties),
            refundPolicy: RefundPolicy(kind: refund),
            msiPolicy: MsiPolicy(kind: msi, reversalPatterns: msiPatterns.split(whereSeparator: \.isNewline).map(String.init),
                                 conversionRiskThreshold: risk),
            reward: RewardSpec(expectedAmount: expectedReward,
                               descriptorPatterns: rewardPatterns.split(whereSeparator: \.isNewline).map(String.init)),
            knownUnknowns: knownUnknowns.split(whereSeparator: \.isNewline).map(String.init)
        )
    }
}

enum PromotionEditorError: LocalizedError, Equatable {
    case invalidAmount, invalidPeriods, invalidMerchants, invalidConditions, accountRequired
    var errorDescription: String? {
        switch self {
        case .invalidAmount: "Revisa los importes y porcentajes."
        case .invalidPeriods: "Usa una fecha válida por renglón con el formato AAAA-MM-DD,AAAA-MM-DD."
        case .invalidMerchants: "Usa un comercio por renglón: id|expresión regular;otra expresión|canal."
        case .invalidConditions: "Hay una condición de reembolso, MSI o canal inválida."
        case .accountRequired: "Selecciona una cuenta para vincular la promoción."
        }
    }
}

struct PromotionEditorSheet: View {
    let accounts: [Account]
    let isNew: Bool
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: PromotionEditorDraft
    @State private var errorMessage = ""

    init(definition: PromotionDefinition, accounts: [Account], isNew: Bool, onSave: @escaping () -> Void) {
        self.accounts = accounts
        self.isNew = isNew
        self.onSave = onSave
        _draft = State(initialValue: PromotionEditorDraft(definition))
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(isNew ? "Agregar promoción" : "Editar promoción").font(.headline).padding()
            Form {
                Section("Datos generales") {
                    TextField("Nombre de la promoción", text: $draft.name)
                    Picker("Cuenta", selection: $draft.accountID) {
                        Text("Selecciona una cuenta").tag(nil as UUID?)
                        ForEach(accounts.filter { $0.type == .creditCard }.sorted {
                            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                        }, id: \.id) { Text($0.displayName).tag($0.id as UUID?) }
                    }
                    if draft.accountID == nil {
                        Text("Selecciona la tarjeta a la que pertenece esta promoción.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Picker("Vigencia", selection: $draft.windowKind) {
                        Text("Fechas fijas").tag("fixed")
                        Text("Duración desde una fecha").tag("anchored")
                        Text("Desconocida").tag("unknown")
                    }
                    if draft.windowKind != "unknown" {
                        DatePicker("Inicio", selection: $draft.startDate, displayedComponents: .date)
                        if draft.windowKind == "fixed" {
                            DatePicker("Fin", selection: $draft.endDate, displayedComponents: .date)
                        } else {
                            Stepper("Duración: \(draft.durationDays) días", value: $draft.durationDays, in: 1...730)
                        }
                    }
                    if draft.windowKind != "unknown" {
                        TextField("Procedencia de las fechas", text: $draft.provenance)
                    }
                }
                Section("Objetivo y recompensa") {
                    Picker("Tipo de promoción", selection: $draft.shape) {
                        ForEach(PromotionEditorShape.allCases) { Text($0.title).tag($0) }
                    }
                    if draft.shape == .cashbackCap {
                        TextField("Porcentaje de reembolso", text: $draft.amount1)
                        TextField("Tope de reembolso", text: $draft.amount2)
                    } else {
                        TextField(draft.shape == .tieredPeriods ? "Meta por periodo" : "Meta de gasto", text: $draft.amount1)
                        TextField("Recompensa por meta", text: $draft.amount2)
                    }
                    if draft.shape == .tieredPeriods {
                        TextField("Tope acumulado", text: $draft.amount3)
                        Picker("Periodo del tope", selection: $draft.capScope) {
                            Text("Vigencia completa").tag(RewardCapScope.promoLifetime)
                            Text("Año calendario CDMX").tag(RewardCapScope.calendarYear)
                        }
                        Text("Un periodo por renglón: AAAA-MM-DD,AAAA-MM-DD").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $draft.periods).frame(minHeight: 75)
                    }
                    TextField("Moneda", text: $draft.currency)
                    TextField("Recompensa esperada", text: $draft.expectedReward)
                }
                Section("Comercios y canal") {
                    Text("Un comercio por renglón: id|regex;regex|canal opcional (physical, online, aggregator, any).")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $draft.merchants).frame(minHeight: 85)
                    Picker("Canal requerido", selection: $draft.channel) {
                        Text("Cualquiera").tag("any")
                        Text("Solo presencial").tag("physicalOnly")
                    }
                    Toggle("Excluir comisiones", isOn: $draft.excludeFees)
                    Toggle("Excluir agregadores", isOn: $draft.excludeThirdParties)
                }
                DisclosureGroup("Condiciones avanzadas") {
                    Picker("Reembolsos", selection: $draft.refundKind) {
                        Text("Restan del gasto").tag("subtract")
                        Text("Se ignoran").tag("ignore")
                    }
                    Picker("Compras a meses", selection: $draft.msiKind) {
                        Text("Contar mensualidades publicadas").tag("countPostedInstallments")
                        Text("Excluir todo el cargo").tag("excludeAll")
                        Text("Por revisar").tag("uncertain")
                    }
                    TextField("Umbral de riesgo MSI (opcional)", text: $draft.conversionRisk)
                    Text("Patrones de reversión MSI, uno por renglón").font(.caption)
                    TextEditor(text: $draft.msiPatterns).frame(minHeight: 50)
                    Text("Descriptores de abono de recompensa, uno por renglón").font(.caption)
                    TextEditor(text: $draft.rewardPatterns).frame(minHeight: 50)
                    Text("Supuestos y datos pendientes, uno por renglón").font(.caption)
                    TextEditor(text: $draft.knownUnknowns).frame(minHeight: 50)
                }
                if !errorMessage.isEmpty {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            HStack {
                Button("Cancelar") { dismiss() }
                Spacer()
                Button("Guardar") { save() }.buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(minWidth: 620, minHeight: 650)
    }

    private func save() {
        do {
            try PromotionStore.save(draft.definition())
            onSave()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview("Promotions management") {
    PromotionHealthSection(accounts: [], catalog: PromotionCatalog.load(), onEdit: { _, _ in }, onCatalogChanged: {})
}
