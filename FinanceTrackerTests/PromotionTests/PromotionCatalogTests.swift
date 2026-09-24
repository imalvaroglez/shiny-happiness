import Testing
import Foundation
@testable import FinanceTracker

/// Ciclo 1 (TDD): decode del catálogo de promociones — fail-soft por entrada,
/// ventana desconocida, tabla de canal. Fuente: docs/specs/2026-09-22-promotion-tracking-brainstorm.md (C/H/K).
@Suite("Promotion Catalog")
struct PromotionCatalogTests {

    private func catalogJSON(_ promotions: String) -> Data {
        Data("{\"promotions\": [\(promotions)]}".utf8)
    }

    private let validThreshold = """
    {
      "id": "amex-platinum-bienvenida-2026",
      "displayName": "Bono de bienvenida Platinum",
      "accountUUID": "98635015-070A-4EB5-9050-3268FB4B49FA",
      "authoringNickname": "The Platinum Credit Card",
      "window": { "kind": "anchored", "start": "2026-09-09", "durationDays": 90,
                  "provenance": "aprobación=activación (usuario); verificación T&C residual" },
      "shape": { "kind": "spendThreshold", "target": 100000, "rewardAmount": 15000 },
      "scope": { "currency": "MXN", "merchants": [], "requireChannel": "any", "excludeFees": true },
      "refundPolicy": { "kind": "subtract" },
      "msiPolicy": { "kind": "countPostedInstallments",
                     "reversalPatterns": ["(?i)MONTO A DIFERIR"],
                     "conversionRiskThreshold": 6000 },
      "reward": { "expectedAmount": 15000, "descriptorPatterns": ["(?i)BONIFICACI"] },
      "knownUnknowns": ["titular vs adicional — se asume titular único"]
    }
    """

    @Test("Decodifica una definición válida de umbral en ventana")
    func decodesValidThresholdDefinition() throws {
        let catalog = PromotionCatalog.decode(catalogJSON(validThreshold))
        #expect(catalog.warnings.isEmpty)
        #expect(catalog.definitions.count == 1)
        let promo = try #require(catalog.definitions.first)
        #expect(promo.id == "amex-platinum-bienvenida-2026")
        #expect(promo.accountUUID == UUID(uuidString: "98635015-070A-4EB5-9050-3268FB4B49FA"))
        #expect(promo.authoringNickname == "The Platinum Credit Card")
        #expect(promo.knownUnknowns.count == 1)

        guard case .anchored(let start, let days, let provenance) = promo.window else {
            Issue.record("Se esperaba ventana anclada, fue \(promo.window)"); return
        }
        #expect(start == "2026-09-09")
        #expect(days == 90)
        #expect(provenance.contains("activación"))

        guard case .spendThreshold(let target, let reward) = promo.shape else {
            Issue.record("Se esperaba spendThreshold, fue \(promo.shape)"); return
        }
        #expect(target == 100_000)
        #expect(reward == 15_000)
    }

    @Test("Entrada rota NO tumba el catálogo: fail-soft con warning")
    func brokenEntryFailsSoftWithWarning() throws {
        let broken = "{ \"id\": \"rota\", \"shape\": { \"kind\": \"inexistente\" } }"
        let catalog = PromotionCatalog.decode(catalogJSON(broken + ", " + validThreshold))
        #expect(catalog.definitions.count == 1, "La entrada válida debe cargar")
        #expect(catalog.warnings.count == 1, "La entrada rota debe producir exactamente un warning")
        #expect(catalog.warnings.first?.kind == .decodeFailed)
    }

    @Test("Una entrada con ID mal tipado no oculta las promociones válidas")
    func malformedIDIsolated() throws {
        let malformed = validThreshold.replacingOccurrences(of: "\"id\": \"amex-platinum-bienvenida-2026\"",
                                                            with: "\"id\": 42")
        let catalog = PromotionCatalog.decode(catalogJSON(malformed + ", " + validThreshold))
        #expect(catalog.definitions.map(\.id) == ["amex-platinum-bienvenida-2026"])
        #expect(catalog.warnings.count == 1)
    }

    @Test("Patrón de canal inválido hace que la tabla no esté disponible")
    func invalidChannelTableIsRejected() {
        let data = Data("{\"channels\":[{\"pattern\":\"[\",\"channel\":\"aggregator\"}]}".utf8)
        #expect(PromotionCatalog.decodeChannelTable(data) == nil)
        #expect(PromotionCatalog.decodeChannelTable(Data("{\"channels\":[]}".utf8)) == nil)
    }

    @Test("Periodo calendarYear que cruza año civil se rechaza")
    func calendarYearPeriodMustStayWithinYear() {
        let data = Data("""
        {"promotions":[{
          "id":"calendar-year","accountUUID":null,
          "window":{"kind":"fixed","start":"2026-12-01","end":"2027-02-28","provenance":"test"},
          "shape":{"kind":"tieredPeriods","periods":[{"start":"2026-12-31","end":"2027-01-01"}],
                   "threshold":100,"rewardAmount":10,"annualRewardCap":100,"capScope":"calendarYear"},
          "scope":{"currency":"MXN"},"knownUnknowns":[]
        }]}
        """.utf8)
        let catalog = PromotionCatalog.decode(data)
        #expect(catalog.definitions.isEmpty)
        #expect(catalog.warnings.first?.message.contains("cruza años") == true)
    }

    @Test("Ventana desconocida decodifica como unknown (caso B)")
    func unknownWindowDecodes() throws {
        let unknownWindow = """
        {
          "id": "amex-gold-bienvenida", "displayName": "Bono Gold",
          "accountUUID": null,
          "window": { "kind": "unknown", "note": "T&C pendiente" },
          "shape": { "kind": "spendThreshold", "target": 100000, "rewardAmount": 10000 },
          "scope": { "currency": "MXN", "merchants": [], "requireChannel": "any", "excludeFees": true },
          "refundPolicy": { "kind": "subtract" },
          "msiPolicy": { "kind": "countPostedInstallments", "reversalPatterns": [], "conversionRiskThreshold": 6000 },
          "reward": { "expectedAmount": 10000, "descriptorPatterns": ["(?i)BONIFICACI"] },
          "knownUnknowns": ["ventana desconocida", "exclusiones detalladas desconocidas"]
        }
        """
        let catalog = PromotionCatalog.decode(catalogJSON(unknownWindow))
        #expect(catalog.warnings.isEmpty)
        let promo = try #require(catalog.definitions.first)
        guard case .unknown = promo.window else {
            Issue.record("Se esperaba ventana unknown, fue \(promo.window)"); return
        }
        #expect(promo.accountUUID == nil, "Sin UUID la promo queda desvinculada (evaluador decide no calculable)")
    }

    @Test("Forma de periodos escalonados decodifica con periodos literales y tope anual")
    func decodesTieredPeriods() throws {
        let tiered = """
        {
          "id": "gold-everyday-value", "displayName": "Everyday Value",
          "accountUUID": null,
          "window": { "kind": "fixed", "start": "2026-09-22", "end": "2027-12-31", "provenance": "T&C" },
          "shape": { "kind": "tieredPeriods",
                     "periods": [ {"start": "2026-09-22", "end": "2026-09-30"},
                                  {"start": "2026-10-01", "end": "2026-12-31"} ],
                     "threshold": 5000, "rewardAmount": 1000,
                     "annualRewardCap": 4000, "capScope": "promoLifetime" },
          "scope": { "currency": "MXN",
                     "merchants": [ { "id": "fresko", "patterns": ["(?i)FRESKO"], "channel": "any" } ],
                     "requireChannel": "any", "excludeFees": true },
          "refundPolicy": { "kind": "subtract" },
          "msiPolicy": { "kind": "uncertain", "reversalPatterns": [], "conversionRiskThreshold": 6000 },
          "reward": { "expectedAmount": 1000, "descriptorPatterns": ["(?i)BONIFICACI"] },
          "knownUnknowns": ["canal por comercio sin confirmar"]
        }
        """
        let catalog = PromotionCatalog.decode(catalogJSON(tiered))
        #expect(catalog.warnings.isEmpty)
        let promo = try #require(catalog.definitions.first)
        guard case .tieredPeriods(let periods, let threshold, let reward, let cap, let capScope) = promo.shape else {
            Issue.record("Se esperaba tieredPeriods, fue \(promo.shape)"); return
        }
        #expect(periods.count == 2)
        #expect(periods[0].start == "2026-09-22")
        #expect(threshold == 5_000)
        #expect(reward == 1_000)
        #expect(cap == 4_000)
        #expect(capScope == .promoLifetime)
        guard let fresko = promo.scope.merchants.first else { return }
        #expect(fresko.id == "fresko")
        #expect(fresko.channel == .any)
    }

    @Test("Tabla de canal decodifica agregadores y canales")
    func decodesChannelTable() throws {
        let json = Data("""
        { "channels": [
            { "pattern": "(?i)UBER EATS", "channel": "aggregator" },
            { "merchantID": "fresko", "channel": "any" }
        ] }
        """.utf8)
        let table = try ChannelTable.decode(json)
        #expect(table.entries.count == 2)
        #expect(table.entries[0].channel == .aggregator)
        #expect(table.entries[1].merchantID == "fresko")
    }
}
