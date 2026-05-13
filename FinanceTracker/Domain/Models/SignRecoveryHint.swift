import Foundation
import SwiftData

/// A learned rule that recovers a missing +/- sign during paste-import based on a
/// description pattern. HSBC sometimes omits the sign glyph on payment lines
/// (e.g. "SU PAGO GRACIAS SPEI ... 25,986.00" with no leading "-"). When the user
/// manually resolves a PendingImport whose amount lacked a sign, we save a hint so
/// the next paste handles the same kind of line automatically.
@Model
final class SignRecoveryHint {
    var id: UUID = UUID()
    /// Case-insensitive regex against `Transaction.descriptionRaw`.
    var pattern: String = ""
    /// `-1` = the row should be stored negative (expense / charge), `+1` = positive
    /// (payment received / refund). Zero is unused.
    var implicitSign: Int = 0
    /// `"seed"` or `"user_correction"`.
    var source: String = "user_correction"
    /// An example raw line, useful for diagnostics.
    var createdFrom: String?
    var matchCount: Int = 0

    init(
        id: UUID = UUID(),
        pattern: String,
        implicitSign: Int,
        source: String = "user_correction",
        createdFrom: String? = nil,
        matchCount: Int = 0
    ) {
        self.id = id
        self.pattern = pattern
        self.implicitSign = implicitSign
        self.source = source
        self.createdFrom = createdFrom
        self.matchCount = matchCount
    }
}
