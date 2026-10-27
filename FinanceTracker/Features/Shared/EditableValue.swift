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
/// field only exists while editing. Enter commits — an invalid draft is
/// kept with an inline error — and Escape restores the committed value
/// without triggering a containing sheet's cancel action.
struct EditableValueField<Value: Equatable & Sendable>: View {
    private let value: Value
    private let display: (Value) -> String
    private let parse: (String) -> Value?
    private let onCommit: (Value) -> Void
    private let validate: ((Value) -> String?)?
    private let changeTitle: LocalizedStringKey

    @State private var draft: EditableValueDraft<Value>
    @FocusState private var isFieldFocused: Bool

    init(
        value: Value,
        display: @escaping (Value) -> String,
        parse: @escaping (String) -> Value?,
        onCommit: @escaping (Value) -> Void,
        validate: ((Value) -> String?)? = nil,
        changeTitle: LocalizedStringKey = "Change"
    ) {
        self.value = value
        self.display = display
        self.parse = parse
        self.onCommit = onCommit
        self.validate = validate
        self.changeTitle = changeTitle
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
            draft.replaceAutomatic(with: newValue, edit: display, manual: false)
        }
    }

    /// Read-only value plus the "Change" trigger; no text field exists
    /// until the user asks for one.
    private var consultation: some View {
        HStack(spacing: 4) {
            Text(display(value))
            Button(changeTitle) {
                draft.begin(from: value, edit: display)
            }
            .buttonStyle(.link)
        }
    }

    private var editor: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            TextField(display(value), text: $draft.text)
                .focused($isFieldFocused)
                .onSubmit { commitDraft() }
                .frame(minWidth: 100)
            if let errorText = draft.errorText {
                Label(errorText, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            // Hidden Escape handler inside the row, so it never collides
            // with the cancelAction of a containing sheet.
            Button("Cancel") {
                draft.cancel(edit: display)
            }
            .keyboardShortcut(.cancelAction)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .onAppear { isFieldFocused = true }
    }

    private func commitDraft() {
        draft.commit(parse: parse, validate: validate, onCommit: onCommit)
    }
}

// MARK: - Money field

/// `EditableValueField` preconfigured for money amounts: `Decimal` values
/// formatted with `MoneyFormat` and parsed with the shared entry-amount
/// parser. Shares and percentages do not use this wrapper.
struct EditableMoneyField: View {
    private let value: Decimal
    private let currencyCode: String
    private let onCommit: (Decimal) -> Void
    private let validate: ((Decimal) -> String?)?
    private let changeTitle: LocalizedStringKey

    init(
        value: Decimal,
        currencyCode: String = "MXN",
        onCommit: @escaping (Decimal) -> Void,
        validate: ((Decimal) -> String?)? = nil,
        changeTitle: LocalizedStringKey = "Change"
    ) {
        self.value = value
        self.currencyCode = currencyCode
        self.onCommit = onCommit
        self.validate = validate
        self.changeTitle = changeTitle
    }

    var body: some View {
        EditableValueField(
            value: value,
            display: { MoneyFormat.string($0, code: currencyCode) },
            parse: { PropertyCollectionPosting.parseEntryAmount($0) },
            onCommit: onCommit,
            validate: validate,
            changeTitle: changeTitle
        )
    }
}
