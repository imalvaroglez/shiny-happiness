import Foundation
import SwiftData

/// Read/write service for settlement due-date overrides (`SettlementDueDateOverride`).
///
/// Due dates are stored off-`Transaction` (see `SettlementDueDateOverride` and
/// `docs/specs/household-settlement-due-dates.md`). This service is the single
/// persistence-aware entry point for the report and the UI: it resolves active
/// due dates for a set of transactions, sets a due date (upsert), and clears one
/// (tombstone — a `nil` row so a cleared date defeats an older active date under
/// backup merge).
@MainActor
enum SettlementDueDateService {
    /// Active due dates for the given transaction IDs. A tombstone (`nil` row) or a
    /// missing row both resolve to "no override" and are absent from the result, so
    /// callers default to the transaction's `postedAt` month.
    ///
    /// Rows are fetched sorted (newest `lastModifiedAt` first, then `id` desc) so the
    /// "newest row per transactionID wins" rule is deterministic even when duplicate
    /// rows share an identical timestamp (e.g. from a legacy bug or backup import).
    static func activeDueDates(for transactionIDs: Set<UUID>, context: ModelContext) -> [UUID: Date] {
        guard !transactionIDs.isEmpty else { return [:] }
        let ids = transactionIDs
        let descriptor = FetchDescriptor<SettlementDueDateOverride>(
            predicate: #Predicate<SettlementDueDateOverride> { ids.contains($0.transactionID) }
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        // Resolve the newest row per transactionID deterministically, independent of
        // the (non-deterministic) order SwiftData returns tied rows in. For each
        // transactionID, keep the row that "wins" under: newer lastModifiedAt, then
        // active (non-nil dueDate) beats tombstone on an identical timestamp, then
        // larger id — so a clear and a set in the same instant doesn't erase a real
        // date and the result is stable across runs.
        var winner: [UUID: SettlementDueDateOverride] = [:]
        for row in rows {
            if let existing = winner[row.transactionID], !Self.shouldReplace(existing, with: row) {
                continue
            }
            winner[row.transactionID] = row
        }
        var result: [UUID: Date] = [:]
        for (txID, row) in winner {
            if let due = row.dueDate { result[txID] = due }
        }
        return result
    }

    /// True if `candidate` should replace `current` as the winning override for a tx.
    private static func shouldReplace(_ current: SettlementDueDateOverride, with candidate: SettlementDueDateOverride) -> Bool {
        if candidate.lastModifiedAt != current.lastModifiedAt {
            return candidate.lastModifiedAt > current.lastModifiedAt
        }
        let candidateActive = candidate.dueDate != nil
        let currentActive = current.dueDate != nil
        if candidateActive != currentActive {
            return candidateActive // active beats tombstone on an identical timestamp
        }
        return candidate.id.uuidString > current.id.uuidString
    }

    /// All override rows for the given transaction IDs (used by backup export).
    static func overrides(for transactionIDs: Set<UUID>, context: ModelContext) -> [SettlementDueDateOverride] {
        guard !transactionIDs.isEmpty else { return [] }
        let ids = transactionIDs
        let descriptor = FetchDescriptor<SettlementDueDateOverride>(
            predicate: #Predicate<SettlementDueDateOverride> { ids.contains($0.transactionID) }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// All override rows (used by backup export of the whole store).
    static func allOverrides(context: ModelContext) -> [SettlementDueDateOverride] {
        (try? context.fetch(FetchDescriptor<SettlementDueDateOverride>())) ?? []
    }

    /// Sets (or replaces) the due date for a transaction. `nil` writes a tombstone.
    ///
    /// A due date cannot precede the transaction's purchase day — if `date` is earlier
    /// than `startOfDay(postedAt)`, it is clamped up to the purchase day so the row is
    /// never stored in an impossible state. (The UI already enforces this via the
    /// DatePicker's `in: postedDay...` bound; this defends programmatic/backup callers.)
    static func setDueDate(_ date: Date?, for transactionID: UUID, context: ModelContext) throws {
        let clamped = Self.clampToNotBeforePurchase(date, for: transactionID, context: context)
        let rows = overrides(for: [transactionID], context: context)
        // Deterministic newest: highest lastModifiedAt, tie-broken by id, so duplicate
        // rows (legacy/backup) never pick an arbitrary winner.
        if let row = rows.max(by: {
            if $0.lastModifiedAt != $1.lastModifiedAt { return $0.lastModifiedAt < $1.lastModifiedAt }
            return $0.id.uuidString < $1.id.uuidString
        }) {
            row.dueDate = clamped
            row.lastModifiedAt = .now
        } else {
            context.insert(SettlementDueDateOverride(transactionID: transactionID, dueDate: clamped))
        }
        try context.save()
    }

    /// Returns `date` clamped to `startOfDay(for: postedAt)` so a due date can never
    /// precede the purchase day. `nil` passes through (tombstone). If the transaction
    /// can't be found, the date is returned unchanged.
    private static func clampToNotBeforePurchase(_ date: Date?, for transactionID: UUID, context: ModelContext) -> Date? {
        guard let date else { return nil }
        let targetID = transactionID
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate<Transaction> { $0.id == targetID }
        )
        guard let tx = (try? context.fetch(descriptor))?.first else { return date }
        let purchaseDay = Calendar(identifier: .gregorian).startOfDay(for: tx.postedAt)
        return date < purchaseDay ? purchaseDay : date
    }

    /// Clears the due date for a transaction by writing a tombstone (`nil`), so a
    /// cleared date survives a subsequent backup merge against an older active date.
    static func clear(for transactionID: UUID, context: ModelContext) throws {
        try setDueDate(nil, for: transactionID, context: context)
    }

    /// Removes all override rows for a transaction (hard delete, no tombstone). Used
    /// when a transaction is reassigned away from Fer — there is no value in keeping
    /// a due date or a tombstone for a non-Fer row.
    static func purge(for transactionIDs: Set<UUID>, context: ModelContext) throws {
        guard !transactionIDs.isEmpty else { return }
        let rows = overrides(for: transactionIDs, context: context)
        for row in rows { context.delete(row) }
        try context.save()
    }
}
