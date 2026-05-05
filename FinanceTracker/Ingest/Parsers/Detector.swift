import Foundation
import PDFKit

enum DetectedIssuer: String, Sendable {
    case openbankMexico = "Openbank Mexico"
    case amexMexico = "American Express Mexico"
    case banortePORti = "Banorte POR Ti"
    case mercadoPago = "Mercado Pago"
    case didiCuenta = "DiDi Cuenta"
    case skandia = "Skandia"
    case ciBanco = "CI Banco"
    case suburbia = "Suburbia"
    case unknown = "Unknown"
}

struct DetectionResult: Sendable {
    let issuer: DetectedIssuer
    let format: FileFormat
    let confidence: Double
    let suggestedAccountType: AccountType
}

struct Detector: Sendable {
    static func detect(data: Data, fileExtension: String?) -> DetectionResult {
        let ext = fileExtension?.lowercased()
        let format: FileFormat = (ext == "csv") ? .csv : .pdf

        if format == .pdf {
            return detectPDF(data: data)
        }

        return detectCSV(data: data)
    }

    private static func detectPDF(data: Data) -> DetectionResult {
        guard let document = PDFDocument(data: data) else {
            return DetectionResult(
                issuer: .unknown,
                format: .pdf,
                confidence: 0,
                suggestedAccountType: .other
            )
        }

        let sampleText = extractSampleText(from: document)

        if sampleText.contains("Openbank") || sampleText.contains("OPENBANK MEXICO") || sampleText.contains("Cuenta Débito Open") {
            return DetectionResult(
                issuer: .openbankMexico,
                format: .pdf,
                confidence: 0.95,
                suggestedAccountType: .checking
            )
        }

        if sampleText.contains("American Express") || sampleText.contains("americanexpress.com.mx") {
            return DetectionResult(
                issuer: .amexMexico,
                format: .pdf,
                confidence: 0.95,
                suggestedAccountType: .creditCard
            )
        }

        if sampleText.contains("Banorte") || sampleText.contains("POR Ti") {
            return DetectionResult(
                issuer: .banortePORti,
                format: .pdf,
                confidence: 0.9,
                suggestedAccountType: .creditCard
            )
        }

        if sampleText.contains("Mercado Pago") || sampleText.contains("Mercadolibre") {
            return DetectionResult(
                issuer: .mercadoPago,
                format: .pdf,
                confidence: 0.9,
                suggestedAccountType: .wallet
            )
        }

        if sampleText.contains("DiDi Cuenta") || sampleText.contains("didicuenta") {
            return DetectionResult(
                issuer: .didiCuenta,
                format: .pdf,
                confidence: 0.9,
                suggestedAccountType: .savings
            )
        }

        if sampleText.contains("Skandia") || sampleText.contains("skandia.com.mx") {
            return DetectionResult(
                issuer: .skandia,
                format: .pdf,
                confidence: 0.9,
                suggestedAccountType: .retirement
            )
        }

        if sampleText.contains("CETES") || sampleText.contains("CI Banco") {
            return DetectionResult(
                issuer: .ciBanco,
                format: .pdf,
                confidence: 0.85,
                suggestedAccountType: .investment
            )
        }

        if sampleText.contains("Suburbia") || sampleText.contains("TARJETA SUBURBIA") {
            return DetectionResult(
                issuer: .suburbia,
                format: .pdf,
                confidence: 0.9,
                suggestedAccountType: .creditCard
            )
        }

        return DetectionResult(
            issuer: .unknown,
            format: .pdf,
            confidence: 0,
            suggestedAccountType: .other
        )
    }

    private static func detectCSV(data: Data) -> DetectionResult {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return DetectionResult(issuer: .unknown, format: .csv, confidence: 0, suggestedAccountType: .other)
        }

        return DetectionResult(issuer: .unknown, format: .csv, confidence: 0, suggestedAccountType: .other)
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
