import SwiftUI

/// Sheet for pasting statement text copied from a bank portal.
/// HSBC 2Now is the first supported issuer; the detection chip lights up
/// as soon as the buffer contains enough text for `Detector.detectFromPastedText`
/// to identify it.
struct PasteImportSheet: View {
    @Bindable var viewModel: ImportViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingExample = false

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

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showingExample.toggle() }
            } label: {
                Label(showingExample ? "Hide example" : "Show example", systemImage: showingExample ? "chevron.down" : "chevron.right")
                    .font(.caption)
            }
            .buttonStyle(.plain)

            if showingExample {
                VStack(alignment: .leading, spacing: 4) {
                    Text("HSBC 2Now — copy starting from the “TU PAGO REQUERIDO” header:")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(Self.exampleText)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static let exampleText = """
    TU PAGO REQUERIDO ESTE PERIODO
    a) Periodo:
    …
    10-Abr-2026 al 09-May-2026
    d) Fecha límite de pago: 1 sábado, 30-May-2026
    e) PAGO PARA NO GENERAR INTERESES: 2 $ 30,892.20

    RESUMEN DE CARGOS Y ABONOS DEL PERIODO
    …
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
            label = "Couldn't identify this statement. Paste import currently supports HSBC 2Now — make sure you copied from the “TU PAGO REQUERIDO” header down, and tap Show example to compare."
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
