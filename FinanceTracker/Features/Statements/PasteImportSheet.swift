import SwiftUI

/// Sheet for pasting statement text copied from a bank portal.
/// HSBC 2Now is the first supported issuer; the detection chip lights up
/// as soon as the buffer contains enough text for `Detector.detectFromPastedText`
/// to identify it.
struct PasteImportSheet: View {
    @Bindable var viewModel: ImportViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingHSBCExample = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 12)

            Divider()

            TextEditor(text: $viewModel.pasteBuffer)
                .font(.system(.body, design: .monospaced))
                .padding(12)
                .frame(minWidth: 600, minHeight: 320)

            Divider()

            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 480, idealHeight: 560)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Paste statement text")
                .font(.title3.bold())
            Text("Copy the statement contents from your bank's web portal and paste them here. The app keeps confidently parsed rows and stages anything ambiguous for review in Transactions.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if shouldShowUnsupportedGuidance {
                Text("Paste import currently supports HSBC 2Now. For a complete import, copy from the “TU PAGO REQUERIDO” heading through the transaction rows.")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showingHSBCExample.toggle()
                    }
                } label: {
                    Label(
                        showingHSBCExample ? "Hide HSBC 2Now example" : "Show HSBC 2Now example",
                        systemImage: showingHSBCExample ? "chevron.down" : "chevron.right"
                    )
                    .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityHint("Shows an example of the HSBC 2Now header needed for paste import.")

                if showingHSBCExample {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("HSBC 2Now example")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(Self.hsbcExampleText)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var shouldShowUnsupportedGuidance: Bool {
        !viewModel.pasteBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && viewModel.pasteDetection.issuer == .unknown
    }

    private static let hsbcExampleText = """
    TU PAGO REQUERIDO ESTE PERIODO
    a) Periodo: 01-Ene-2026 al 31-Ene-2026
    d) Fecha límite de pago: 15-Feb-2026
    e) PAGO PARA NO GENERAR INTERESES: $1,234.56

    RESUMEN DE CARGOS Y ABONOS DEL PERIODO
    """

    private var footer: some View {
        HStack(spacing: 12) {
            detectionChip
            Spacer()
            Button("Cancel") {
                viewModel.pasteBuffer = ""
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button {
                Task { await viewModel.importPastedText() }
            } label: {
                if viewModel.isImporting {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Importing…")
                    }
                } else {
                    Text("Import")
                }
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canImport)
        }
    }

    private var canImport: Bool {
        let trimmed = viewModel.pasteBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !viewModel.isImporting else { return false }
        return viewModel.pasteDetection.issuer != .unknown
    }

    private var detectionChip: some View {
        let detection = viewModel.pasteDetection
        let trimmedEmpty = viewModel.pasteBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let label: String
        let icon: String
        let color: Color
        if trimmedEmpty {
            label = "Waiting for text…"
            icon = "doc.text"
            color = .secondary
        } else if detection.issuer == .unknown {
            label = "Couldn't identify this statement. Paste import supports HSBC 2Now; compare the example to include a complete statement."
            icon = "questionmark.circle"
            color = .orange
        } else {
            label = "Detected: \(detection.issuer.rawValue)"
            icon = "checkmark.seal.fill"
            color = .green
        }
        return HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(label)
                .font(.callout)
                .foregroundStyle(color)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
    }
}
