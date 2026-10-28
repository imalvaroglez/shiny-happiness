import Foundation
import Testing
@testable import FinanceTracker

/// Pure state tests for `EditableValueDraft` — no UI, no model container.
///
/// Covers the draft transitions behind `EditableValueField`: commit on
/// Enter, restore on Escape, keep-and-flag on invalid drafts, and
/// automatic refreshes preserving a manual draft.
@Suite("Editable Value Draft State")
struct EditableValueDraftTests {

    @Test("A rejected save preserves the draft and its committed value")
    func rejectedSavePreservesDraft() {
        var draft = EditableValueDraft(lastCommitted: 100)
        draft.begin(from: 100, edit: edit)
        draft.text = "250"
        var committed: Int?
        draft.commit(parse: parse, onSave: { _ in "No se pudo guardar" }, onCommit: { committed = $0 })
        #expect(draft.isEditing)
        #expect(draft.text == "250")
        #expect(draft.lastCommitted == 100)
        #expect(draft.errorText == "No se pudo guardar")
        #expect(committed == nil)
    }

    private func parse(_ text: String) -> Int? {
        Int(text)
    }

    private func edit(_ value: Int) -> String {
        "\(value)"
    }

    @Test("Enter commits a valid draft")
    func enterCommitsValidDraft() {
        var draft = EditableValueDraft(lastCommitted: 100)

        draft.begin(from: 100, edit: edit)
        #expect(draft.isEditing)
        #expect(draft.text == "100")

        draft.text = "250"
        var committed: Int?
        draft.commit(parse: parse, onCommit: { committed = $0 })

        #expect(committed == 250)
        #expect(!draft.isEditing)
        #expect(draft.lastCommitted == 250)
        #expect(draft.errorText == nil)
    }

    @Test("Escape restores the previous value and closes the field")
    func escapeRestoresPreviousValueAndClosesField() {
        var draft = EditableValueDraft(lastCommitted: 100)

        draft.begin(from: 100, edit: edit)
        draft.text = "999"
        draft.cancel(edit: edit)

        #expect(!draft.isEditing)
        #expect(draft.text == "100")
        #expect(draft.lastCommitted == 100)
        #expect(draft.errorText == nil)
    }

    @Test("An invalid draft keeps its text and surfaces an error")
    func invalidDraftKeepsTextAndSurfacesError() {
        var draft = EditableValueDraft(lastCommitted: 100)

        draft.begin(from: 100, edit: edit)
        draft.text = "abc"
        var committed: Int?
        draft.commit(parse: parse, onCommit: { committed = $0 })

        #expect(committed == nil)
        #expect(draft.isEditing)
        #expect(draft.text == "abc")
        #expect(draft.errorText != nil)

        // A value that parses but fails validation keeps the draft too,
        // surfacing the custom message instead of the generic one.
        draft.text = "500"
        draft.commit(
            parse: parse,
            validate: { $0 > 300 ? "Too high" : nil },
            onCommit: { committed = $0 }
        )

        #expect(committed == nil)
        #expect(draft.isEditing)
        #expect(draft.text == "500")
        #expect(draft.errorText == "Too high")
        #expect(draft.lastCommitted == 100)
    }

    @Test("An automatic refresh keeps a manual draft")
    func automaticRefreshKeepsManualDraft() {
        // No manual draft: the refresh moves text and lastCommitted.
        var draft = EditableValueDraft(lastCommitted: 100)
        draft.replaceAutomatic(with: 150, edit: edit, manual: false)

        #expect(draft.text == "150")
        #expect(draft.lastCommitted == 150)

        // Diverged in-progress draft: text survives, lastCommitted moves.
        draft.begin(from: 150, edit: edit)
        draft.text = "200"
        draft.replaceAutomatic(with: 175, edit: edit, manual: false)

        #expect(draft.isEditing)
        #expect(draft.text == "200")
        #expect(draft.lastCommitted == 175)

        // Escape restores the refreshed value, not the stale one.
        draft.cancel(edit: edit)
        #expect(draft.text == "175")
        #expect(!draft.isEditing)

        // Manual display: the caller flags it, so the refresh must not
        // clobber the shown text.
        var manual = EditableValueDraft(lastCommitted: 100)
        manual.text = "120"
        manual.replaceAutomatic(with: 150, edit: edit, manual: true)

        #expect(manual.text == "120")
        #expect(manual.lastCommitted == 150)
    }

    @Test("Begin with an active error clears it and reseeds the text")
    func beginWithActiveErrorClearsErrorAndReseeds() {
        var draft = EditableValueDraft(lastCommitted: 100)

        draft.begin(from: 100, edit: edit)
        draft.text = "abc"
        draft.commit(parse: parse, onCommit: { _ in })
        #expect(draft.isEditing)
        #expect(draft.errorText != nil)

        draft.begin(from: 100, edit: edit)
        #expect(draft.isEditing)
        #expect(draft.errorText == nil)
        #expect(draft.text == "100")
    }

    @Test("Commit after a divergent refresh delivers the manual draft")
    func commitAfterRefreshKeepsManualDraft() {
        var draft = EditableValueDraft(lastCommitted: 100)
        draft.begin(from: 100, edit: edit)
        draft.text = "200"

        // An automatic refresh arrives with a different value: the manual
        // draft survives it, so commit delivers the draft, not the refresh.
        draft.replaceAutomatic(with: 175, edit: edit, manual: false)

        var committed: Int?
        draft.commit(parse: parse, onCommit: { committed = $0 })

        #expect(committed == 200)
        #expect(draft.lastCommitted == 200)
        #expect(!draft.isEditing)
        #expect(draft.errorText == nil)
    }

    @Test("A second begin reseeds the editor text")
    func doubleBeginReseedsText() {
        var draft = EditableValueDraft(lastCommitted: 100)

        draft.begin(from: 100, edit: edit)
        draft.text = "250"
        draft.begin(from: 120, edit: edit)

        #expect(draft.isEditing)
        #expect(draft.text == "120")
        #expect(draft.errorText == nil)
    }

    @Test("The editor is seeded with edit text, not display text")
    func beginSeedsEditorWithEditClosureNotDisplay() {
        // Display renders a currency symbol; entry text must not, or a
        // seeded draft could never parse on Enter. This pins the edit ≠
        // display contract at the machine level.
        let displayText: (Decimal) -> String = { "$\($0)" }
        let entryText: (Decimal) -> String = { MoneyEntry.suggestedEntryText($0) }
        let amount = Decimal(string: "1000")!
        var draft = EditableValueDraft(lastCommitted: amount)

        draft.begin(from: amount, edit: entryText)
        #expect(draft.text == "1000.00")
        #expect(draft.text != displayText(amount))

        var committed: Decimal?
        draft.commit(parse: { MoneyEntry.parseEntryAmount($0) }, onCommit: { committed = $0 })

        #expect(committed == Decimal(string: "1000.00")!)
        #expect(!draft.isEditing)
        #expect(draft.errorText == nil)
    }

    @Test("Begin from the value trigger seeds the edit form, not the display")
    func beginFromValueTriggerSeedsEditForm() {
        // The amount-as-trigger button opens the editor from the value the
        // user is looking at, so the seeded text must be `edit` of that
        // value; a display form with a currency symbol could never commit.
        let amount = Decimal(string: "2500")!
        var draft = EditableValueDraft(lastCommitted: amount)

        draft.begin(from: amount, edit: { MoneyEntry.suggestedEntryText($0) })

        #expect(draft.isEditing)
        #expect(draft.text == "2500.00")
        #expect(draft.text != "$\(amount)")

        var committed: Decimal?
        draft.commit(parse: { MoneyEntry.parseEntryAmount($0) }, onCommit: { committed = $0 })

        #expect(committed == Decimal(string: "2500.00")!)
        #expect(!draft.isEditing)
        #expect(draft.errorText == nil)
    }
}
