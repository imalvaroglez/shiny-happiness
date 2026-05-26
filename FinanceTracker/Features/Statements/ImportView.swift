import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ImportView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var viewModel: ImportViewModel

    init(modelContext: ModelContext) {
        self._viewModel = State(initialValue: ImportViewModel(modelContext: modelContext))
    }

    var body: some View {
        VStack(spacing: 0) {
            dropZone
                .padding()

            if !viewModel.reports.isEmpty {
                reportsSection
                    .padding(.horizontal)
                    .padding(.bottom)
            }
        }
        .navigationTitle("Import Statements")
        .fileImporter(
            isPresented: $viewModel.showFilePicker,
            allowedContentTypes: [.pdf, .commaSeparatedText, .plainText],
            allowsMultipleSelection: true
        ) { result in
            handleFilePickerResult(result)
        }
        .sheet(isPresented: $viewModel.showingPasteSheet) {
            PasteImportSheet(viewModel: viewModel)
        }
    }

    private var dropZone: some View {
        VStack(spacing: 16) {
            Image(systemName: viewModel.isImporting ? "arrow.trianglehead.2.clockwise" : "doc.badge.plus")
                .font(.system(size: 48))
                .foregroundStyle(viewModel.dragTargeted ? Color.accentColor : .secondary)

            Text(viewModel.isImporting ? "Importing..." : "Drop PDF, CSV, or TXT bank statements here")
                .font(.headline)

            HStack(spacing: 10) {
                Button("Browse Files") {
                    viewModel.showFilePicker = true
                }
                .buttonStyle(.glassProminent)
                .disabled(viewModel.isImporting)

                Button {
                    viewModel.showingPasteSheet = true
                } label: {
                    Label("Paste Text", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isImporting)
            }

            if !viewModel.reports.isEmpty {
                HStack(spacing: 24) {
                    MetricChip(label: "New", value: "\(viewModel.totalNewTransactions)", tint: .green)
                    MetricChip(label: "Duplicates", value: "\(viewModel.totalDuplicates)", tint: .orange)
                    MetricChip(label: "Errors", value: "\(viewModel.totalErrors)", tint: .red)
                }

                Button("Clear History") {
                    viewModel.clearReports()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(32)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: GlassRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: GlassRadius.card, style: .continuous)
                .stroke(
                    viewModel.dragTargeted ? Color.accentColor : Color.primary.opacity(0.08),
                    lineWidth: viewModel.dragTargeted ? 2 : 0.5
                )
        )
        .overlay(
            Group {
                if !viewModel.dragTargeted && !viewModel.isImporting {
                    RoundedRectangle(cornerRadius: GlassRadius.card, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [8, 4]))
                        .foregroundStyle(.tertiary)
                }
            }
        )
        .onDrop(of: [.fileURL], isTargeted: $viewModel.dragTargeted) { providers in
            handleDrop(providers)
            return true
        }
    }

    private var reportsSection: some View {
        SectionCard(title: "Import History") {
            VStack(spacing: 0) {
                ForEach(Array(viewModel.reports.enumerated()), id: \.element.fileName) { index, report in
                    ReportRow(report: report)
                    if index < viewModel.reports.count - 1 {
                        Divider().padding(.leading, 12)
                    }
                }
            }
        }
    }

    private final class URLBag: @unchecked Sendable {
        var urls: [URL] = []
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        let group = DispatchGroup()
        let bag = URLBag()

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                defer { group.leave() }
                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                _ = url.startAccessingSecurityScopedResource()
                bag.urls.append(url)
            }
        }

        group.notify(queue: .main) {
            Task {
                await viewModel.importFiles(bag.urls)
                for url in bag.urls {
                    url.stopAccessingSecurityScopedResource()
                }
            }
        }
    }

    private func handleFilePickerResult(_ result: Result<[URL], Error>) {
        guard let urls = try? result.get() else { return }
        Task {
            for url in urls {
                _ = url.startAccessingSecurityScopedResource()
            }
            await viewModel.importFiles(urls)
            for url in urls {
                url.stopAccessingSecurityScopedResource()
            }
        }
    }
}

private struct ReportRow: View {
    let report: IngestReport

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: report.errorCount > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(report.errorCount > 0 ? .red : .green)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(report.fileName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(report.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if report.newTransactions > 0 {
                Text("\(report.newTransactions) new")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.green.opacity(0.12)))
            }

            if report.duplicateTransactions > 0 {
                Text("\(report.duplicateTransactions) dup")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.orange.opacity(0.12)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

extension IngestReport: Identifiable {
    public var id: String { fileName }
}

extension IngestReport {
    var summary: String {
        var parts: [String] = []
        if newTransactions > 0 { parts.append("\(newTransactions) new") }
        if duplicateTransactions > 0 { parts.append("\(duplicateTransactions) duplicates") }
        if errorCount > 0 { parts.append("\(errorCount) errors") }
        if uncategorizedCount > 0 { parts.append("\(uncategorizedCount) uncategorized") }
        return parts.isEmpty ? "No transactions found" : parts.joined(separator: ", ")
    }
}
