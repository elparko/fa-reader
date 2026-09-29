import AppKit

/// Incremental Markdown syntax highlighting for the source editor.
///
/// Only the edited paragraph is restyled on each keystroke. Fenced code blocks and
/// front matter are tracked as ranges so a local edit knows whether it's inside
/// code; any edit that could open or close one triggers a full pass instead.
final class MarkdownHighlighter: NSObject, NSTextStorageDelegate {

    var fontSize: CGFloat { didSet { buildAttributes() } }
    /// Set by the editor when the text being replaced contained a fence.
    var forceFullPass = false

    private(set) var baseAttributes: [NSAttributedString.Key: Any] = [:]
    private var baseFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    private var codeRanges: [NSRange] = []
    private var traitCache: [NSFont: [Int: NSFont]] = [:]

    init(fontSize: CGFloat) {
        self.fontSize = fontSize
        super.init()
        buildAttributes()
    }

    private func buildAttributes() {
        baseFont = FontCache.shared.font(size: editorSize, mono: true)
        let ps = NSMutableParagraphStyle()
        ps.lineHeightMultiple = 1.18
        ps.defaultTabInterval = round(editorSize * 0.6 * 4)
        ps.tabStops = []
        baseAttributes = [.font: baseFont, .foregroundColor: NSColor.textColor, .paragraphStyle: ps]
        traitCache.removeAll()
    }

    private var editorSize: CGFloat { max(9, fontSize - 1) }

    // MARK: - NSTextStorageDelegate

    func textStorage(_ ts: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        let ns = ts.string as NSString
        let para = ns.paragraphRange(for: editedRange)
        var full = forceFullPass || !shiftCodeRanges(edit: editedRange, delta: delta)
        forceFullPass = false
        if !full { full = touchesCodeBoundary(para) || containsFence(ns, para) }
        if full {
            highlightAll(ts)
        } else {
            highlight(ts, range: para)
        }
    }

    func highlightAll(_ ts: NSTextStorage) {
        let ns = ts.string as NSString
        codeRanges = Self.findCodeRanges(ns)
        highlight(ts, range: NSRange(location: 0, length: ns.length))
    }

    // MARK: - Code range bookkeeping

    /// Moves code ranges to account for an edit. Returns false if an edit cut across a range boundary.
    private func shiftCodeRanges(edit: NSRange, delta: Int) -> Bool {
        let oldEnd = edit.location + edit.length - delta // end of the replaced text, in old coordinates
        for i in codeRanges.indices {
            let r = codeRanges[i]
            if NSMaxRange(r) < edit.location { continue }
            if r.location > oldEnd {
                codeRanges[i].location += delta
            } else if r.location < edit.location && oldEnd < NSMaxRange(r) {
                codeRanges[i].length += delta
            } else {
                return false
            }
        }
        return true
    }

    private func touchesCodeBoundary(_ para: NSRange) -> Bool {
        for r in codeRanges where NSIntersectionRange(r, para).length > 0 || r.location == para.location {
            if NSLocationInRange(r.location, para) || NSLocationInRange(NSMaxRange(r) - 1, para) { return true }
        }
        return false
    }

    private func containsFence(_ ns: NSString, _ para: NSRange) -> Bool {
        var found = false
        ns.enumerateSubstrings(in: para, options: [.byLines, .substringNotRequired]) { _, line, _, stop in
            if Self.fenceInfo(ns, line) != nil || (ns.hasPrefix("---") && Self.isFrontMatterFence(ns, line)) {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    private func codeRange(at loc: Int) -> NSRange? {
        var lo = 0, hi = codeRanges.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let r = codeRanges[mid]
            if loc < r.location { hi = mid - 1 } else if loc >= NSMaxRange(r) { lo = mid + 1 } else { return r }
        }
        return nil
    }

    /// Returns (fence char, run length, has info string) if the line is a code fence.
    private static func fenceInfo(_ ns: NSString, _ line: NSRange) -> (UInt16, Int, Bool)? {
        var i = line.location
        let end = NSMaxRange(line)
        while i < end, ns.character(at: i) == 0x20 || ns.character(at: i) == 0x09 { i += 1 }
        guard i < end else { return nil }
        let c = ns.character(at: i)
        guard c == 0x60 || c == 0x7E else { return nil } // ` or ~
        var n = 0
        while i < end, ns.character(at: i) == c { n += 1; i += 1 }
        guard n >= 3 else { return nil }
        var info = false
        while i < end {
            let ch = ns.character(at: i)
            if c == 0x60 && ch == 0x60 { return nil } // backtick fences can't have backticks in the info string
            if ch != 0x20 && ch != 0x09 && ch != 0x0D { info = true }
            i += 1
        }
        return (c, n, info)
    }

    private static func isFrontMatterFence(_ ns: NSString, _ line: NSRange) -> Bool {
        let s = ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
        return s == "---" || s == "..."
    }

    /// Range of a YAML front matter block at the top of the document, if closed.
    static func frontMatterRange(_ ns: NSString) -> NSRange? {
        guard ns.length >= 7, ns.hasPrefix("---") else { return nil }
        let first = ns.lineRange(for: NSRange(location: 0, length: 0))
        guard isFrontMatterFence(ns, first), ns.substring(with: first).trimmingCharacters(in: .whitespacesAndNewlines) == "---" else { return nil }
        var loc = NSMaxRange(first)
        while loc < ns.length {
            let line = ns.lineRange(for: NSRange(location: loc, length: 0))
            if isFrontMatterFence(ns, line) {
                return loc == NSMaxRange(first) ? nil : NSRange(location: 0, length: NSMaxRange(line))
            }
            loc = NSMaxRange(line)
        }
        return nil
    }

    static func findCodeRanges(_ ns: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var start = 0
        if let fm = frontMatterRange(ns) {
            ranges.append(fm)
            start = NSMaxRange(fm)
        }
        var open: (start: Int, char: UInt16, count: Int)?
        ns.enumerateSubstrings(in: NSRange(location: start, length: ns.length - start), options: [.byLines, .substringNotRequired]) { _, line, enclosing, _ in
            if let o = open {
                if let f = fenceInfo(ns, line), f.0 == o.char, f.1 >= o.count, !f.2 {
                    ranges.append(NSRange(location: o.start, length: NSMaxRange(enclosing) - o.start))
                    open = nil
                }
            } else if let f = fenceInfo(ns, line) {
                open = (line.location, f.0, f.1)
            }
        }
        if let o = open { ranges.append(NSRange(location: o.start, length: ns.length - o.start)) }
        return ranges
    }

    // MARK: - Styling

    private func highlight(_ ts: NSTextStorage, range: NSRange) {
        guard range.length > 0 else { return }
        let ns = ts.string as NSString
        ts.setAttributes(baseAttributes, range: range)
        var protected = IndexSet()

        let frontMatterEnd = codeRanges.first.flatMap { $0.location == 0 && ns.hasPrefix("---") ? NSMaxRange($0) : nil } ?? 0
        ns.enumerateSubstrings(in: range, options: [.byLines, .substringNotRequired]) { _, line, _, _ in
            if self.codeRange(at: line.location) != nil {
                let color: NSColor
                if line.location < frontMatterEnd {
                    color = Self.isFrontMatterFence(ns, line) ? Theme.syntaxMarker : Theme.syntaxQuote
                } else {
                    color = Self.fenceInfo(ns, line) != nil ? Theme.syntaxMarker : Theme.syntaxCode
                }
                ts.addAttribute(.foregroundColor, value: color, range: line)
                protected.insert(integersIn: line.location..<NSMaxRange(line))
                return
            }
            self.styleLine(ts, ns, line, &protected)
        }
        styleInline(ts, ns, range, &protected)
    }

    private func styleLine(_ ts: NSTextStorage, _ ns: NSString, _ line: NSRange, _ protected: inout IndexSet) {
        let end = NSMaxRange(line)
        var i = line.location
        while i < end, ns.character(at: i) == 0x20 { i += 1 }
        guard i < end else { return }
        let c = ns.character(at: i)
        let marker = Theme.syntaxMarker

        // ATX heading
        if c == 0x23 { // #
            var n = 0
            var j = i
            while j < end, ns.character(at: j) == 0x23 { n += 1; j += 1 }
            if n <= 6 && (j == end || ns.character(at: j) == 0x20 || ns.character(at: j) == 0x09) {
                let scale: CGFloat = n == 1 ? 1.3 : n == 2 ? 1.15 : 1.0
                ts.addAttribute(.font, value: FontCache.shared.font(size: editorSize * scale, weight: .bold, mono: true), range: line)
                ts.addAttribute(.foregroundColor, value: marker, range: NSRange(location: i, length: n))
                return
            }
        }

        // Thematic break / setext underline
        if c == 0x2D || c == 0x2A || c == 0x5F || c == 0x3D { // - * _ =
            var count = 0
            var j = i
            var only = true
            while j < end {
                let ch = ns.character(at: j)
                if ch == c { count += 1 } else if ch != 0x20 && ch != 0x09 && ch != 0x0D { only = false; break }
                j += 1
            }
            if only && (count >= 3 || (c == 0x3D && count >= 1)) {
                ts.addAttribute(.foregroundColor, value: marker, range: line)
                protected.insert(integersIn: line.location..<end)
                return
            }
        }

        // Blockquote
        if c == 0x3E { // >
            ts.addAttribute(.foregroundColor, value: Theme.syntaxQuote, range: line)
            var j = i
            while j < end, ns.character(at: j) == 0x3E || ns.character(at: j) == 0x20 {
                if ns.character(at: j) == 0x3E { ts.addAttribute(.foregroundColor, value: marker, range: NSRange(location: j, length: 1)) }
                j += 1
            }
            return
        }

        // List item: -, *, + or 1. / 1)
        var j = i
        var isList = false
        if c == 0x2D || c == 0x2A || c == 0x2B {
            if j + 1 == end || ns.character(at: j + 1) == 0x20 || ns.character(at: j + 1) == 0x09 { isList = true; j += 1 }
        } else if c >= 0x30 && c <= 0x39 {
            var k = j
            while k < end, k - j < 9, ns.character(at: k) >= 0x30 && ns.character(at: k) <= 0x39 { k += 1 }
            if k < end, ns.character(at: k) == 0x2E || ns.character(at: k) == 0x29,
               k + 1 == end || ns.character(at: k + 1) == 0x20 || ns.character(at: k + 1) == 0x09 {
                isList = true
                j = k + 1
            }
        }
        if isList {
            ts.addAttribute(.foregroundColor, value: Theme.syntaxListMarker, range: NSRange(location: i, length: j - i))
            // Task box
            var k = j
            while k < end, ns.character(at: k) == 0x20 { k += 1 }
            if k + 2 < end, ns.character(at: k) == 0x5B, ns.character(at: k + 2) == 0x5D {
                let m = ns.character(at: k + 1)
                if m == 0x20 || m == 0x78 || m == 0x58 {
                    ts.addAttribute(.foregroundColor, value: Theme.syntaxListMarker, range: NSRange(location: k, length: 3))
                    if m != 0x20 {
                        ts.addAttribute(.foregroundColor, value: Theme.syntaxQuote, range: NSRange(location: k + 3, length: end - k - 3))
                    }
                }
            }
            return
        }

        // Table rows: dim the pipes, and the whole delimiter row
        if c == 0x7C || ns.range(of: "|", options: .literal, range: line).location != NSNotFound {
            let s = ns.substring(with: line)
            if Self.tableDelimiterRegex.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil {
                ts.addAttribute(.foregroundColor, value: marker, range: line)
                protected.insert(integersIn: line.location..<end)
                return
            }
            if c == 0x7C {
                var k = line.location
                while k < end {
                    if ns.character(at: k) == 0x7C { ts.addAttribute(.foregroundColor, value: marker, range: NSRange(location: k, length: 1)) }
                    k += 1
                }
            }
        }

        // Link reference definition: [id]: url
        if c == 0x5B, Self.refDefRegex.firstMatch(in: ns as String, range: line) != nil {
            ts.addAttribute(.foregroundColor, value: marker, range: line)
            protected.insert(integersIn: line.location..<end)
        }
    }

    private static func re(_ p: String, _ o: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: o)
    }

    private static let tableDelimiterRegex = re("^\\s*\\|?\\s*:?-+:?\\s*(\\|\\s*:?-+:?\\s*)+\\|?\\s*$")
    private static let refDefRegex = re("^ {0,3}\\[[^\\]]+\\]:\\s*\\S+")
    private static let codeSpanRegex = re("(`+)(?=[^`\\n])[^\\n]*?[^`\\n]?\\1(?!`)")
    private static let htmlRegex = re("<!--[^\\n]*?-->|</?[A-Za-z][A-Za-z0-9-]*(?:\\s[^<>\\n]*)?/?>")
    private static let linkRegex = re("(!?)\\[((?:[^\\[\\]\\n]|\\[[^\\]\\n]*\\])*)\\]\\(([^()\\s]*(?:\\([^()\\s]*\\))?[^()\\s]*)(\\s+\"[^\"\\n]*\")?\\)")
    private static let refLinkRegex = re("\\[([^\\[\\]\\n]+)\\]\\[([^\\]\\n]*)\\]")
    private static let wikiRegex = re("\\[\\[[^\\]\\n]+\\]\\]")
    private static let autolinkRegex = re("<(?:https?|mailto|ftp):[^>\\s]+>|\\bhttps?://[^\\s<>()\\[\\]]*[^\\s<>()\\[\\].,;:!?'\"*_~]")
    private static let boldRegex = re("(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)\\1")
    private static let italicStarRegex = re("(?<![*\\\\\\w])\\*(?![\\s*])(.+?)(?<![\\s*\\\\])\\*(?!\\*)")
    private static let italicUnderRegex = re("(?<![_\\w])_(?![\\s_])(.+?)(?<![\\s_])_(?![_\\w])")
    private static let strikeRegex = re("~~(?=\\S)(.+?)(?<=\\S)~~")

    private func styleInline(_ ts: NSTextStorage, _ ns: NSString, _ range: NSRange, _ protected: inout IndexSet) {
        let s = ns as String
        let marker = Theme.syntaxMarker
        func free(_ r: NSRange) -> Bool { !protected.intersects(integersIn: r.location..<NSMaxRange(r)) }
        func protect(_ r: NSRange) { protected.insert(integersIn: r.location..<NSMaxRange(r)) }

        Self.codeSpanRegex.enumerateMatches(in: s, range: range) { m, _, _ in
            guard let m, free(m.range) else { return }
            let tick = m.range(at: 1).length
            ts.addAttribute(.foregroundColor, value: Theme.syntaxCode, range: m.range)
            ts.addAttribute(.foregroundColor, value: marker, range: NSRange(location: m.range.location, length: tick))
            ts.addAttribute(.foregroundColor, value: marker, range: NSRange(location: NSMaxRange(m.range) - tick, length: tick))
            protect(m.range)
        }
        Self.htmlRegex.enumerateMatches(in: s, range: range) { m, _, _ in
            guard let m, free(m.range) else { return }
            ts.addAttribute(.foregroundColor, value: marker, range: m.range)
            protect(m.range)
        }
        Self.wikiRegex.enumerateMatches(in: s, range: range) { m, _, _ in
            guard let m, free(m.range) else { return }
            ts.addAttribute(.foregroundColor, value: Theme.syntaxLink, range: m.range)
            protect(m.range)
        }
        Self.linkRegex.enumerateMatches(in: s, range: range) { m, _, _ in
            guard let m, free(m.range) else { return }
            ts.addAttribute(.foregroundColor, value: marker, range: m.range)
            let text = m.range(at: 2)
            if text.length > 0 { ts.addAttribute(.foregroundColor, value: Theme.syntaxLink, range: text) }
            // Only the URL part is protected; the link text may contain emphasis.
            protect(NSRange(location: NSMaxRange(text), length: NSMaxRange(m.range) - NSMaxRange(text)))
        }
        Self.refLinkRegex.enumerateMatches(in: s, range: range) { m, _, _ in
            guard let m, free(m.range) else { return }
            ts.addAttribute(.foregroundColor, value: marker, range: m.range)
            ts.addAttribute(.foregroundColor, value: Theme.syntaxLink, range: m.range(at: 1))
        }
        Self.autolinkRegex.enumerateMatches(in: s, range: range) { m, _, _ in
            guard let m, free(m.range) else { return }
            ts.addAttribute(.foregroundColor, value: Theme.syntaxLink, range: m.range)
            protect(m.range)
        }
        let boldBit = 1, italicBit = 2
        Self.boldRegex.enumerateMatches(in: s, range: range) { m, _, _ in
            guard let m, free(m.range) else { return }
            self.addTrait(ts, m.range(at: 2), boldBit)
            self.dimMarkers(ts, m.range, m.range(at: 1).length)
        }
        for regex in [Self.italicStarRegex, Self.italicUnderRegex] {
            regex.enumerateMatches(in: s, range: range) { m, _, _ in
                guard let m, free(m.range) else { return }
                self.addTrait(ts, m.range(at: 1), italicBit)
                self.dimMarkers(ts, m.range, 1)
            }
        }
        Self.strikeRegex.enumerateMatches(in: s, range: range) { m, _, _ in
            guard let m, free(m.range) else { return }
            ts.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: m.range(at: 1))
            self.dimMarkers(ts, m.range, 2)
        }
    }

    private func dimMarkers(_ ts: NSTextStorage, _ r: NSRange, _ n: Int) {
        ts.addAttribute(.foregroundColor, value: Theme.syntaxMarker, range: NSRange(location: r.location, length: n))
        ts.addAttribute(.foregroundColor, value: Theme.syntaxMarker, range: NSRange(location: NSMaxRange(r) - n, length: n))
    }

    private func addTrait(_ ts: NSTextStorage, _ r: NSRange, _ bit: Int) {
        ts.enumerateAttribute(.font, in: r) { value, sub, _ in
            guard let f = value as? NSFont else { return }
            ts.addAttribute(.font, value: self.font(f, adding: bit), range: sub)
        }
    }

    private func font(_ f: NSFont, adding bit: Int) -> NSFont {
        if let cached = traitCache[f]?[bit] { return cached }
        var traits = f.fontDescriptor.symbolicTraits
        if bit & 1 != 0 { traits.insert(.bold) }
        if bit & 2 != 0 { traits.insert(.italic) }
        let result = NSFont(descriptor: f.fontDescriptor.withSymbolicTraits(traits), size: f.pointSize) ?? f
        traitCache[f, default: [:]][bit] = result
        return result
    }
}
