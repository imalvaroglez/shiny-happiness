import SwiftUI

struct TransactionDateGroupHeader: View {
    let group: TransactionDayGroup

    var body: some View {
        HStack {
            Text(group.date, format: .dateTime.weekday(.wide).day().month(.wide))
                .font(.subheadline.weight(.semibold))
            Spacer()
            Text(group.count == 1 ? "1 movimiento" : "\(group.count) movimientos")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(MoneyFormat.string(group.netTotal))
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(group.netTotal >= 0 ? .green : .red)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        // Base opaca (se adapta al tema) para que las filas NO se vean a
        // través del header pineado al scrollear; el tinte va encima.
        .background(Color.primary.opacity(0.045))
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
