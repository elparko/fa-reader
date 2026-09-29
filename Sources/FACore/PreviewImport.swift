import AppKit
import Foundation
import PDFKit

public struct RawAnnotation: Equatable {
    public var fingerprint: String
    public var type: String
    public var page: Int
    public var bounds: Rect
    public var rects: [Rect]
    public var text: String
    public var contents: String
    public var color: HighlightColor
    public var date: Date?

    public init(fingerprint: String, type: String, page: Int, bounds: Rect, rects: [Rect], text: String,
                contents: String, color: HighlightColor, date: Date?) {
        self.fingerprint = fingerprint
        self.type = type
        self.page = page
        self.bounds = bounds
        self.rects = rects
        self.text = text
        self.contents = contents
        self.color = color
        self.date = date
    }
}

public struct Burst: Equatable, Identifiable {
    public var id: Int
    public var start: Date
    public var end: Date
    public var count: Int
    public var pages: Int
}

public struct ImportCandidate: Identifiable, Equatable {
    public var id: String
    public var raw: RawAnnotation
    public var burst: Int?
    public var alreadyImported: Bool
    public var highlight: Highlight
}

public struct ImportPreview {
    public var candidates: [ImportCandidate]
    public var bursts: [Burst]

    public func selected(includingBursts: Set<Int> = []) -> [ImportCandidate] {
        candidates.filter { c in
            guard !c.alreadyImported else { return false }
            guard let b = c.burst else { return true }
            return includingBursts.contains(b)
        }
    }

    public func plan(includingBursts: Set<Int> = []) -> Plan {
        Plan(kind: .import, label: "Import from Preview", ops: selected(includingBursts: includingBursts).map { .add($0.highlight) })
    }
}

public enum PreviewImporter {
    static func isOwn(_ a: PDFAnnotation) -> Bool {
        a.userName?.hasPrefix("fa:") == true || a.userName == "fa-selection"
    }

    static let importedTypes: Set<String> = ["Highlight", "Underline", "StrikeOut", "FreeText", "Text"]

    static func fnv1a(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        let hex = String(h, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }

    static func fingerprint(type: String, page: Int, bounds: CGRect) -> String {
        let r = [bounds.minX, bounds.minY, bounds.width, bounds.height].map { Int($0.rounded()) }
        return fnv1a("\(type)|\(page)|\(r[0])|\(r[1])|\(r[2])|\(r[3])")
    }

    public static func scan(_ document: PDFDocument) -> [RawAnnotation] {
        var out: [RawAnnotation] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for a in page.annotations {
                let type = (a.type ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard importedTypes.contains(type), !isOwn(a) else { continue }
                out.append(raw(a, type: type, page: page, index: index))
            }
        }
        return out
    }

    static func raw(_ a: PDFAnnotation, type: String, page: PDFPage, index: Int) -> RawAnnotation {
        let isNote = type == "FreeText" || type == "Text"
        let clipped = a.bounds.intersection(page.bounds(for: .mediaBox))
        let bounds = clipped.isNull || !clipped.isFinite ? CGRect.zero : clipped
        var rects: [CGRect] = []
        if !isNote, let quads = a.quadrilateralPoints {
            for i in stride(from: 0, to: quads.count - 3, by: 4) {
                let pts = quads[i..<(i + 4)].map { $0.pointValue }
                let xs = pts.map(\.x), ys = pts.map(\.y)
                let rect = CGRect(x: a.bounds.minX + xs.min()!, y: a.bounds.minY + ys.min()!,
                                  width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
                if rect.isFinite, !rect.isEmpty, page.bounds(for: .mediaBox).insetBy(dx: -1, dy: -1).contains(rect) { rects.append(rect) }
            }
        }
        if rects.isEmpty, isNote { rects = [bounds] }

        var text = ""
        if !isNote {
            text = rects.compactMap { r in
                page.selection(for: r.insetBy(dx: 0.5, dy: min(2, r.height / 4)))?.string?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        }

        var note = (a.contents ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if note.isEmpty, let popup = a.popup?.contents { note = popup.trimmingCharacters(in: .whitespacesAndNewlines) }

        var color = HighlightColor.noteOnly
        if !isNote {
            let c = a.color.usingColorSpace(.sRGB)
            color = HighlightColor.nearest(r: Double(c?.redComponent ?? 1), g: Double(c?.greenComponent ?? 1), b: Double(c?.blueComponent ?? 0))
        }

        return RawAnnotation(fingerprint: fingerprint(type: type, page: index, bounds: bounds), type: type, page: index,
                             bounds: Rect(bounds), rects: rects.map(Rect.init), text: text, contents: note,
                             color: color, date: a.modificationDate)
    }

    public static func detectBursts(_ annotations: [RawAnnotation], maxGap: TimeInterval = 3, minCount: Int = 15) -> [Burst] {
        let dated = annotations.compactMap { a in a.date.map { (a, $0) } }.sorted { $0.1 < $1.1 }
        var clusters: [[(RawAnnotation, Date)]] = []
        for item in dated {
            if let last = clusters.last?.last, item.1.timeIntervalSince(last.1) <= maxGap {
                clusters[clusters.count - 1].append(item)
            } else {
                clusters.append([item])
            }
        }
        var bursts: [Burst] = []
        for cluster in clusters {
            let start = cluster.first!.1, end = cluster.last!.1
            let pages = Set(cluster.map { $0.0.page }).count
            let fast = pages >= 5 && end.timeIntervalSince(start) <= 10
            guard cluster.count >= minCount || fast else { continue }
            bursts.append(Burst(id: bursts.count, start: start, end: end, count: cluster.count, pages: pages))
        }
        return bursts
    }

    public static func preview(annotations: [RawAnnotation], alreadyImported: Set<String>) -> ImportPreview {
        let bursts = detectBursts(annotations)
        let now = Date().timeIntervalSince1970
        var seen = Set<String>()
        let candidates = annotations.filter { seen.insert($0.fingerprint).inserted }.map { raw -> ImportCandidate in
            let id = "pv-" + raw.fingerprint
            let burst = raw.date.flatMap { d in bursts.first { d >= $0.start && d <= $0.end }?.id }
            let highlight = Highlight(id: id, page: raw.page, rects: raw.rects, text: raw.text, color: raw.color,
                                      note: raw.contents, created: raw.date?.timeIntervalSince1970 ?? now, source: "preview")
            return ImportCandidate(id: id, raw: raw, burst: burst, alreadyImported: alreadyImported.contains(id), highlight: highlight)
        }
        return ImportPreview(candidates: candidates, bursts: bursts)
    }

    public static func preview(document: PDFDocument, store: Store) throws -> ImportPreview {
        preview(annotations: scan(document), alreadyImported: try store.importedHighlightIDs())
    }
}

extension CGRect {
    var isFinite: Bool { [minX, minY, width, height].allSatisfy(\.isFinite) }
}

extension Rect {
    init(_ r: CGRect) { self.init(x: r.minX, y: r.minY, w: r.width, h: r.height) }
}
