import CoreGraphics
import FACore
import PDFKit

final class PageGeometry {
    private var lineBoxes: [ObjectIdentifier: [CGRect]] = [:]
    private var charBoxes: [ObjectIdentifier: [CGRect]] = [:]
    private var pageTexts: [ObjectIdentifier: PageText] = [:]

    func reset() {
        lineBoxes = [:]
        charBoxes = [:]
        pageTexts = [:]
    }

    /// Boxes of the text lines on a page, trimmed with `trimLine`.
    func lines(on page: PDFPage) -> [CGRect] {
        let raw = rawLines(on: page)
        return raw.map { Self.trimLine($0, among: raw) }
    }

    func trimLine(_ box: CGRect, on page: PDFPage) -> CGRect {
        Self.trimLine(box, among: rawLines(on: page))
    }

    private func rawLines(on page: PDFPage) -> [CGRect] {
        if let cached = lineBoxes[ObjectIdentifier(page)] { return cached }
        let raw = page.selection(for: page.bounds(for: .mediaBox))?.selectionsByLine().map { $0.bounds(for: page) }
            .filter { $0.width >= 1 && $0.height >= 1 } ?? []
        lineBoxes[ObjectIdentifier(page)] = raw
        return raw
    }

    /// Some lines in First Aid report a box about twice their real height, hanging over the row below.
    /// Cuts such a box where it overlaps a normal-height line in the same column.
    /// Neighboring rows also overlap by about a point; those boxes are cut halfway through the overlap,
    /// so highlights on adjacent rows do not draw a darker stripe where they meet.
    static func trimLine(_ box: CGRect, among lines: [CGRect]) -> CGRect {
        var r = box
        for o in lines where o != box && box.height > o.height * 1.5 && o.maxX > box.minX && o.minX < box.maxX {
            guard o.maxY > r.minY, o.minY < r.maxY else { continue }
            if o.midY < r.midY { r.origin.y = o.maxY; r.size.height = box.maxY - o.maxY } else { r.size.height = o.minY - r.minY }
        }
        if r.height < box.height * 0.3 { r = box }
        let trimmed = r
        for o in lines where o != box && o.maxX > trimmed.minX && o.minX < trimmed.maxX {
            let overlap = min(trimmed.maxY, o.maxY) - max(trimmed.minY, o.minY)
            guard overlap > 0, overlap < min(trimmed.height, o.height) * 0.3 else { continue }
            if o.midY < trimmed.midY {
                let cut = trimmed.minY + overlap / 2
                if cut > r.minY { r.size.height = r.maxY - cut; r.origin.y = cut }
            } else {
                let cut = trimmed.maxY - overlap / 2
                if cut < r.maxY { r.size.height = cut - r.minY }
            }
        }
        return r
    }

    func pageText(_ page: PDFPage) -> PageText {
        if let cached = pageTexts[ObjectIdentifier(page)] { return cached }
        let text = PageText(page.string ?? "")
        pageTexts[ObjectIdentifier(page)] = text
        return text
    }

    /// Boxes of each character on a page, indexed like selections. They come from one-character selections,
    /// because `characterBounds(at:)` counts characters differently from selections in some PDFs, First Aid among them.
    /// The last character of a line reports the whole line's box; it is moved to just after the character before it.
    func charBoxes(_ page: PDFPage) -> [CGRect] {
        if let cached = charBoxes[ObjectIdentifier(page)] { return cached }
        let text = pageText(page)
        var boxes = (0..<text.count).map { page.selection(for: NSRange(location: $0, length: 1))?.bounds(for: page) ?? .zero }
        for i in boxes.indices {
            if text.isSpace(i) { boxes[i] = .zero; continue }
            guard i > 0 else { continue }
            let prev = boxes[i - 1], box = boxes[i]
            if prev.width > 0, box.minX < prev.maxX - 1, box.width > prev.width * 1.5, prev.maxY > box.minY, prev.minY < box.maxY {
                boxes[i] = CGRect(x: prev.maxX, y: box.minY, width: min(prev.width, 5), height: box.height)
            }
        }
        charBoxes[ObjectIdentifier(page)] = boxes
        return boxes
    }

    /// The characters a stored highlight covers: those whose box has its upper middle in one of the highlight's boxes,
    /// after cutting oversized boxes back to their own row. The upper middle, because an oversized box hangs below its row.
    func chars(in rects: [Rect], on page: PDFPage) -> IndexSet {
        let boxes = charBoxes(page)
        let areas = rects.map { trimLine(CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h), on: page).insetBy(dx: -0.5, dy: -0.5) }
        var out = IndexSet()
        for (i, b) in boxes.enumerated() where b.width > 0 && b.height > 0 {
            let p = CGPoint(x: b.midX, y: b.maxY - min(b.height / 2, 6))
            if areas.contains(where: { $0.contains(p) }) { out.insert(i) }
        }
        return out
    }

    /// One box per text line of a character range, spanning the line's own characters, with its text.
    func lineBoxes(for range: Range<Int>, on page: PDFPage) -> [(rect: CGRect, text: String)] {
        guard let selection = page.selection(for: NSRange(location: range.lowerBound, length: range.count)) else { return [] }
        let boxes = charBoxes(page)
        return selection.selectionsByLine().compactMap { line in
            let raw = line.bounds(for: page)
            guard raw.width >= 1, raw.height >= 1 else { return nil }
            var r = trimLine(raw, on: page)
            let span = chars(of: line, on: page).reduce(CGRect.null) { boxes.indices.contains($1) && boxes[$1].width > 0 ? $0.union(boxes[$1]) : $0 }
            if !span.isNull {
                r.origin.x = span.minX
                r.size.width = span.width
            }
            return (r, line.string ?? "")
        }
    }

    /// The characters a selection covers on a page.
    func chars(of selection: PDFSelection, on page: PDFPage) -> IndexSet {
        var out = IndexSet()
        for i in 0..<selection.numberOfTextRanges(on: page) {
            let r = selection.range(at: i, on: page)
            if r.location != NSNotFound, r.length > 0 { out.insert(integersIn: r.location..<(r.location + r.length)) }
        }
        return out
    }
}
