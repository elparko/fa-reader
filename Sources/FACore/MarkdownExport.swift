import Foundation

public struct ExportResult: Equatable {
    public var written: [String]
    public var unchanged: [String]
    public var removed: [String]
}

public enum MarkdownExporter {
    public static let marker = "fa-reader-export: 1"

    public static func link(page: Int, highlight: String? = nil) -> String {
        var s = "fa-reader://open?page=\(page + 1)"
        if let highlight { s += "&highlight=\(highlight)" }
        return s
    }

    public static func fileName(for section: Section) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        var title = String(String.UnicodeScalarView(section.title.unicodeScalars.map { bad.contains($0) ? " " : $0 }))
        title = title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        while title.hasPrefix(".") { title.removeFirst() }
        return String(format: "%02d ", section.id) + title + ".md"
    }

    public static func render(section: Section, highlights: [Highlight], printedPage: (Int) -> String?) -> String {
        var out = "---\n\(marker)\n"
        out += "section: \(quoted(section.title))\n"
        if let parent = section.parent { out += "parent: \(quoted(parent))\n" }
        out += "pdf-pages: \(section.start + 1)-\(section.end + 1)\n"
        out += "highlights: \(highlights.count)\n---\n"
        out += "# \(section.title)\n"

        let byPage = Dictionary(grouping: highlights, by: \.page)
        for page in byPage.keys.sorted() {
            if let printed = printedPage(page) {
                out += "\n## p. \(printed) (PDF \(page + 1))\n"
            } else {
                out += "\n## PDF p. \(page + 1)\n"
            }
            for h in byPage[page]!.sorted(by: readingOrder) {
                out += line(h)
            }
        }
        return out
    }

    public static func export(store: Store, sections: [Section], to directory: URL,
                              printedPage: (Int) -> String? = { _ in nil }) throws -> ExportResult {
        var grouped: [Int: [Highlight]] = [:]
        for h in try store.highlights() {
            if let s = Sections.section(for: h.page, in: sections) { grouped[s.id, default: []].append(h) }
        }

        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        var result = ExportResult(written: [], unchanged: [], removed: [])
        var current = Set<String>()
        for section in sections where !(grouped[section.id] ?? []).isEmpty {
            let name = fileName(for: section)
            current.insert(name)
            let data = Data(render(section: section, highlights: grouped[section.id]!, printedPage: printedPage).utf8)
            let url = directory.appendingPathComponent(name)
            if let existing = try? Data(contentsOf: url), existing == data {
                result.unchanged.append(name)
            } else {
                try data.write(to: url, options: .atomic)
                result.written.append(name)
            }
        }

        let files = try fm.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".md") }.sorted()
        for name in files where !current.contains(name) {
            let url = directory.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8), hasMarker(text) else { continue }
            try fm.removeItem(at: url)
            result.removed.append(name)
        }
        return result
    }

    private static func hasMarker(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first == "---" else { return false }
        for l in lines.dropFirst() {
            if l == "---" { return false }
            if l == Substring(marker) { return true }
        }
        return false
    }

    private static func quoted(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func oneLine(_ s: String) -> String {
        s.split(whereSeparator: { $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func line(_ h: Highlight) -> String {
        let open = "[open](\(link(page: h.page, highlight: h.id))) <!-- fa:\(h.id) -->"
        if h.highlightColor == .noteOnly {
            return "- Note: \(oneLine(h.note).replacingOccurrences(of: "==", with: "\\=\\=")) \(open)\n"
        }
        let text = oneLine(h.text).replacingOccurrences(of: "==", with: "\\=\\=")
        var s = "- ==\(text)== (\(h.highlightColor.name)) \(open)\n"
        if !h.note.isEmpty {
            for l in h.note.split(separator: "\n", omittingEmptySubsequences: false) {
                s += l.isEmpty ? "  >\n" : "  > \(l)\n"
            }
        }
        return s
    }

    private static func readingOrder(_ a: Highlight, _ b: Highlight) -> Bool {
        func key(_ h: Highlight) -> (Double, Double, String) {
            guard let r = h.rects.first else { return (-Double.infinity, 0, h.id) }
            return (-(r.y + r.h), r.x, h.id)
        }
        return key(a) < key(b)
    }
}
