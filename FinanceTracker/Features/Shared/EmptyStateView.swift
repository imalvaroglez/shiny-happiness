import SwiftUI

struct EmptyStateView: View {
    let icon: String
    let title: String
    var subtitle: String?
    var tint: Color = .accentColor

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
            Text(title)
                .font(.headline)
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 24)
    }
}
