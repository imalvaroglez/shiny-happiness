import Foundation
import SwiftData

/// Manual-review hooks that feed user corrections back into the categorization and
/// parsing pipelines. Called from the editable Transactions view and the
/// PendingImport resolution flow.
///
/// The principle: every time the user fixes a row by hand, we record a rule that
/// the next import can apply automatically. Two surfaces today:
///   - merchant -> category (CategoryRule, source = "user_correction")
///   - description -> sign (SignRecoveryHint, source = "user_correction")
enum LearningHooks {
    /// Promote a `Transaction -> Category` assignment into a baseline `CategoryRule`
    /// so future imports of the same merchant categorize without manual touch.
    /// No-ops if a rule for `(keyword, category)` already exists (case-insensitive).
    static func recordCategorization(
        keyword: String?,
        category: Category,
        sourceDescription: String,
        in context: ModelContext
    ) {
        guard let keyword = keyword?.trimmingCharacters(in: .whitespacesAndNewlines), !keyword.isEmpty else {
            return
        }
        let pattern = "(?i)\(NSRegularExpression.escapedPattern(for: keyword))"

        // Skip if an equivalent rule already exists.
        let descriptor = FetchDescriptor<CategoryRule>()
        let existing = (try? context.fetch(descriptor)) ?? []
        if existing.contains(where: { $0.patternRegex == pattern && $0.category?.id == category.id }) {
            return
        }

        let rule = CategoryRule(
            patternRegex: pattern,
            category: category,
            priority: 90,
            source: "user_correction",
            createdFrom: sourceDescription
        )
        context.insert(rule)
    }

    /// When the user resolves a `PendingImport` whose original raw text lacked an
    /// explicit `+/-` sign for the amount, record a `SignRecoveryHint` so the parser
    /// can fix the sign automatically next time. `rawText` is the pending row text;
    /// `resolvedSign` is +1 or -1 based on the resolved transaction's amount sign.
    static func recordSignRecovery(
        rawText: String,
        descriptionKeyword: String?,
        resolvedSign: Int,
        in context: ModelContext
    ) {
        guard signMissing(in: rawText) else { return }
        guard let keyword = descriptionKeyword?.trimmingCharacters(in: .whitespacesAndNewlines), !keyword.isEmpty else {
            return
        }
        let pattern = "(?i)\(NSRegularExpression.escapedPattern(for: keyword))"

        let descriptor = FetchDescriptor<SignRecoveryHint>()
        let existing = (try? context.fetch(descriptor)) ?? []
        if existing.contains(where: { $0.pattern == pattern && $0.implicitSign == resolvedSign }) {
            return
        }

        let hint = SignRecoveryHint(
            pattern: pattern,
            implicitSign: resolvedSign,
            source: "user_correction",
            createdFrom: rawText
        )
        context.insert(hint)
    }

    /// True when the raw row body has no explicit "+" or "-" sign immediately
    /// before its amount token.
    private static func signMissing(in rawText: String) -> Bool {
        // Look for "+ $" or "- $" anywhere in the line. If neither is present,
        // the sign was omitted.
        return rawText.range(of: #"[+\-]\s*\$"#, options: .regularExpression) == nil
    }
}
