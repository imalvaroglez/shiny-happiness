import SwiftUI

/// Accounts and houses share the exact sidebar hierarchy and native disclosure behavior.
/// `trailing` puts always-visible controls (e.g. the account sort menu) next to
/// the title; right-click remains as a secondary path, not the only one.
struct SidebarDestinationGroup<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    var trailing: AnyView? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded, content: content) {
            HStack(spacing: 4) {
                Text(LocalizedStringKey(title))
                Spacer(minLength: 8)
                if let trailing { trailing }
            }
        }
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
