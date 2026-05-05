import Foundation
import PDFKit

struct TextBlock: Identifiable {
    let id = UUID()
    let text: String
    let bounds: CGRect
}

struct TableRow: Sendable {
    let y: CGFloat
    let cells: [TextBlock]
}

struct PDFTextExtractor {
    static func extractBlocks(from page: PDFPage) -> [TextBlock] {
        var blocks: [TextBlock] = []
        let contentRect = page.bounds(for: .mediaBox)

        guard let fullSelection = page.selection(for: contentRect) else { return blocks }

        let lineSelections = fullSelection.selectionsByLine()
        for lineSelection in lineSelections {
            let lineBounds = lineSelection.bounds(for: page)
            let text = lineSelection.string ?? ""
            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                blocks.append(TextBlock(text: text, bounds: lineBounds))
            }
        }

        return blocks
    }

    static func extractRows(from page: PDFPage, yTolerance: CGFloat = 0.02) -> [TableRow] {
        let blocks = extractBlocks(from: page)
        guard !blocks.isEmpty else { return [] }

        let pageHeight = page.bounds(for: .mediaBox).height
        let tolerance = pageHeight * yTolerance

        var rowMap: [CGFloat: [TextBlock]] = [:]
        var rowYValues: [CGFloat] = []

        for block in blocks {
            let y = block.bounds.midY
            if let existingY = rowYValues.first(where: { abs($0 - y) <= tolerance }) {
                rowMap[existingY]?.append(block)
            } else {
                rowYValues.append(y)
                rowMap[y] = [block]
            }
        }

        let sortedY = rowYValues.sorted(by: >)

        return sortedY.compactMap { y in
            guard var cells = rowMap[y] else { return nil }
            cells.sort { $0.bounds.minX < $1.bounds.minX }
            return TableRow(y: y, cells: cells)
        }
    }

    static func extractAllText(from document: PDFDocument) -> String {
        var result = ""
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            if let text = page.string {
                result += text
                result += "\n"
            }
        }
        return result
    }
}
