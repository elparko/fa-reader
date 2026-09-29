import Foundation
import PDFKit

public struct Section: Identifiable, Hashable {
    public var id: Int
    public var title: String
    public var parent: String?
    public var start: Int
    public var end: Int

    public init(id: Int, title: String, parent: String? = nil, start: Int, end: Int) {
        self.id = id
        self.title = title
        self.parent = parent
        self.start = start
        self.end = end
    }

    public var pages: ClosedRange<Int> { start...end }
}

public enum Sections {
    public static func from(document: PDFDocument) -> [Section] {
        guard let root = document.outlineRoot else {
            return [Section(id: 0, title: "Book", start: 0, end: max(0, document.pageCount - 1))]
        }
        func page(_ o: PDFOutline) -> Int? {
            o.destination?.page.map { document.index(for: $0) }
        }
        var entries: [(title: String, parent: String?, start: Int)] = []
        for i in 0..<root.numberOfChildren {
            guard let top = root.child(at: i), let start = page(top) else { continue }
            let title = normalize(top.label ?? "")
            entries.append((title, nil, start))
            for j in 0..<top.numberOfChildren {
                guard let child = top.child(at: j), let childStart = page(child) else { continue }
                entries.append((normalize(child.label ?? ""), title, childStart))
            }
        }
        return build(entries, pageCount: document.pageCount)
    }

    public static func build(_ entries: [(title: String, parent: String?, start: Int)], pageCount: Int) -> [Section] {
        let sorted = entries.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }.map(\.element)
        var sections: [Section] = []
        for (i, e) in sorted.enumerated() {
            let nextStart = sorted[(i + 1)...].first { $0.start > e.start }?.start ?? pageCount
            if i + 1 < sorted.count, sorted[i + 1].start == e.start { continue }
            sections.append(Section(id: sections.count, title: e.title, parent: e.parent, start: e.start, end: nextStart - 1))
        }
        return sections
    }

    public static func section(for page: Int, in sections: [Section]) -> Section? {
        sections.last { $0.start <= page }
    }

    public static func normalize(_ label: String) -> String {
        var s = label.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if s.uppercased().hasPrefix("SECTION ") {
            let words = s.split(separator: " ").map(String.init)
            var numeral = ""
            var k = 1
            while k < words.count, words[k].allSatisfy({ "IVX".contains($0) }) {
                numeral += words[k]
                k += 1
            }
            if !numeral.isEmpty {
                s = "Section \(numeral): " + words[k...].joined(separator: " ")
            }
        }
        return s
    }
}
