import SwiftData
import SwiftUI

struct PaymentDetailsSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let account: Account
    let onSaved: () -> Void

    @State private var billingMonth = Date.now
    @State private var dueDate: Date = Date.now
    @State private var paymentForNoInterest: Decimal = 0
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 18) {
            Text("Payment Details")
                .font(.headline)

            VStack(spacing: 0) {
                row("Account") {
                    Text(account.displayName)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Divider().padding(.leading, 132)

                row("Billing Month") {
                    DatePicker("", selection: $billingMonth, displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.compact)
                }
                Divider().padding(.leading, 132)

                row("Due Date") {
                    DatePicker("", selection: $dueDate, displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.compact)
                }
                Divider().padding(.leading, 132)

                row("Amount to Pay") {
                    HStack(spacing: 8) {
                        TextField("0.00", value: $paymentForNoInterest, format: .number)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                        Text(account.currency)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
            )

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear {
            loadExisting()
        }
        .onChange(of: billingMonth) {
            loadExisting()
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label).frame(width: 116, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func loadExisting() {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month], from: billingMonth)
        guard let monthStart = calendar.date(from: components) else { return }

        let existing = PaymentMetadataService.fetch(
            accountId: account.id,
            billingMonthStart: monthStart,
            context: modelContext
        )
        if let stmt = existing {
            dueDate = stmt.paymentDueDate ?? defaultDueDate(for: billingMonth)
            paymentForNoInterest = stmt.paymentForNoInterest ?? 0
        } else {
            dueDate = defaultDueDate(for: billingMonth)
            paymentForNoInterest = 0
        }
    }

    private func defaultDueDate(for billingMonth: Date) -> Date {
        let calendar = Calendar(identifier: .gregorian)
        let currentDay = calendar.component(.day, from: dueDate)
        let monthComponents = calendar.dateComponents([.year, .month], from: billingMonth)
        guard let monthStart = calendar.date(from: monthComponents),
              let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart) else {
            return billingMonth
        }
        let lastDay = calendar.component(.day, from: calendar.date(byAdding: .day, value: -1, to: nextMonth)!)
        let clampedDay = min(currentDay, lastDay)
        var targetComponents = monthComponents
        targetComponents.day = clampedDay
        return calendar.date(from: targetComponents) ?? billingMonth
    }

    private func save() {
        do {
            try PaymentMetadataService.upsert(
                account: account,
                billingMonth: billingMonth,
                dueDate: dueDate,
                paymentForNoInterest: paymentForNoInterest > 0 ? paymentForNoInterest : nil,
                context: modelContext
            )
            onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
