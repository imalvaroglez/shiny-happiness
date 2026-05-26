import SwiftUI

struct TransactionDateGroupHeader: View {
    let group: TransactionDayGroup

    var body: some View {
        HStack {
            Text(group.date, format: .dateTime.weekday(.wide).day().month(.wide))
                .font(.subheadline.weight(.semibold))
            Spacer()
            Text("\(group.count) transaction\(group.count == 1 ? "" : "s")")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(MoneyFormat.string(group.netTotal))
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(group.netTotal >= 0 ? .green : .red)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
