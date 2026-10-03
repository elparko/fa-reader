import Foundation

public enum HighlightGrouping: Int, CaseIterable, Identifiable {
    case section, color, page, none

    public var id: Int { rawValue }

    public var name: String {
        switch self {
        case .section: "Section"
        case .color: "Color"
        case .page: "Page"
        case .none: "No groups"
        }
    }
}

public enum HighlightOrder: Int, CaseIterable, Identifiable {
    case book, newest, oldest

    public var id: Int { rawValue }

    public var name: String {
        switch self {
        case .book: "Book order"
        case .newest: "Newest first"
        case .oldest: "Oldest first"
        }
    }
}

public struct HighlightFilter: Equatable {
    public var colors: Set<HighlightColor> = []
    public var pages: ClosedRange<Int>?
    public var tag: String?
    public var text = ""
    public var withNotes = false

    public init(colors: Set<HighlightColor> = [], pages: ClosedRange<Int>? = nil, tag: String? = nil, text: String = "", withNotes: Bool = false) {
        self.colors = colors
        self.pages = pages
        self.tag = tag
        self.text = text
        self.withNotes = withNotes
    }
}

public struct HighlightGroup: Identifiable, Equatable {
    public var id: String
    public var title: String
    public var color: HighlightColor?
    public var highlights: [Highlight]
}

public enum HighlightList {
    public static func filter(_ all: [Highlight], _ f: HighlightFilter) -> [Highlight] {
        let terms = f.text.split(whereSeparator: { $0.isWhitespace }).map { fold(String($0)) }
        return all.filter { h in
            if !f.colors.isEmpty, !f.colors.contains(h.highlightColor) { return false }
            if let pages = f.pages, !pages.contains(h.page) { return false }
            if let tag = f.tag, !h.tags.contains(tag.lowercased()) { return false }
            if f.withNotes, h.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
            if !terms.isEmpty {
                let hay = fold(h.text + " " + h.note)
                if !terms.allSatisfy(hay.contains) { return false }
            }
            return true
        }
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Top to bottom, then left to right on the page.
    public static func readingOrder(_ a: Highlight, _ b: Highlight) -> Bool {
        func key(_ h: Highlight) -> (Int, Double, Double, String) {
            guard let r = h.rects.first else { return (h.page, -Double.infinity, 0, h.id) }
            return (h.page, -(r.y + r.h), r.x, h.id)
        }
        return key(a) < key(b)
    }

    public static func sorted(_ hs: [Highlight], _ order: HighlightOrder) -> [Highlight] {
        switch order {
        case .book: hs.sorted(by: readingOrder)
        case .newest: hs.sorted { ($0.created, $0.id) > ($1.created, $1.id) }
        case .oldest: hs.sorted { ($0.created, $0.id) < ($1.created, $1.id) }
        }
    }

    public static func groups(_ hs: [Highlight], by grouping: HighlightGrouping, order: HighlightOrder,
                              sections: [Section], pageLabel: (Int) -> String) -> [HighlightGroup] {
        let items = sorted(hs, order)
        func ordered(_ dict: [String: [Highlight]], keys: [String]) -> [String] {
            order == .book ? keys : keys.sorted { a, b in
                let x = dict[a]!.first!, y = dict[b]!.first!
                return order == .newest ? (x.created, x.id) > (y.created, y.id) : (x.created, x.id) < (y.created, y.id)
            }
        }
        switch grouping {
        case .none:
            return items.isEmpty ? [] : [HighlightGroup(id: "all", title: "", color: nil, highlights: items)]
        case .color:
            return HighlightColor.allCases.compactMap { c in
                let members = items.filter { $0.highlightColor == c }
                return members.isEmpty ? nil : HighlightGroup(id: "color:\(c.rawValue)", title: c.name.capitalized, color: c, highlights: members)
            }
        case .page:
            let dict = Dictionary(grouping: items) { "page:\($0.page)" }
            let keys = Set(items.map(\.page)).sorted().map { "page:\($0)" }
            return ordered(dict, keys: keys).map { k in
                let page = dict[k]!.first!.page
                return HighlightGroup(id: k, title: pageLabel(page), color: nil, highlights: dict[k]!)
            }
        case .section:
            var titles: [String: String] = [:]
            var starts: [String: Int] = [:]
            let dict = Dictionary(grouping: items) { h -> String in
                let s = Sections.section(for: h.page, in: sections)
                let key = s.map { "section:\($0.id)" } ?? "section:none"
                titles[key] = s?.title ?? "Before the first section"
                starts[key] = s?.start ?? -1
                return key
            }
            let keys = dict.keys.sorted { starts[$0]! < starts[$1]! }
            return ordered(dict, keys: keys).map { HighlightGroup(id: $0, title: titles[$0]!, color: nil, highlights: dict[$0]!) }
        }
    }

    public static func counts(_ hs: [Highlight]) -> [HighlightColor: Int] {
        var out: [HighlightColor: Int] = [:]
        for h in hs { out[h.highlightColor, default: 0] += 1 }
        return out
    }

    public static func markdown(_ groups: [HighlightGroup], pageLabel: (Int) -> String) -> String {
        var out = ""
        for g in groups {
            if !g.title.isEmpty { out += (out.isEmpty ? "" : "\n") + "## \(g.title)\n\n" }
            for h in g.highlights {
                let text = h.text.split(whereSeparator: { $0.isNewline }).joined(separator: " ")
                out += h.highlightColor == .noteOnly
                    ? "- Note · \(pageLabel(h.page))\n"
                    : "- ==\(text)== (\(h.highlightColor.name)) · \(pageLabel(h.page))\n"
                for l in h.note.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }) where !h.note.isEmpty {
                    out += l.isEmpty ? "  >\n" : "  > \(l)\n"
                }
            }
        }
        return out
    }
}
