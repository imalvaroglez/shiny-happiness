import SwiftUI

// MARK: - Form label layout

/// Shared label-column width for detail form rows, so label and value
/// columns line up across every sheet that renders label-value pairs.
enum FormLabelLayout {
    /// Fixed width for `DetailRow` labels.
    static let width: CGFloat = 120
}

// MARK: - Detail row

/// A label-value row for consult/detail surfaces.
///
/// The label occupies a fixed `FormLabelLayout.width` column; the content
/// fills the remaining width, aligned per `alignment`.
struct DetailRow<Content: View>: View {
    private let title: LocalizedStringKey
    private let alignment: Alignment
    private let content: Content

    init(
        _ title: LocalizedStringKey,
        alignment: Alignment = .leading,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.alignment = alignment
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .frame(width: FormLabelLayout.width, alignment: .leading)
            content
                .frame(maxWidth: .infinity, alignment: alignment)
        }
    }
}

// MARK: - Editable value draft

/// State machine behind `EditableValueField`: the in-progress text draft,
/// the last committed value it falls back to, and any validation error.
///
/// An invalid draft is never discarded: committing keeps the text and
/// surfaces `errorText` instead, so the user can fix the input in place.
struct EditableValueDraft<Value: Equatable & Sendable>: Sendable {
    /// Whether the inline editor is open.
    var isEditing = false
    /// Raw text of the in-progress draft.
    var text = ""
    /// Last value accepted (committed, or refreshed automatically).
    var lastCommitted: Value
    /// Validation error for the current draft, if any.
    var errorText: String?

    init(lastCommitted value: Value) {
        lastCommitted = value
    }

    /// Opens the editor seeded with the editable form of `value`.
    mutating func begin(from value: Value, edit: (Value) -> String) {
        isEditing = true
        text = edit(value)
        errorText = nil
    }

    /// Escape: restores the committed value and closes the editor.
    mutating func cancel(edit: (Value) -> String) {
        text = edit(lastCommitted)
        isEditing = false
        errorText = nil
    }

    /// Enter: parses and validates the draft. On failure the draft stays
    /// open with `errorText` set and `onCommit` is not called; on success
    /// the value is committed and `onCommit` runs.
    mutating func commit(
        parse: (String) -> Value?,
        validate: ((Value) -> String?)? = nil,
        onSave: ((Value) -> String?)? = nil,
        onCommit: (Value) -> Void
    ) {
        guard let parsed = parse(text) else {
            errorText = String(localized: "Invalid value")
            return
        }
        if let validate, let message = validate(parsed) {
            errorText = message
            return
        }
        if let message = onSave?(parsed) {
            errorText = message
            return
        }
        lastCommitted = parsed
        isEditing = false
        errorText = nil
        onCommit(parsed)
    }

    /// Refreshes the automatic value. A manual draft — an open, diverged
    /// editor, or a display flagged as manual by the caller — keeps its
    /// text and only moves `lastCommitted`; otherwise the text follows the
    /// refresh.
    mutating func replaceAutomatic(
        with value: Value,
        edit: (Value) -> String,
        manual: Bool
    ) {
        let hasManualDraft = manual || (isEditing && text != edit(lastCommitted))
        lastCommitted = value
        if !hasManualDraft {
            text = edit(value)
        }
    }
}

// MARK: - Editable value field

/// A value that renders read-only until the user presses "Change".
///
/// Consultation shows `display(value)` plus a link-style button; the text
/// field only exists while editing. `changeTriggerShowsValue` replaces that
/// pair with the amount itself as the trigger, styled as ordinary text.
/// Enter commits — an invalid draft is kept with an inline error — and
/// Escape restores the committed value without triggering a containing
/// sheet's cancel action.
///
/// The editor is seeded with `edit(value)` when provided (falling back to
/// `display`), so fields whose display text is not directly parseable —
/// money rendered with a currency symbol — still commit on Enter.
struct EditableValueField<Value: Equatable & Sendable>: View {
    private let value: Value
    private let display: (Value) -> String
    private let edit: ((Value) -> String)?
    private let parse: (String) -> Value?
    private let onCommit: (Value) -> Void
    private let onSave: ((Value) -> String?)?
    private let onBlurSave: ((Value) -> String?)?
    private let validate: ((Value) -> String?)?
    private let fieldLabel: LocalizedStringKey?
    private let changeTitle: LocalizedStringKey
    private let changeAccessibilityLabel: Text?
    private let changeTriggerShowsValue: Bool
    private let onEditingChange: ((Bool) -> Void)?

    @State private var draft: EditableValueDraft<Value>
    @FocusState private var isFieldFocused: Bool

    init(
        value: Value,
        display: @escaping (Value) -> String,
        parse: @escaping (String) -> Value?,
        onCommit: @escaping (Value) -> Void,
        onSave: ((Value) -> String?)? = nil,
        onBlurSave: ((Value) -> String?)? = nil,
        validate: ((Value) -> String?)? = nil,
        edit: ((Value) -> String)? = nil,
        fieldLabel: LocalizedStringKey? = nil,
        changeTitle: LocalizedStringKey = "Change",
        changeAccessibilityLabel: Text? = nil,
        changeTriggerShowsValue: Bool = false,
        onEditingChange: ((Bool) -> Void)? = nil
    ) {
        self.value = value
        self.display = display
        self.edit = edit
        self.parse = parse
        self.onCommit = onCommit
        self.onSave = onSave
        self.onBlurSave = onBlurSave
        self.validate = validate
        self.fieldLabel = fieldLabel
        self.changeTitle = changeTitle
        self.changeAccessibilityLabel = changeAccessibilityLabel
        self.changeTriggerShowsValue = changeTriggerShowsValue
        self.onEditingChange = onEditingChange
        _draft = State(initialValue: EditableValueDraft(lastCommitted: value))
    }

    var body: some View {
        Group {
            if draft.isEditing {
                editor
            } else {
                consultation
            }
        }
        .onChange(of: value) { _, newValue in
            draft.replaceAutomatic(with: newValue, edit: editText, manual: false)
        }
        .onChange(of: draft.isEditing) { _, editing in onEditingChange?(editing) }
        .onChange(of: isFieldFocused) { _, focused in
            if !focused, draft.isEditing, let onBlurSave {
                draft.commit(parse: parse, validate: validate, onSave: onBlurSave, onCommit: onCommit)
                if draft.isEditing { isFieldFocused = true }
            }
        }
    }

    /// Read-only value plus the "Change" trigger; no text field exists
    /// until the user asks for one. With `changeTriggerShowsValue` the
    /// amount itself is the trigger: a plain-style button that renders
    /// exactly like the static text it replaces (same font, color, and
    /// metrics) instead of adding a link-style title next to it.
    @ViewBuilder
    private var consultation: some View {
        if changeTriggerShowsValue {
            Button {
                draft.begin(from: value, edit: editText)
            } label: {
                Text(display(value))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(changeAccessibilityLabel ?? Text(changeTitle))
        } else {
            HStack(spacing: 4) {
                Text(display(value))
                Button(changeTitle) {
                    draft.begin(from: value, edit: editText)
                }
                .buttonStyle(.link)
                .accessibilityLabel(changeAccessibilityLabel ?? Text(changeTitle))
            }
        }
    }

    private var editor: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            field
            if let errorText = draft.errorText {
                Label(errorText, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            // Hidden Escape handler inside the row, so it never collides
            // with the cancelAction of a containing sheet.
            Button("Cancel") {
                draft.cancel(edit: editText)
            }
            .keyboardShortcut(.cancelAction)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .onAppear { isFieldFocused = true }
    }

    /// The draft text field. `fieldLabel` titles the field and names it
    /// for VoiceOver; without it the display text keeps the old behavior.
    @ViewBuilder
    private var field: some View {
        if let fieldLabel {
            configured(TextField(fieldLabel, text: $draft.text))
                .accessibilityLabel(fieldLabel)
        } else {
            configured(TextField(display(value), text: $draft.text))
        }
    }

    private func configured(_ field: TextField<Text>) -> some View {
        field
            .focused($isFieldFocused)
            .onSubmit { commitDraft() }
            .frame(minWidth: 100)
    }

    /// Text used to seed or restore the editor; `display` when the caller
    /// did not provide a separate editing form.
    private func editText(_ value: Value) -> String {
        edit?(value) ?? display(value)
    }

    private func commitDraft() {
        draft.commit(parse: parse, validate: validate, onSave: onSave, onCommit: onCommit)
    }
}

// MARK: - Money field

/// `EditableValueField` preconfigured for money amounts: `Decimal` values
/// shown with `MoneyFormat`, but seeded and parsed through `MoneyEntry`'s
/// plain-text form, so the seeded text commits on Enter. Shares and
/// percentages do not use this wrapper.
///
/// Intended for NON-negative amounts, e.g. capturing collection receipts.
/// Signed contexts — such as editing a transaction's amount in
/// TransactionDetailSheet — keep using their own signed fields; the entry
/// parser deliberately rejects sign characters (YAGNI).
struct EditableMoneyField: View {
    private let value: Decimal
    private let currencyCode: String
    private let onCommit: (Decimal) -> Void
    private let onSave: ((Decimal) -> String?)?
    private let onBlurSave: ((Decimal) -> String?)?
    private let validate: ((Decimal) -> String?)?
    private let fieldLabel: LocalizedStringKey?
    private let changeTitle: LocalizedStringKey
    private let changeAccessibilityLabel: Text?
    private let changeTriggerShowsValue: Bool
    private let onEditingChange: ((Bool) -> Void)?

    init(
        value: Decimal,
        currencyCode: String = "MXN",
        onCommit: @escaping (Decimal) -> Void,
        onSave: ((Decimal) -> String?)? = nil,
        onBlurSave: ((Decimal) -> String?)? = nil,
        validate: ((Decimal) -> String?)? = nil,
        fieldLabel: LocalizedStringKey? = nil,
        changeTitle: LocalizedStringKey = "Change",
        changeAccessibilityLabel: Text? = nil,
        changeTriggerShowsValue: Bool = false,
        onEditingChange: ((Bool) -> Void)? = nil
    ) {
        self.value = value
        self.currencyCode = currencyCode
        self.onCommit = onCommit
        self.onSave = onSave
        self.onBlurSave = onBlurSave
        self.validate = validate
        self.fieldLabel = fieldLabel
        self.changeTitle = changeTitle
        self.changeAccessibilityLabel = changeAccessibilityLabel
        self.changeTriggerShowsValue = changeTriggerShowsValue
        self.onEditingChange = onEditingChange
    }

    var body: some View {
        EditableValueField(
            value: value,
            display: { MoneyFormat.string($0, code: currencyCode) },
            parse: { MoneyEntry.parseEntryAmount($0) },
            onCommit: onCommit,
            onSave: onSave,
            onBlurSave: onBlurSave,
            validate: validate,
            edit: { MoneyEntry.suggestedEntryText($0) },
            fieldLabel: fieldLabel,
            changeTitle: changeTitle,
            changeAccessibilityLabel: changeAccessibilityLabel,
            changeTriggerShowsValue: changeTriggerShowsValue,
            onEditingChange: onEditingChange
        )
    }
}
