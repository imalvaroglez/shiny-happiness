import Testing
import Foundation
@testable import FinanceTracker

@Suite("KnowledgeLoader")
struct KnowledgeLoaderTests {

    @Test("DatePatterns.load() returns non-nil from bundle")
    func datePatternsLoads() {
        let patterns = DatePatterns.load()
        #expect(patterns != nil, "DatePatterns.load() should succeed — JSON must be in test bundle")
    }

    @Test("DatePatterns month maps are non-empty with correct values")
    func datePatternsMonthMaps() throws {
        let patterns = try #require(DatePatterns.load())

        let shortMap = patterns.monthMap(named: "spanish_short")
        #expect(!shortMap.isEmpty, "spanish_short month map should not be empty")
        #expect(shortMap["Ene"] == 1, "Ene should map to 1")
        #expect(shortMap["Dic"] == 12, "Dic should map to 12")
        #expect(shortMap["Sept"] == 9, "Sept should map to 9")

        let fullMap = patterns.monthMap(named: "spanish_full")
        #expect(!fullMap.isEmpty, "spanish_full month map should not be empty")
        #expect(fullMap["Enero"] == 1, "Enero should map to 1")
        #expect(fullMap["Diciembre"] == 12, "Diciembre should map to 12")
        #expect(fullMap["Septiembre"] == 9, "Septiembre should map to 9")
    }

    @Test("DatePatterns has patterns and period patterns")
    func datePatternsHasContent() throws {
        let patterns = try #require(DatePatterns.load())
        #expect(!patterns.patterns.isEmpty, "Should have date patterns")
        #expect(!patterns.periodPatterns.isEmpty, "Should have period patterns")
    }

    @Test("HeaderVocabulary.load() returns non-nil from bundle")
    func headerVocabularyLoads() {
        let vocab = HeaderVocabulary.load()
        #expect(vocab != nil, "HeaderVocabulary.load() should succeed — JSON must be in test bundle")
    }

    @Test("HeaderVocabulary has keywords for all roles")
    func headerVocabularyKeywords() throws {
        let vocab = try #require(HeaderVocabulary.load())
        #expect(!vocab.dateKeywords.isEmpty, "dateKeywords should not be empty")
        #expect(!vocab.descriptionKeywords.isEmpty, "descriptionKeywords should not be empty")
        #expect(!vocab.amountKeywords.isEmpty, "amountKeywords should not be empty")
        #expect(!vocab.sectionStartMarkers.isEmpty, "sectionStartMarkers should not be empty")
        #expect(!vocab.sectionEndMarkers.isEmpty, "sectionEndMarkers should not be empty")
    }

    @Test("AmountConventions.load() returns non-nil from bundle")
    func amountConventionsLoads() {
        let conventions = AmountConventions.load()
        #expect(conventions != nil, "AmountConventions.load() should succeed — JSON must be in test bundle")
    }

    @Test("AmountConventions has conventions and number format")
    func amountConventionsContent() throws {
        let conventions = try #require(AmountConventions.load())
        #expect(!conventions.conventions.isEmpty, "Should have amount conventions")
        #expect(conventions.numberFormat.thousands_separator == ",")
        #expect(conventions.numberFormat.decimal_separator == ".")

        let crSuffix = conventions.conventions.first { $0.id == "cr_suffix" }
        #expect(crSuffix != nil, "Should have cr_suffix convention")
        #expect(crSuffix?.charge_sign == -1)
        #expect(crSuffix?.credit_sign == 1)
    }

    @Test("StructuralParser() init succeeds with bundle JSON")
    func structuralParserInit() {
        let parser = StructuralParser()
        #expect(parser != nil, "StructuralParser() should initialize — all knowledge JSONs must be loadable from bundle")
    }
}
