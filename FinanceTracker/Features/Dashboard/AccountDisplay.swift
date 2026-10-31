import Foundation

/// Presentation-level helpers for rendering account identity without repeating
/// information the display name already carries.
enum AccountDisplay {
    /// The institution label worth rendering alongside the display name, or
    /// `nil` when it would only repeat it — a "BBVA" row must not stack a
    /// second "BBVA" line underneath.
    ///
    /// Comparison is case-, diacritic- and width-insensitive, and hides the
    /// institution when either string contains the other ("BBVA ···1234" over
    /// "BBVA" adds nothing either).
    static func institutionLabel(displayName: String, institution: String) -> String? {
        let trimmed = institution.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let foldedName = displayName.folded
        let foldedInstitution = trimmed.folded
        guard !foldedName.isEmpty else { return trimmed }

        if foldedName == foldedInstitution { return nil }
        // Containment only counts when the contained side carries real
        // information: a 1–2 character nickname inside "Banorte" hides the
        // institution without the name actually conveying it.
        let shorter = min(foldedName.count, foldedInstitution.count)
        if shorter >= 3,
           foldedName.contains(foldedInstitution) || foldedInstitution.contains(foldedName) {
            return nil
        }
        return trimmed
    }
}

private extension String {
    /// Normalizes case, diacritics and full-width variants so "bbva",
    /// "Bbvá" and "ＢＢＶＡ" all compare equal.
    var folded: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
