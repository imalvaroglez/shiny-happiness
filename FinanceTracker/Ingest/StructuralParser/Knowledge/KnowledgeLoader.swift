import Foundation

enum ColumnRole: String, Codable, CaseIterable, Sendable {
    case date = "date_column"
    case description = "description_column"
    case amount = "amount_column"
    case debit = "debit_column"
    case credit = "credit_column"
    case balance = "balance_column"
}

struct HeaderVocabulary: Sendable {
    let dateKeywords: [String]
    let descriptionKeywords: [String]
    let amountKeywords: [String]
    let debitKeywords: [String]
    let creditKeywords: [String]
    let balanceKeywords: [String]
    let combinedHeaders: [String: [String]]
    let sectionStartMarkers: [String]
    let sectionEndMarkers: [String]

    static func load() -> HeaderVocabulary? {
        guard let url = Bundle.main.url(
            forResource: "header_vocabulary",
            withExtension: "json",
            subdirectory: "FinanceTracker/Ingest/StructuralParser/Knowledge"
        ) else { return nil }

        do {
            let data = try Data(contentsOf: url)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            return HeaderVocabulary(from: json)
        } catch {
            return nil
        }
    }

    func roleForKeyword(_ keyword: String) -> ColumnRole? {
        if dateKeywords.contains(where: { keyword.localizedCaseInsensitiveContains($0) }) { return .date }
        if descriptionKeywords.contains(where: { keyword.localizedCaseInsensitiveContains($0) }) { return .description }
        if debitKeywords.contains(where: { keyword.localizedCaseInsensitiveContains($0) }) { return .debit }
        if creditKeywords.contains(where: { keyword.localizedCaseInsensitiveContains($0) }) { return .credit }
        if balanceKeywords.contains(where: { keyword.localizedCaseInsensitiveContains($0) }) { return .balance }
        if amountKeywords.contains(where: { keyword.localizedCaseInsensitiveContains($0) }) { return .amount }
        return nil
    }

    func isSectionStart(_ text: String) -> Bool {
        sectionStartMarkers.contains { text.localizedCaseInsensitiveContains($0) }
    }

    func isSectionEnd(_ text: String) -> Bool {
        sectionEndMarkers.contains { text.localizedCaseInsensitiveContains($0) }
    }

    init(from json: [String: Any]) {
        func strings(_ key: String) -> [String] { json[key] as? [String] ?? [] }
        func stringDict(_ key: String) -> [String: [String]] {
            (json[key] as? [String: Any] ?? [:]).mapValues { $0 as? [String] ?? [] }
        }

        self.dateKeywords = strings("date_column")
        self.descriptionKeywords = strings("description_column")
        self.amountKeywords = strings("amount_column")
        self.debitKeywords = strings("debit_column")
        self.creditKeywords = strings("credit_column")
        self.balanceKeywords = strings("balance_column")
        self.combinedHeaders = stringDict("combined_headers")
        self.sectionStartMarkers = strings("section_start_markers")
        self.sectionEndMarkers = strings("section_end_markers")
    }
}

struct DatePatterns: Sendable {
    struct Pattern: Codable, Sendable {
        let id: String
        let regex: String
        let fields: [String]
        let month_map: String?
        let year_source: String?
        let year_padding: Int?
        let continuation: Bool?
        let continuation_pattern: String?
        let continuation_fields: [String]?
        let sourced_from: String?
    }

    struct PeriodPattern: Codable, Sendable {
        let id: String
        let regex: String
        let fields: [String]
        let month_map: String?
        let sourced_from: String?
    }

    let patterns: [Pattern]
    let periodPatterns: [PeriodPattern]
    let monthMaps: [String: [String: Int]]

    static func load() -> DatePatterns? {
        guard let url = Bundle.main.url(
            forResource: "date_patterns",
            withExtension: "json",
            subdirectory: "FinanceTracker/Ingest/StructuralParser/Knowledge"
        ) else { return nil }

        do {
            let data = try Data(contentsOf: url)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

            let patternData = try JSONSerialization.data(withJSONObject: json["patterns"] ?? [])
            let patterns = try JSONDecoder().decode([Pattern].self, from: patternData)

            let periodData = try JSONSerialization.data(withJSONObject: json["statement_period_patterns"] ?? [])
            let periodPatterns = try JSONDecoder().decode([PeriodPattern].self, from: periodData)

            var monthMaps: [String: [String: Int]] = [:]
            if let rawMaps = json["month_maps"] as? [String: Any] {
                for (name, value) in rawMaps {
                    guard let stringMap = value as? [String: String] else { continue }
                    var intMap: [String: Int] = [:]
                    for (month, val) in stringMap {
                        intMap[month] = Int(val)
                    }
                    monthMaps[name] = intMap
                }
            }

            return DatePatterns(patterns: patterns, periodPatterns: periodPatterns, monthMaps: monthMaps)
        } catch {
            return nil
        }
    }

    func monthMap(named name: String) -> [String: Int] {
        monthMaps[name] ?? [:]
    }
}

struct AmountConventions: Sendable {
    struct Convention: Codable, Sendable {
        let id: String
        let description: String
        let charge_sign: Int?
        let credit_sign: Int?
        let credit_marker: String?
        let credit_marker_position: String?
        let detect_hint: String?
        let deposit_sign: Int?
        let withdrawal_sign: Int?
        let sourced_from: String?
    }

    struct NumberFormat: Codable, Sendable {
        let thousands_separator: String
        let decimal_separator: String
        let currency_symbols: [String]
        let amount_regex: String
    }

    let numberFormat: NumberFormat
    let conventions: [Convention]

    static func load() -> AmountConventions? {
        guard let url = Bundle.main.url(
            forResource: "amount_conventions",
            withExtension: "json",
            subdirectory: "FinanceTracker/Ingest/StructuralParser/Knowledge"
        ) else { return nil }

        do {
            let data = try Data(contentsOf: url)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

            let formatData = try JSONSerialization.data(withJSONObject: json["number_format"] ?? [:])
            let numberFormat = try JSONDecoder().decode(NumberFormat.self, from: formatData)

            let convData = try JSONSerialization.data(withJSONObject: json["conventions"] ?? [])
            let conventions = try JSONDecoder().decode([Convention].self, from: convData)

            return AmountConventions(numberFormat: numberFormat, conventions: conventions)
        } catch {
            return nil
        }
    }
}
