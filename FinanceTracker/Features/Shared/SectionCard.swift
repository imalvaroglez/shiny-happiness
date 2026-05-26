import SwiftUI

struct SectionCard<Content: View>: View {
    let title: String?
    @ViewBuilder var content: () -> Content

    init(title: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title)
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 8)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: GlassRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: GlassRadius.card, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
}
