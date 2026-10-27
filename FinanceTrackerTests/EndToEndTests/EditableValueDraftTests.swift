import Testing
@testable import FinanceTracker

/// Pure state tests for `EditableValueDraft` — no UI, no model container.
///
/// Covers the draft transitions behind `EditableValueField`: commit on
/// Enter, restore on Escape, keep-and-flag on invalid drafts, and
/// automatic refreshes preserving a manual draft.
@Suite("Editable Value Draft State")
struct EditableValueDraftTests {

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
}
