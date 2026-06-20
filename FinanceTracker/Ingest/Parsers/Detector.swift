import Foundation
import PDFKit

enum DetectedIssuer: String, Sendable {
    case openbankMexico = "Openbank Mexico"
    case amexMexico = "American Express Mexico"
    case banamexPriority = "Banamex Priority"
    case banamexExplora = "Banamex Explora"
    case banortePORti = "Banorte POR Ti"
    case mercadoPago = "Mercado Pago"
    case didiCuenta = "DiDi Cuenta"
    case skandia = "Skandia"
    case ciBanco = "CI Banco"
    case suburbia = "Suburbia"
    case hsbcMexico2Now = "HSBC 2Now"
    case unknown = "Unknown"
}

struct DetectionResult: Sendable {
    let issuer: DetectedIssuer
    let suggestedAccountType: AccountType
}

struct Detector: Sendable {
    static func detect(data: Data, fileExtension: String?) -> DetectionResult {
        guard fileExtension?.lowercased() != "csv" else {
            return DetectionResult(issuer: .unknown, suggestedAccountType: .other)
        }
        return detectPDF(data: data)
    }

    private static func detectPDF(data: Data) -> DetectionResult {
        guard let document = PDFDocument(data: data) else {
            return DetectionResult(issuer: .unknown, suggestedAccountType: .other)
        }

        let sampleText = extractSampleText(from: document)

        if sampleText.contains("Openbank") || sampleText.contains("OPENBANK MEXICO") || sampleText.contains("Cuenta Débito Open") {
            return DetectionResult(issuer: .openbankMexico, suggestedAccountType: .checking)
        }

        if sampleText.contains("American Express") || sampleText.contains("americanexpress.com.mx") {
            return DetectionResult(issuer: .amexMexico, suggestedAccountType: .creditCard)
        }

        if sampleText.localizedCaseInsensitiveContains("EXPLORA BANAMEX")
            || (sampleText.localizedCaseInsensitiveContains("Tarjeta de Crédito")
                && sampleText.localizedCaseInsensitiveContains("Banco Nacional de México")) {
            return DetectionResult(issuer: .banamexExplora, suggestedAccountType: .creditCard)
        }

        if sampleText.localizedCaseInsensitiveContains("Cuenta Priority")
            || (sampleText.localizedCaseInsensitiveContains("Cuenta de cheques")
                && sampleText.localizedCaseInsensitiveContains("Banco Nacional de México")) {
            return DetectionResult(issuer: .banamexPriority, suggestedAccountType: .checking)
        }

        if sampleText.contains("Banorte") || sampleText.contains("POR Ti") {
            return DetectionResult(issuer: .banortePORti, suggestedAccountType: .creditCard)
        }

        if sampleText.contains("Mercado Pago") || sampleText.contains("Mercadolibre") {
            return DetectionResult(issuer: .mercadoPago, suggestedAccountType: .wallet)
        }

        if sampleText.contains("DiDi Cuenta") || sampleText.contains("didicuenta") {
            return DetectionResult(issuer: .didiCuenta, suggestedAccountType: .savings)
        }

        if sampleText.contains("Skandia") || sampleText.contains("skandia.com.mx") {
            return DetectionResult(issuer: .skandia, suggestedAccountType: .retirement)
        }

        if sampleText.contains("CETES") || sampleText.contains("CI Banco") {
            return DetectionResult(issuer: .ciBanco, suggestedAccountType: .investment)
        }

        if sampleText.contains("Suburbia") || sampleText.contains("TARJETA SUBURBIA") {
            return DetectionResult(issuer: .suburbia, suggestedAccountType: .creditCard)
        }

        if let hsbc = matchHSBC2Now(in: sampleText) {
            return hsbc
        }

        return DetectionResult(issuer: .unknown, suggestedAccountType: .other)
    }

    /// Pasted-text detection: classify the issuer from raw text the user pastes from
    /// their bank portal. Used by the paste-import path; never invoked for PDF data.
    static func detectFromPastedText(_ text: String) -> DetectionResult {
        if let hsbc = matchHSBC2Now(in: text) {
            return hsbc
        }
        return DetectionResult(issuer: .unknown, suggestedAccountType: .other)
    }

    private static func matchHSBC2Now(in sampleText: String) -> DetectionResult? {
        let upper = sampleText.uppercased()
        let mentionsHSBC = upper.contains("HSBC")
        let mentions2Now = upper.contains("2NOW") || upper.contains("2 NOW")
        guard mentionsHSBC && mentions2Now else { return nil }
        return DetectionResult(issuer: .hsbcMexico2Now, suggestedAccountType: .creditCard)
    }

    private static func extractSampleText(from document: PDFDocument) -> String {
        var text = ""
        let pagesToCheck = min(2, document.pageCount)
        for i in 0..<pagesToCheck {
            if let page = document.page(at: i) {
                text += page.string ?? ""
            }
        }
        return text
    }
}
