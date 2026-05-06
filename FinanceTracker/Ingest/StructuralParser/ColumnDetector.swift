import Foundation

struct DetectedColumn: Sendable {
    let role: ColumnRole
    let xCenter: CGFloat
    let xRange: ClosedRange<CGFloat>
    let headerText: String?
}

struct DetectedTable: Sendable {
    enum Layout: Sendable {
        case grid
        case flow
    }

    let layout: Layout
    let columns: [DetectedColumn]
    let dataRowRange: Range<Int>
    let amountConvention: String?

    var isEmpty: Bool {
        dataRowRange.isEmpty
    }
}

struct ColumnDetector: Sendable {
    let vocabulary: HeaderVocabulary

    init(vocabulary: HeaderVocabulary) {
        self.vocabulary = vocabulary
    }

    func detectTables(in rows: [TableRow]) -> [DetectedTable] {
        var tables: [DetectedTable] = []
        var currentIndex = 0

        while currentIndex < rows.count {
            guard let table = findNextTable(from: currentIndex, in: rows) else {
                currentIndex += 1
                continue
            }
            tables.append(table)
            currentIndex = table.dataRowRange.upperBound
        }

        return tables
    }

    func detectTable(in rows: [TableRow]) -> DetectedTable? {
        detectTables(in: rows).first
    }

    private func findNextTable(from startIndex: Int, in rows: [TableRow]) -> DetectedTable? {
        var i = startIndex

        while i < rows.count {
            let combinedColumns = tryCombinedHeader(in: rows[i])
            let isStart = vocabulary.isSectionStart(rowText(rows[i]))

            let columns: [DetectedColumn]
            let headerIndex: Int

            if let combined = combinedColumns, combined.count >= 2 {
                columns = combined
                headerIndex = i
            } else if isStart {
                let lookAhead = scanForHeader(from: i, in: rows)
                columns = lookAhead.columns
                headerIndex = lookAhead.headerIndex
            } else if let combined = combinedColumns {
                columns = combined
                headerIndex = i
            } else {
                let detected = detectColumns(in: rows[i])
                if detected.count >= 2 {
                    columns = detected
                    headerIndex = i
                } else {
                    i += 1
                    continue
                }
            }

            guard !columns.isEmpty else { i += 1; continue }

            let layout = determineLayout(columns: columns, rows: rows, headerIndex: headerIndex)
            let endRowIndex = findSectionEnd(from: headerIndex + 1, in: rows)

            let dataStart = headerIndex + 1
            let dataEnd = min(endRowIndex, rows.count)
            if dataStart >= dataEnd { i += 1; continue }

            let convention = detectAmountConvention(
                rows: Array(rows[dataStart..<dataEnd]),
                columns: columns
            )

            return DetectedTable(
                layout: layout,
                columns: columns,
                dataRowRange: dataStart..<dataEnd,
                amountConvention: convention
            )
        }
        return nil
    }

    private func scanForHeader(from sectionStart: Int, in rows: [TableRow]) -> (columns: [DetectedColumn], headerIndex: Int) {
        for j in (sectionStart + 1)..<min(sectionStart + 5, rows.count) {
            if let combined = tryCombinedHeader(in: rows[j]), combined.count >= 2 {
                return (columns: combined, headerIndex: j)
            }
            let detected = detectColumns(in: rows[j])
            if detected.count >= 2 {
                return (columns: detected, headerIndex: j)
            }
        }
        let fallback = detectColumns(in: rows[sectionStart])
        return (columns: fallback, headerIndex: sectionStart)
    }

    private func detectColumns(in row: TableRow) -> [DetectedColumn] {
        var columns: [DetectedColumn] = []

        for cell in row.cells {
            let text = cell.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }

            if let role = vocabulary.roleForKeyword(text) {
                columns.append(DetectedColumn(
                    role: role,
                    xCenter: cell.bounds.midX,
                    xRange: cell.bounds.minX...cell.bounds.maxX,
                    headerText: text
                ))
            }
        }

        return columns
    }

    private func tryCombinedHeader(in row: TableRow) -> [DetectedColumn]? {
        let text = rowText(row)
        var columns: [DetectedColumn] = []
        var matchedAnyCombined = false

        for (headerPattern, roles) in vocabulary.combinedHeaders {
            if text.localizedCaseInsensitiveContains(headerPattern) {
                matchedAnyCombined = true

                let matchingCell = row.cells.first { cell in
                    cell.text.trimmingCharacters(in: .whitespaces)
                        .localizedCaseInsensitiveContains(headerPattern)
                }
                let xCenter = matchingCell?.bounds.midX ?? row.cells.first?.bounds.midX ?? 0
                let xRange = matchingCell.map { $0.bounds.minX...$0.bounds.maxX }
                    ?? row.cells.first.map { $0.bounds.minX...$0.bounds.maxX } ?? (0...0)

                for roleString in roles {
                    if let role = ColumnRole(rawValue: roleString) {
                        columns.append(DetectedColumn(
                            role: role,
                            xCenter: xCenter,
                            xRange: xRange,
                            headerText: headerPattern
                        ))
                    }
                }
            }
        }

        guard matchedAnyCombined else { return nil }

        for cell in row.cells {
            let cellText = cell.text.trimmingCharacters(in: .whitespaces)
            guard !cellText.isEmpty else { continue }

            var matchesCombinedHeader = false
            for (headerPattern, _) in vocabulary.combinedHeaders {
                if cellText.localizedCaseInsensitiveContains(headerPattern) {
                    matchesCombinedHeader = true
                    break
                }
            }
            if matchesCombinedHeader { continue }

            if let role = vocabulary.roleForKeyword(cellText) {
                if !columns.contains(where: { $0.role == role }) {
                    columns.append(DetectedColumn(
                        role: role,
                        xCenter: cell.bounds.midX,
                        xRange: cell.bounds.minX...cell.bounds.maxX,
                        headerText: cellText
                    ))
                }
            }
        }

        return columns.isEmpty ? nil : columns
    }

    private func determineLayout(columns: [DetectedColumn], rows: [TableRow], headerIndex: Int) -> DetectedTable.Layout {
        let hasSeparateDebitCredit = columns.contains(where: { $0.role == .debit }) &&
                                      columns.contains(where: { $0.role == .credit })

        if hasSeparateDebitCredit {
            return .grid
        }

        let dateCol = columns.first(where: { $0.role == .date })
        let descCol = columns.first(where: { $0.role == .description })

        if let dateCol, let descCol {
            if abs(dateCol.xCenter - descCol.xCenter) < 50 {
                return .flow
            }
        }

        return .grid
    }

    private func findSectionEnd(from startIndex: Int, in rows: [TableRow]) -> Int {
        for i in startIndex..<rows.count {
            let text = rowText(rows[i])
            if vocabulary.isSectionEnd(text) {
                return i
            }
        }
        return rows.count
    }

    private func detectAmountConvention(rows: [TableRow], columns: [DetectedColumn]) -> String? {
        let allText = rows.map { rowText($0) }.joined(separator: " ")

        if columns.contains(where: { $0.role == .debit }) &&
           columns.contains(where: { $0.role == .credit }) {
            return "split_columns"
        }

        if allText.contains("CR") {
            return "cr_suffix"
        }

        return nil
    }

    func assignCellRoles(in row: TableRow, columns: [DetectedColumn]) -> [(text: String, role: ColumnRole?)] {
        var assignments: [(text: String, role: ColumnRole?)] = []

        for cell in row.cells {
            let text = cell.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }

            let closestColumn = columns.min(by: { column1, column2 in
                let dist1 = abs(cell.bounds.midX - column1.xCenter)
                let dist2 = abs(cell.bounds.midX - column2.xCenter)
                return dist1 < dist2
            })

            assignments.append((text: text, role: closestColumn?.role))
        }

        return assignments
    }

    private func rowText(_ row: TableRow) -> String {
        row.cells.map { $0.text.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
