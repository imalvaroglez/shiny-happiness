import Foundation
import SwiftData

/// Sidecar record of a settlement due date for a single `Transaction`.
///
/// Due dates are meaningful only for `.partner` (Fer) rows — a charge made in one
/// month but payable later (e.g. a credit-card purchase that cuts the following
/// month) must be billed to Fer in the month it is actually due, while staying
/// visible (and explained) in the purchase month. See
/// `docs/specs/household-settlement-due-dates.md`.
///
/// Stored off-`Transaction` because adding an additive-optional `Date?` to the live
/// `Transaction` changes the terminal schema model hash and breaks existing stores
/// (see the spec). Introduced via a lightweight V5→V6 stage; `Transaction` and V5
/// stay byte-identical. Keyed by `transactionID` with no inverse `@Relationship`, so
/// cleanup on transaction/account deletion is explicit.
///
/// - `dueDate != nil`: active override.
/// - `dueDate == nil`: tombstone — an earlier override was cleared. Merge-safe.
/// - Missing row: default to the transaction's purchase (`postedAt`) month.
@Model
final class SettlementDueDateOverride: LastModifiedTracking {
    var id: UUID
    var transactionID: UUID
    var dueDate: Date?
    var lastModifiedAt: Date = Date.now

    init(
        id: UUID = UUID(),
        transactionID: UUID,
        dueDate: Date? = nil
    ) {
        self.id = id
        self.transactionID = transactionID
        self.dueDate = dueDate
    }
}
