import SwiftUI
import AppKit

/// Raw numeric clipboard helper + the shared "click balance to copy"
/// interaction. Keeps all pasteboard code in one place (the only other
/// pasteboard write is an inline snippet in HouseholdSettlementView).
extension Decimal {
    /// Plain numeric string for clipboard/spreadsheet use: `en_US_POSIX`
    /// (guaranteed dot decimal regardless of user locale), exactly 2 fraction
    /// digits, no currency symbol, no grouping separator. Sign preserved.
    ///   `172382.42` · `-533.72` · `0.00`
    var plainMoneyString: String {
        Self.plainFormatter.string(from: self as NSDecimalNumber) ?? description
    }

    private static let plainFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.usesGroupingSeparator = false
        return formatter
    }()
}

/// Writes a raw amount to the system clipboard.
enum ClipboardWriter {
    /// Copies `amount` as a plain numeric string (see `Decimal.plainMoneyString`).
    @MainActor
    static func copyPlainAmount(_ amount: Decimal) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(amount.plainMoneyString, forType: .string)
    }
}

private struct CopyBalanceAffordance: ViewModifier {
    /// Raw amount copied to the clipboard (sign preserved as the model stores it).
    let amount: Decimal
    /// Displayed amount text, exposed as the VoiceOver value.
    let displayedAmount: String
    @Binding var copied: Bool

    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .underline(hovering, color: .secondary)
            .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .onHover { hovering = $0 }
            .help("Click to copy balance")
            .onTapGesture {
                ClipboardWriter.copyPlainAmount(amount)
                flashCopied()
            }
            .contextMenu {
                Button {
                    ClipboardWriter.copyPlainAmount(amount)
                    flashCopied()
                } label: {
                    Label("Copy Balance", systemImage: "doc.on.doc")
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Balance")
            .accessibilityValue(displayedAmount)
            .accessibilityHint("Copies the raw balance value to the clipboard")
            .accessibilityAddTraits(.isButton)
    }

    private func flashCopied() {
        withAnimation(.easeInOut(duration: 0.2)) { copied = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation(.easeInOut(duration: 0.3)) { copied = false }
        }
    }
}

extension View {
    /// Makes a balance value text clickable to copy its raw amount: hover
    /// underline, tap-to-copy, a "Copy Balance" context menu, and VoiceOver
    /// semantics. The host owns the `copied` binding and renders the transient
    /// "Balance copied" feedback so it can place it in its own layout.
    func copyBalanceAffordance(amount: Decimal, displayedAmount: String, copied: Binding<Bool>) -> some View {
        modifier(CopyBalanceAffordance(amount: amount, displayedAmount: displayedAmount, copied: copied))
    }
}
