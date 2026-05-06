import Foundation

struct MerchantExtractor {
    static func extractMerchant(from description: String) -> String? {
        var cleaned = description

        cleaned = stripRFC(from: cleaned)
        cleaned = stripRefPatterns(from: cleaned)
        cleaned = stripPunctuation(from: cleaned)

        let tokens = cleaned
            .split(separator: " ")
            .map(String.init)

        for token in tokens {
            let stripped = stripTrailingDigits(from: token)
            guard stripped.count >= 4 else { continue }
            guard stripped.allSatisfy({ $0.isLetter }) else { continue }
            return stripped.uppercased()
        }

        return nil
    }

    private static func stripRFC(from text: String) -> String {
        text.replacingOccurrences(
            of: "RFC[A-Z0-9]{12,13}",
            with: "",
            options: .regularExpression
        )
    }

    private static func stripRefPatterns(from text: String) -> String {
        text.replacingOccurrences(
            of: "/REF[A-Z0-9]+",
            with: "",
            options: .regularExpression
        )
    }

    private static func stripPunctuation(from text: String) -> String {
        text
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "/", with: " ")
    }

    private static func stripTrailingDigits(from token: String) -> String {
        var result = token
        while let last = result.last, last.isNumber {
            result.removeLast()
        }
        return result
    }
}
