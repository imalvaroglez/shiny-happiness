import Foundation

/// Formato declarativo de una promoción (spec: docs/specs/2026-09-22-promotion-tracking-brainstorm.md, secciones C/H).
/// Es configuración, no estado: borrarla no pierde datos del usuario. Todo dinero es Decimal.
struct PromotionDefinition: Equatable, Decodable {
    let id: String
    let displayName: String
    /// UUID obligatorio para evaluar; nil ⇒ desvinculada / no calculable (clase ①).
    let accountUUID: UUID?
    /// Solo ayuda de autoría del JSON — nunca vincula en runtime (spec v4-h).
    let authoringNickname: String?
    let window: PromotionWindow
    let shape: PromotionShape
    let scope: PromotionScope
    let refundPolicy: RefundPolicy
    let msiPolicy: MsiPolicy
    let reward: RewardSpec
    let knownUnknowns: [String]

    // MARK: - Ventana (fechas literales yyyy-MM-dd resueltas al autorar, con procedencia)

    enum PromotionWindow: Equatable, Decodable {
        case fixed(start: String, end: String, provenance: String)
        case anchored(start: String, durationDays: Int, provenance: String)
        case unknown(note: String?)
    }

    // MARK: - Forma matemática (3 cerradas; una 4ª exige código deliberado — spec D)

    enum PromotionShape: Equatable, Decodable {
        case spendThreshold(target: Decimal, reward: Decimal)
        case cashbackCap(ratePercent: Decimal, cap: Decimal)
        case tieredPeriods(periods: [PromotionPeriod], threshold: Decimal, reward: Decimal,
                           annualCap: Decimal, capScope: RewardCapScope)
    }
}

struct PromotionPeriod: Equatable, Decodable {
    let start: String
    let end: String
}

/// Ámbito del tope anual (spec J.4: T&C ambiguos; default conservador = vigencia total).
enum RewardCapScope: String, Equatable, Decodable {
    case promoLifetime
    case calendarYear
}

// MARK: - Alcance y políticas

struct PromotionScope: Equatable, Decodable {
    let currency: String
    /// Whitelist con alias; vacía = todo comercio (bonos de bienvenida).
    let merchants: [MerchantEntry]
    let requireChannel: ChannelRestriction
    let excludeFees: Bool
    /// Excluir terceros/agregadores (cashbacks); los bonos de bienvenida cuentan todo gasto.
    let excludeThirdParties: Bool
}

struct MerchantEntry: Equatable, Decodable {
    /// Identificador explícito de comercio (avisos preventivos de solapamiento sin comparar regex — spec H).
    let id: String
    let patterns: [String]
    /// Canal declarado por entrada; nil = por revisar (default incierto, nunca "ambos" por intuición — spec G.3).
    let channel: MerchantChannel?
}

enum ChannelRestriction: String, Equatable, Decodable {
    case any
    case physicalOnly
}

enum MerchantChannel: String, Equatable, Decodable {
    case any
    case physical
    case online
    case aggregator
}

struct RefundPolicy: Equatable, Decodable {
    enum Kind: String, Equatable, Decodable { case subtract, ignore }
    let kind: Kind
}

struct MsiPolicy: Equatable, Decodable {
    enum Kind: String, Equatable, Decodable { case countPostedInstallments, excludeAll, uncertain }
    let kind: Kind
    /// Descriptores de reversión (créditos positivos) para la conciliación — solo sugerencia; el signo decide la función.
    let reversalPatterns: [String]
    /// Cargos nacionales ≥ umbral se señalan como riesgo de conversión sin descontar del firme.
    let conversionRiskThreshold: Decimal?
}

struct RewardSpec: Equatable, Decodable {
    let expectedAmount: Decimal
    /// Patrón de descriptor de créditos candidatos a recibo (solo listado, sin asignación — spec G).
    let descriptorPatterns: [String]
}

// MARK: - Tabla de canal compartida (un archivo, referenciada por todas las promos — spec H)

struct ChannelTable: Equatable {
    struct Entry: Equatable, Decodable {
        /// Descriptor regex (agregadores/terceros) — exclusivo con merchantID.
        let pattern: String?
        /// Canal declarado para un comercio de alguna whitelist.
        let merchantID: String?
        let channel: MerchantChannel
    }

    let entries: [Entry]

    static func decode(_ data: Data) throws -> ChannelTable {
        struct Envelope: Decodable { let channels: [Entry] }
        return ChannelTable(entries: try JSONDecoder().decode(Envelope.self, from: data).channels)
    }
}

// MARK: - Decoding (inits en extensions para conservar el memberwise sintetizado)

extension PromotionDefinition.PromotionWindow {
    private enum CodingKeys: String, CodingKey { case kind, start, end, durationDays, provenance, note }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "fixed":
            self = .fixed(start: try c.decode(String.self, forKey: .start),
                          end: try c.decode(String.self, forKey: .end),
                          provenance: try c.decode(String.self, forKey: .provenance))
        case "anchored":
            self = .anchored(start: try c.decode(String.self, forKey: .start),
                             durationDays: try c.decode(Int.self, forKey: .durationDays),
                             provenance: try c.decode(String.self, forKey: .provenance))
        case "unknown":
            self = .unknown(note: try c.decodeIfPresent(String.self, forKey: .note))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c,
                debugDescription: "Ventana desconocida: \(other)")
        }
    }
}

extension PromotionDefinition.PromotionShape {
    private enum CodingKeys: String, CodingKey {
        case kind, target, rewardAmount, ratePercent, cap, periods, threshold, annualRewardCap, capScope
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "spendThreshold":
            self = .spendThreshold(target: try c.decode(Decimal.self, forKey: .target),
                                   reward: try c.decode(Decimal.self, forKey: .rewardAmount))
        case "cashbackCap":
            self = .cashbackCap(ratePercent: try c.decode(Decimal.self, forKey: .ratePercent),
                                cap: try c.decode(Decimal.self, forKey: .cap))
        case "tieredPeriods":
            self = .tieredPeriods(
                periods: try c.decode([PromotionPeriod].self, forKey: .periods),
                threshold: try c.decode(Decimal.self, forKey: .threshold),
                reward: try c.decode(Decimal.self, forKey: .rewardAmount),
                annualCap: try c.decode(Decimal.self, forKey: .annualRewardCap),
                capScope: try c.decodeIfPresent(RewardCapScope.self, forKey: .capScope) ?? .promoLifetime)
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c,
                debugDescription: "Forma desconocida: \(other)")
        }
    }
}

extension PromotionScope {
    private enum CodingKeys: String, CodingKey {
        case currency, merchants, requireChannel, excludeFees, excludeThirdParties
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        currency = try c.decodeIfPresent(String.self, forKey: .currency) ?? "MXN"
        merchants = try c.decodeIfPresent([MerchantEntry].self, forKey: .merchants) ?? []
        requireChannel = try c.decodeIfPresent(ChannelRestriction.self, forKey: .requireChannel) ?? .any
        excludeFees = try c.decodeIfPresent(Bool.self, forKey: .excludeFees) ?? true
        excludeThirdParties = try c.decodeIfPresent(Bool.self, forKey: .excludeThirdParties) ?? false
    }
}

extension RefundPolicy {
    private enum CodingKeys: String, CodingKey { case kind }

    init(from decoder: Decoder) throws {
        kind = try decoder.container(keyedBy: CodingKeys.self).decode(Kind.self, forKey: .kind)
    }
}

extension MsiPolicy {
    private enum CodingKeys: String, CodingKey { case kind, reversalPatterns, conversionRiskThreshold }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        reversalPatterns = try c.decodeIfPresent([String].self, forKey: .reversalPatterns) ?? []
        conversionRiskThreshold = try c.decodeIfPresent(Decimal.self, forKey: .conversionRiskThreshold)
    }
}

extension PromotionDefinition {
    private enum CodingKeys: String, CodingKey {
        case id, displayName, accountUUID, authoringNickname, window, shape, scope
        case refundPolicy, msiPolicy, reward, knownUnknowns
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let uuidString = try c.decodeIfPresent(String.self, forKey: .accountUUID)
        let accountUUID: UUID?
        if let s = uuidString, !s.isEmpty {
            guard let uuid = UUID(uuidString: s) else {
                throw DecodingError.dataCorruptedError(forKey: .accountUUID, in: c,
                    debugDescription: "accountUUID inválido (no es nil ni UUID)")
            }
            accountUUID = uuid
        } else {
            accountUUID = nil  // desvinculada / no calculable (clase ①)
        }
        let id = try c.decode(String.self, forKey: .id)
        let displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? id
        let scope = try c.decodeIfPresent(PromotionScope.self, forKey: .scope)
            ?? PromotionScope(currency: "MXN", merchants: [], requireChannel: .any, excludeFees: true,
                              excludeThirdParties: false)
        let refundPolicy = try c.decodeIfPresent(RefundPolicy.self, forKey: .refundPolicy)
            ?? RefundPolicy(kind: .subtract)
        let msiPolicy = try c.decodeIfPresent(MsiPolicy.self, forKey: .msiPolicy)
            ?? MsiPolicy(kind: .uncertain, reversalPatterns: [], conversionRiskThreshold: nil)
        let reward = try c.decodeIfPresent(RewardSpec.self, forKey: .reward)
            ?? RewardSpec(expectedAmount: 0, descriptorPatterns: [])
        let knownUnknowns = try c.decodeIfPresent([String].self, forKey: .knownUnknowns) ?? []
        self.init(id: id, displayName: displayName, accountUUID: accountUUID,
                  authoringNickname: try c.decodeIfPresent(String.self, forKey: .authoringNickname),
                  window: try c.decode(PromotionWindow.self, forKey: .window),
                  shape: try c.decode(PromotionShape.self, forKey: .shape),
                  scope: scope, refundPolicy: refundPolicy, msiPolicy: msiPolicy, reward: reward,
                  knownUnknowns: knownUnknowns)
    }
}

extension ChannelTable.Entry {
    private enum CodingKeys: String, CodingKey { case pattern, merchantID, channel }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pattern = try c.decodeIfPresent(String.self, forKey: .pattern)
        merchantID = try c.decodeIfPresent(String.self, forKey: .merchantID)
        channel = try c.decode(MerchantChannel.self, forKey: .channel)
    }
}
