import Foundation

public struct ExportResult: Equatable {
    public var written: [String]
    public var unchanged: [String]
    public var removed: [String]
}

public enum MarkdownExporter {
    public static let marker = "fa-reader-export: 1"

    public static func link(page: Int, highlight: String? = nil, pdf: URL? = nil) -> String {
        var s = "fa-reader://open?page=\(page + 1)"
        if let highlight { s += "&highlight=\(highlight)" }
        if let pdf, let path = pdf.path.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) {
            s += "&pdf=\(path)"
        }
        return s
    }

    public static func fileName(for section: Section) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        var title = String(String.UnicodeScalarView(section.title.unicodeScalars.map { bad.contains($0) ? " " : $0 }))
        title = title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        while title.hasPrefix(".") { title.removeFirst() }
        title = String(title.prefix(120))
        return String(format: "%02d ", section.id) + title + ".md"
    }

    public static let blockStart = "<!-- fa-reader:highlights:start -->"
    public static let blockEnd = "<!-- fa-reader:highlights:end -->"
    public static let notesHeading = "## Notes"

    public static func render(section: Section, highlights: [Highlight], printedPage: (Int) -> String?, pdf: URL? = nil) -> String {
        merge(existing: nil, section: section, highlights: highlights, printedPage: printedPage, pdf: pdf)
    }

    public static func merge(existing: String?, section: Section, highlights: [Highlight],
                             printedPage: (Int) -> String?, pdf: URL? = nil) -> String {
        var out = "---\n\(marker)\n"
        if let pdf { out += "book: \(quoted(pdf.deletingPathExtension().lastPathComponent))\n" }
        out += "section: \(quoted(section.title))\n"
        if let parent = section.parent { out += "parent: \(quoted(parent))\n" }
        out += "pdf-pages: \(section.start + 1)-\(section.end + 1)\n"
        out += "highlights: \(highlights.count)\n---\n"

        var block = blockStart + "\n"
        let byPage = Dictionary(grouping: highlights, by: \.page)
        for page in byPage.keys.sorted() {
            if let printed = printedPage(page) {
                block += "\n## p. \(printed) (PDF \(page + 1))\n"
            } else {
                block += "\n## PDF p. \(page + 1)\n"
            }
            for h in byPage[page]!.sorted(by: readingOrder) {
                block += line(h, pdf: pdf)
            }
        }
        if !highlights.isEmpty { block += "\n" }
        block += blockEnd + "\n"

        if let existing, let parts = split(existing) {
            return out + parts.before + block + parts.after
        }
        return out + "# \(section.title)\n\n" + block + "\n" + notesHeading + "\n\n"
    }

    public static func hasUserContent(_ text: String) -> Bool {
        guard let parts = split(text) else { return !body(text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let rest = (parts.before + parts.after).split(separator: "\n").filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && !t.hasPrefix("# ") && t != notesHeading
        }
        return !rest.isEmpty
    }

    private static func body(_ text: String) -> Substring {
        guard text.hasPrefix("---\n"), let close = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) else {
            return Substring(text)
        }
        return text[close.upperBound...]
    }

    private static func split(_ text: String) -> (before: String, after: String)? {
        let b = body(text)
        guard let start = b.range(of: blockStart), let end = b.range(of: blockEnd, range: start.upperBound..<b.endIndex) else { return nil }
        var afterStart = end.upperBound
        if afterStart < b.endIndex, b[afterStart] == "\n" { afterStart = b.index(after: afterStart) }
        return (String(b[..<start.lowerBound]), String(b[afterStart...]))
    }

    public static func export(store: Store, sections: [Section], to directory: URL,
                              printedPage: (Int) -> String? = { _ in nil }, pdf: URL? = nil) throws -> ExportResult {
        try export(highlights: store.highlights(), sections: sections, to: directory, printedPage: printedPage, pdf: pdf)
    }

    public static func export(highlights: [Highlight], sections: [Section], to directory: URL,
                              printedPage: (Int) -> String? = { _ in nil }, pdf: URL? = nil) throws -> ExportResult {
        var grouped: [Int: [Highlight]] = [:]
        for h in highlights {
            if let s = Sections.section(for: h.page, in: sections) { grouped[s.id, default: []].append(h) }
        }

        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        var result = ExportResult(written: [], unchanged: [], removed: [])
        var current = Set<String>()
        for section in sections {
            let name = fileName(for: section)
            let url = directory.appendingPathComponent(name)
            let existing = try? String(contentsOf: url, encoding: .utf8)
            if let existing, !hasMarker(existing) { continue }
            let highlights = grouped[section.id] ?? []
            guard !highlights.isEmpty || existing.map(hasUserContent) == true else { continue }
            current.insert(name)
            let text = merge(existing: existing, section: section, highlights: highlights, printedPage: printedPage, pdf: pdf)
            if existing == text {
                result.unchanged.append(name)
            } else {
                try Data(text.utf8).write(to: url, options: .atomic)
                result.written.append(name)
            }
        }

        let files = try fm.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".md") }.sorted()
        for name in files where !current.contains(name) {
            let url = directory.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8), hasMarker(text), !hasUserContent(text) else { continue }
            try fm.removeItem(at: url)
            result.removed.append(name)
        }
        return result
    }

    public static func hasMarker(_ text: String) -> Bool {
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

    private static func line(_ h: Highlight, pdf: URL?) -> String {
        let open = "[open](\(link(page: h.page, highlight: h.id, pdf: pdf))) <!-- fa:\(h.id) -->"
        if h.highlightColor == .noteOnly {
            return "- Note: \(oneLine(h.note).replacingOccurrences(of: "==", with: "\\=\\=")) \(open)\n"
        }
        let text = oneLine(h.text).replacingOccurrences(of: "==", with: "\\=\\=")
        var s = "- ==\(text)== (\(h.highlightColor.name)) \(open)\n"
        if !h.note.isEmpty {
            for l in h.note.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }) {
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

extension CharacterSet {
    static let urlQueryValueAllowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?#"))
}
