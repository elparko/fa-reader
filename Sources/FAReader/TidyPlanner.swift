import FACore
import Foundation
import PDFKit

struct TidyPlan {
    var ops: [PendingOp] = []
    var before = 0
    var after = 0
    var pages = 0
}

extension PageGeometry {
    func highlight(from piece: Piece, page: PDFPage, index: Int, text: PageText) -> Highlight? {
        var rects: [Rect] = []
        var strings: [String] = []
        for r in text.runs(piece.chars) {
            for line in lineBoxes(for: r, on: page) {
                rects.append(Rect(x: line.rect.minX, y: line.rect.minY, w: line.rect.width, h: line.rect.height))
                strings.append(line.text)
            }
        }
        guard !rects.isEmpty else { return nil }
        let joined = strings.joined(separator: " ").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return Highlight(id: piece.id ?? Highlight.newID(), page: index, rects: rects, text: joined, color: piece.color,
                         note: piece.note, created: piece.created ?? Date().timeIntervalSince1970, source: piece.source ?? "app")
    }
}

enum TidyPlanner {
    static func plan(url: URL, highlights: [Highlight]) -> TidyPlan? {
        guard let document = PDFDocument(url: url) else { return nil }
        let geometry = PageGeometry()
        let byPage = Dictionary(grouping: highlights, by: \.page)
        var result = TidyPlan()
        for index in byPage.keys.sorted() {
            guard let page = document.page(at: index) else { continue }
            let text = geometry.pageText(page)
            let items = byPage[index, default: []].map { PageHighlight($0, chars: geometry.chars(in: $0.rects, on: page)) }
            let plan = HighlightMerge.tidy(items, text: text)
            guard !plan.isEmpty else { continue }
            let pieces = plan.pieces.compactMap { geometry.highlight(from: $0, page: page, index: index, text: text) }
            result.ops += plan.removed.map(PendingOp.delete) + pieces.map(PendingOp.add)
            result.before += plan.removed.count
            result.after += pieces.count
            result.pages += 1
        }
        return result
    }
}
