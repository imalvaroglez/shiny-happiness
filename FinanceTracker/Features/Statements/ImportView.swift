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
                Divider()
                reportsList
            }
        }
        .navigationTitle("Import Statements")
        .fileImporter(
            isPresented: $viewModel.showFilePicker,
            allowedContentTypes: [.pdf, .commaSeparatedText],
            allowsMultipleSelection: true
        ) { result in
            handleFilePickerResult(result)
        }
    }

    private var dropZone: some View {
        VStack(spacing: 16) {
            Image(systemName: viewModel.isImporting ? "arrow.trianglehead.2.clockwise" : "doc.badge.plus")
                .font(.system(size: 48))
                .foregroundStyle(viewModel.dragTargeted ? Color.accentColor : .secondary)

            Text(viewModel.isImporting ? "Importing..." : "Drop PDF or CSV bank statements here")
                .font(.headline)

            Button("Browse Files") {
                viewModel.showFilePicker = true
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isImporting)

            if !viewModel.reports.isEmpty {
                HStack(spacing: 24) {
                    StatBadge(label: "New", value: viewModel.totalNewTransactions, color: .green)
                    StatBadge(label: "Duplicates", value: viewModel.totalDuplicates, color: .orange)
                    StatBadge(label: "Errors", value: viewModel.totalErrors, color: .red)
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
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(viewModel.dragTargeted ? Color.accentColor.opacity(0.1) : Color(nsColor: .controlBackgroundColor))
                .stroke(viewModel.dragTargeted ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: viewModel.dragTargeted ? 2 : 1)
        )
        .onDrop(of: [.fileURL], isTargeted: $viewModel.dragTargeted) { providers in
            handleDrop(providers)
            return true
        }
    }

    private var reportsList: some View {
        List(viewModel.reports) { report in
            ReportRow(report: report)
        }
        .listStyle(.inset)
        .frame(minHeight: 200)
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        let group = DispatchGroup()
        var urls: [URL] = []

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                defer { group.leave() }
                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                _ = url.startAccessingSecurityScopedResource()
                urls.append(url)
            }
        }

        group.notify(queue: .main) {
            Task {
                await viewModel.importFiles(urls)
                for url in urls {
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
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: report.errorCount > 0 ? "exclamationmark.triangle" : "checkmark.circle")
                    .foregroundStyle(report.errorCount > 0 ? .red : .green)

                VStack(alignment: .leading, spacing: 2) {
                    Text(report.fileName)
                        .font(.headline)
                    Text(report.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if report.newTransactions > 0 {
                    Text("\(report.newTransactions) new")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.green.opacity(0.15))
                        .clipShape(Capsule())
                }

                if report.duplicateTransactions > 0 {
                    Text("\(report.duplicateTransactions) dup")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.15))
                        .clipShape(Capsule())
                }
            }

            if !report.errors.isEmpty {
                ForEach(report.errors, id: \.message) { error in
                    Text(error.message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 24)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct StatBadge: View {
    let label: String
    let value: Int
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.title2.bold())
                .foregroundStyle(color)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
