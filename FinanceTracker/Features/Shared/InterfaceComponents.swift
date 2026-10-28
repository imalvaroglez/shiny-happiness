import SwiftUI

/// Accounts and houses share the exact sidebar hierarchy and native disclosure behavior.
struct SidebarDestinationGroup<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded, content: content) { Text(LocalizedStringKey(title)) }
    }
}

struct InlineRowAction: View {
    let title: String
    let symbol: String
    var action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.borderless)
            .help(title)
            .accessibilityLabel(title)
    }
}

/// A visible title and wrapping labels stay inside the sheet at all supported window sizes.
struct StandardEditorForm<Content: View>: View {
    let title: String
    var isValid = true
    var onCancel: () -> Void
    var onSave: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(LocalizedStringKey(title)).font(.title2.bold()).accessibilityAddTraits(.isHeader)
            ScrollView { Form(content: content).formStyle(.grouped) }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save", action: onSave).keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(24)
        .frame(minWidth: 500, idealWidth: 560, minHeight: 320, idealHeight: 460)
    }
}
