import Foundation

/// A page's text as UTF-16 units, indexed the same way as PDFKit character indices.
public struct PageText {
    public let units: [UInt16]

    public init(_ text: String) { units = Array(text.utf16) }

    public var count: Int { units.count }

    public func isSpace(_ i: Int) -> Bool {
        guard units.indices.contains(i), let s = Unicode.Scalar(units[i]) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(s)
    }

    public func isWord(_ i: Int) -> Bool {
        guard units.indices.contains(i) else { return false }
        guard let s = Unicode.Scalar(units[i]) else { return true }
        return CharacterSet.alphanumerics.contains(s) || s == "'" || s == "\u{2019}" || s == "-"
    }

    /// Trims whitespace from both ends, then widens the range to whole words.
    public func snap(_ r: Range<Int>) -> Range<Int> {
        var lo = max(0, r.lowerBound), hi = min(count, r.upperBound)
        while lo < hi, isSpace(lo) { lo += 1 }
        while hi > lo, isSpace(hi - 1) { hi -= 1 }
        guard lo < hi else { return r }
        while lo > 0, isWord(lo), isWord(lo - 1) { lo -= 1 }
        while hi < count, isWord(hi - 1), isWord(hi) { hi += 1 }
        return lo..<hi
    }

    public func snap(_ chars: IndexSet) -> IndexSet {
        var out = IndexSet()
        for r in runs(chars) { out.insert(integersIn: snap(r)) }
        return out
    }

    /// Contiguous runs of `chars`, where runs separated only by whitespace count as one.
    public func runs(_ chars: IndexSet) -> [Range<Int>] {
        var out: [Range<Int>] = []
        for r in chars.rangeView {
            if let last = out.last, (last.upperBound..<r.lowerBound).allSatisfy(isSpace) {
                out[out.count - 1] = last.lowerBound..<r.upperBound
            } else {
                out.append(r)
            }
        }
        return out
    }

    public func solid(_ chars: IndexSet) -> IndexSet { chars.filteredIndexSet { !isSpace($0) } }

    func hasWord(_ chars: IndexSet) -> Bool {
        chars.contains { i in
            guard let s = Unicode.Scalar(units[i]) else { return true }
            return CharacterSet.alphanumerics.contains(s)
        }
    }
}

/// An existing highlight and the page characters it covers.
public struct PageHighlight {
    public var highlight: Highlight
    public var chars: IndexSet

    public init(_ highlight: Highlight, chars: IndexSet) {
        self.highlight = highlight
        self.chars = chars
    }
}

/// A highlight to create from page characters. A non-nil `id` keeps the id of a highlight being replaced.
public struct Piece: Equatable {
    public var chars: IndexSet
    public var color: HighlightColor
    public var note: String
    public var id: String?
    public var created: Double?
    public var source: String?

    public init(chars: IndexSet, color: HighlightColor, note: String = "", id: String? = nil, created: Double? = nil, source: String? = nil) {
        self.chars = chars
        self.color = color
        self.note = note
        self.id = id
        self.created = created
        self.source = source
    }
}

/// Highlights to delete from a page and pieces to add in their place.
public struct PagePlan: Equatable {
    public var removed: [Highlight] = []
    public var pieces: [Piece] = []

    public init(removed: [Highlight] = [], pieces: [Piece] = []) {
        self.removed = removed
        self.pieces = pieces
    }

    public var isEmpty: Bool { removed.isEmpty && pieces.isEmpty }
}

public enum HighlightMerge {
    /// Plans highlighting `chars` in `color`, or removing highlighting from them when `color` is nil,
    /// so that highlights on the page never overlap:
    /// - same-color highlights that overlap or touch the new text are merged into one, keeping the oldest one's id;
    /// - other-color highlights keep only the part outside the new text, split into pieces where needed.
    public static func plan(_ chars: IndexSet, color: HighlightColor?, existing: [PageHighlight], text: PageText) -> PagePlan {
        let new = text.solid(chars)
        guard !new.isEmpty else { return PagePlan() }
        let marked = existing.filter { $0.highlight.highlightColor != .noteOnly && !$0.chars.isEmpty }
        let touched = marked.filter { e in
            if !e.chars.intersection(new).isEmpty { return true }
            guard let color, e.highlight.highlightColor == color else { return false }
            return text.runs(e.chars.union(new)).count < text.runs(e.chars).count + text.runs(new).count
        }
        guard let color else {
            return PagePlan(removed: touched.map(\.highlight), pieces: touched.flatMap { leftovers($0, minus: new, text: text) })
        }
        let same = touched.filter { $0.highlight.highlightColor == color }
            .sorted { ($0.highlight.created, $0.highlight.id) < ($1.highlight.created, $1.highlight.id) }
        let other = touched.filter { $0.highlight.highlightColor != color }
        if other.isEmpty, same.count == 1, new.isSubset(of: same[0].chars) { return PagePlan() }

        var merged = new
        for e in same { merged.formUnion(e.chars) }
        var notes: [String] = []
        for e in same where !e.highlight.note.isEmpty && !notes.contains(e.highlight.note) { notes.append(e.highlight.note) }
        let keep = same.first?.highlight
        var plan = PagePlan(removed: touched.map(\.highlight))
        plan.pieces.append(Piece(chars: merged, color: color, note: notes.joined(separator: "\n\n"),
                                 id: keep?.id, created: keep?.created, source: keep?.source))
        for e in other { plan.pieces += leftovers(e, minus: new, text: text) }
        return plan
    }

    private static func leftovers(_ e: PageHighlight, minus new: IndexSet, text: PageText) -> [Piece] {
        let rest = text.solid(e.chars.subtracting(new))
        let runs = text.runs(rest).map { rest.intersection(IndexSet(integersIn: $0)) }.filter(text.hasWord)
        guard let largest = runs.indices.max(by: { runs[$0].count < runs[$1].count }) else { return [] }
        let h = e.highlight
        return runs.indices.map { i in
            i == largest
                ? Piece(chars: runs[i], color: h.highlightColor, note: h.note, id: h.id, created: h.created, source: h.source)
                : Piece(chars: runs[i], color: h.highlightColor, created: h.created, source: h.source)
        }
    }

    /// Replays a page's highlights oldest first through `plan`, so overlapping ones are merged or trimmed
    /// the same way as if they had been made after this change. With `snap`, each is first widened to whole words.
    /// Returns only what changes.
    public static func tidy(_ items: [PageHighlight], text: PageText, snap: Bool = true) -> PagePlan {
        var state: [PageHighlight] = []
        var temp = 0
        let ordered = items.filter { $0.highlight.highlightColor != .noteOnly && !$0.chars.isEmpty }
            .sorted { ($0.highlight.created, $0.highlight.id) < ($1.highlight.created, $1.highlight.id) }
        for item in ordered {
            var current = item
            current.chars = text.solid(snap ? text.snap(item.chars) : item.chars)
            let p = plan(current.chars, color: current.highlight.highlightColor, existing: state + [current], text: text)
            if p.isEmpty {
                state.append(current)
                continue
            }
            let gone = Set(p.removed.map(\.id))
            state.removeAll { gone.contains($0.highlight.id) }
            for piece in p.pieces {
                let h = Highlight(id: piece.id ?? "tmp-\(temp)", page: item.highlight.page, rects: [], text: "", color: piece.color,
                                  note: piece.note, created: piece.created ?? item.highlight.created, source: piece.source ?? "app")
                if piece.id == nil { temp += 1 }
                state.append(PageHighlight(h, chars: piece.chars))
            }
        }

        let originals = Dictionary(ordered.map { ($0.highlight.id, $0) }, uniquingKeysWith: { a, _ in a })
        var unchanged = Set<String>()
        for s in state {
            if let o = originals[s.highlight.id], text.solid(o.chars) == s.chars,
               o.highlight.color == s.highlight.color, o.highlight.note == s.highlight.note {
                unchanged.insert(s.highlight.id)
            }
        }
        let removed = ordered.map(\.highlight).filter { !unchanged.contains($0.id) }
        let pieces = state.filter { !unchanged.contains($0.highlight.id) }.map { s in
            Piece(chars: s.chars, color: s.highlight.highlightColor, note: s.highlight.note,
                  id: s.highlight.id.hasPrefix("tmp-") ? nil : s.highlight.id, created: s.highlight.created, source: s.highlight.source)
        }
        return PagePlan(removed: removed, pieces: pieces)
    }
}
