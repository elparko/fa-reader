import AppKit
import FACore
import md4c

extension NSAttributedString.Key {
    /// UTF-8 byte offset (in the source) of the character between `[` and `]` of a task item.
    static let markyTask = NSAttributedString.Key("MarkyTaskOffset")
}

struct RenderedMarkdown {
    let text: NSAttributedString
    /// Heading slug -> character location, for `#anchor` links.
    let anchors: [String: Int]
    /// Remote images that weren't cached yet.
    let pendingImages: [URL]
}

/// Converts Markdown to a native NSAttributedString by driving the md4c C parser.
/// Block structure maps onto TextKit primitives: NSTextBlock for quotes, code and
/// heading rules, NSTextTable for tables, tab stops for list markers.
final class MarkdownRenderer {

    static func render(_ source: String, baseURL: URL?, fontSize: CGFloat, maxImageWidth: CGFloat) -> RenderedMarkdown {
        let r = MarkdownRenderer(baseURL: baseURL, size: fontSize, maxImageWidth: maxImageWidth)
        var src = source
        src.withUTF8 { buf in
            guard let base = buf.baseAddress else { return }
            var start = 0
            if let fm = Self.frontMatterEnd(buf) {
                r.renderFrontMatter(String(decoding: UnsafeBufferPointer(rebasing: buf[fm.contentStart..<fm.contentEnd]), as: UTF8.self))
                start = fm.bodyStart
            }
            r.byteOffset = start
            r.parse(base.advanced(by: start), count: buf.count - start)
        }
        r.closeParagraph()
        return RenderedMarkdown(text: r.out, anchors: r.anchors, pendingImages: r.pendingImages)
    }

    // MARK: - State

    private let out = NSMutableAttributedString()
    private let baseURL: URL?
    private let size: CGFloat
    private let maxImageWidth: CGFloat
    private let fonts = FontCache.shared
    private var byteOffset = 0

    private var anchors: [String: Int] = [:]
    private var slugCounts: [String: Int] = [:]
    private var pendingImages: [URL] = []

    private enum ParaKind: Equatable {
        case body, heading(Int), code, frontMatter, cell(header: Bool), rule
        var isCell: Bool { if case .cell = self { return true } else { return false } }
    }

    private var paraStart: Int?
    private var paraKind: ParaKind = .body
    private var paraBlock: NSTextBlock?     // code block / table cell / heading rule / hr
    private var paraIndentBlock: NSTextBlock? // wraps paraBlock when it sits inside a list
    private var paraTall = false            // holds a large image: no extra line height
    private var paraFirstInItem = false
    private var paraImplicit = false
    private var paraAlign: NSTextAlignment = .natural

    private final class ListState {
        let ordered: Bool, tight: Bool, delimiter: String
        var next: Int
        init(ordered: Bool, tight: Bool, start: Int, delimiter: String) {
            self.ordered = ordered; self.tight = tight; self.next = start; self.delimiter = delimiter
        }
    }
    private final class ItemState {
        let marker: String
        let task: (checked: Bool, offset: Int)?
        var markerPending = true
        init(marker: String, task: (checked: Bool, offset: Int)?) { self.marker = marker; self.task = task }
    }
    private struct QuoteState { let blocks: [NSTextBlock]; let listDepth: Int }

    private var lists: [ListState] = []
    private var items: [ItemState] = []
    private var quotes: [QuoteState] = []

    private var last: (range: NSRange, style: NSParagraphStyle)?
    private var lastAdjustable = false

    private var table: NSTextTable?
    private var blockCounter = 0
    private var tableRow = -1
    private var tableCol = 0
    private var inTableHead = false
    private var cellAlign: NSTextAlignment = .natural

    // Inline state (md spans + raw inline HTML, which is reset per paragraph)
    private var strong = 0, em = 0, codeSpan = 0, del = 0
    private var hStrong = 0, hEm = 0, hCode = 0, hDel = 0, hLinks = 0
    private var links: [URL?] = []
    private var imageDepth = 0
    private var imageAlt = ""
    private var imageSrcs: [String] = []
    private var headingText: String?
    private var htmlBlock: String?
    private var htmlCenter = false
    private var htmlNextKind: ParaKind?
    private var attrsCache: [NSAttributedString.Key: Any]?

    private init(baseURL: URL?, size: CGFloat, maxImageWidth: CGFloat) {
        self.baseURL = baseURL
        self.size = size
        self.maxImageWidth = maxImageWidth
    }

    private var blockSpacing: CGFloat { round(size * 0.85) }
    private var tightSpacing: CGFloat { round(size * 0.2) }
    private var indentStep: CGFloat { round(size * 1.8) }
    private var listDepthInQuote: Int { lists.count - (quotes.last?.listDepth ?? 0) }
    private var inTightItem: Bool { !items.isEmpty && (lists.last?.tight ?? false) }

    // MARK: - md4c glue

    private func parse(_ text: UnsafePointer<UInt8>, count: Int) {
        var parser = MD_PARSER()
        parser.abi_version = 0
        parser.flags = UInt32(MD_FLAG_TABLES | MD_FLAG_STRIKETHROUGH | MD_FLAG_TASKLISTS
                              | MD_FLAG_PERMISSIVEURLAUTOLINKS | MD_FLAG_PERMISSIVEEMAILAUTOLINKS
                              | MD_FLAG_PERMISSIVEWWWAUTOLINKS | MD_FLAG_WIKILINKS)
        parser.enter_block = { type, detail, ud in
            Unmanaged<MarkdownRenderer>.fromOpaque(ud!).takeUnretainedValue().enterBlock(type, detail); return 0
        }
        parser.leave_block = { type, _, ud in
            Unmanaged<MarkdownRenderer>.fromOpaque(ud!).takeUnretainedValue().leaveBlock(type); return 0
        }
        parser.enter_span = { type, detail, ud in
            Unmanaged<MarkdownRenderer>.fromOpaque(ud!).takeUnretainedValue().enterSpan(type, detail); return 0
        }
        parser.leave_span = { type, _, ud in
            Unmanaged<MarkdownRenderer>.fromOpaque(ud!).takeUnretainedValue().leaveSpan(type); return 0
        }
        parser.text = { type, text, size, ud in
            Unmanaged<MarkdownRenderer>.fromOpaque(ud!).takeUnretainedValue().text(type, text!, Int(size)); return 0
        }
        let ud = Unmanaged.passUnretained(self).toOpaque()
        text.withMemoryRebound(to: CChar.self, capacity: count) { p in
            _ = md_parse(p, MD_SIZE(count), &parser, ud)
        }
    }

    private static func str(_ p: UnsafePointer<CChar>, _ n: Int) -> String {
        String(decoding: UnsafeRawBufferPointer(start: p, count: n), as: UTF8.self)
    }

    private func attr(_ a: MD_ATTRIBUTE) -> String {
        guard let text = a.text, a.size > 0 else { return "" }
        var result = ""
        var i = 0
        while Int(a.substr_offsets[i]) < Int(a.size) {
            let off = Int(a.substr_offsets[i]), end = Int(a.substr_offsets[i + 1])
            switch a.substr_types[i] {
            case MD_TEXT_ENTITY: result += Self.decodeEntity(text + off, end - off)
            case MD_TEXT_NULLCHAR: result += "\u{FFFD}"
            default: result += Self.str(text + off, end - off)
            }
            i += 1
        }
        return result
    }

    static func decodeEntity(_ p: UnsafePointer<CChar>, _ n: Int) -> String {
        if n > 3 && p[1] == 0x23 /* # */ {
            var cp: UInt32 = 0
            let hex = p[2] == 0x78 || p[2] == 0x58
            for i in (hex ? 3 : 2)..<(n - 1) {
                let c = UInt32(UInt8(bitPattern: p[i]))
                let v: UInt32 = c >= 0x61 ? c &- 0x57 : c >= 0x41 ? c &- 0x37 : c &- 0x30
                cp = cp &* (hex ? 16 : 10) &+ v
            }
            guard cp != 0, let scalar = Unicode.Scalar(cp) else { return "\u{FFFD}" }
            return String(Character(scalar))
        }
        if let e = entity_lookup(p, n) {
            var s = ""
            if let a = Unicode.Scalar(e.pointee.codepoints.0) { s.unicodeScalars.append(a) }
            if e.pointee.codepoints.1 != 0, let b = Unicode.Scalar(e.pointee.codepoints.1) { s.unicodeScalars.append(b) }
            return s
        }
        return str(p, n)
    }

    static func decodeEntities(in s: String) -> String {
        guard s.contains("&") else { return s }
        var result = ""
        var rest = Substring(s)
        while let amp = rest.firstIndex(of: "&") {
            result += rest[..<amp]
            let tail = rest[amp...]
            if let semi = tail.prefix(40).firstIndex(of: ";") {
                var ent = String(tail[...semi])
                let decoded = ent.withUTF8 { b in
                    b.withMemoryRebound(to: CChar.self) { decodeEntity($0.baseAddress!, $0.count) }
                }
                result += decoded
                rest = tail[tail.index(after: semi)...]
            } else {
                result += "&"
                rest = tail.dropFirst()
            }
        }
        return result + rest
    }

    // MARK: - Blocks

    private func enterBlock(_ type: MD_BLOCKTYPE, _ detail: UnsafeMutableRawPointer?) {
        switch type {
        case MD_BLOCK_QUOTE:
            closeImplicit()
            let b = makeBlock()
            b.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
            b.setBorderColor(Theme.quoteBar, for: .minX)
            b.setWidth(round(size * 0.9), type: .absoluteValueType, for: .padding, edge: .minX)
            b.setWidth(blockSpacing, type: .absoluteValueType, for: .margin, edge: .maxY)
            quotes.append(QuoteState(blocks: (indentBlock().map { [$0] } ?? []) + [b], listDepth: lists.count))

        case MD_BLOCK_UL:
            closeImplicit()
            let d = detail!.assumingMemoryBound(to: MD_BLOCK_UL_DETAIL.self).pointee
            lists.append(ListState(ordered: false, tight: d.is_tight != 0, start: 0, delimiter: ""))

        case MD_BLOCK_OL:
            closeImplicit()
            let d = detail!.assumingMemoryBound(to: MD_BLOCK_OL_DETAIL.self).pointee
            let delim = String(UnicodeScalar(UInt8(bitPattern: d.mark_delimiter)))
            lists.append(ListState(ordered: true, tight: d.is_tight != 0, start: Int(d.start), delimiter: delim))

        case MD_BLOCK_LI:
            closeImplicit()
            let d = detail!.assumingMemoryBound(to: MD_BLOCK_LI_DETAIL.self).pointee
            var marker = "•"
            if let list = lists.last {
                if list.ordered {
                    marker = "\(list.next)\(list.delimiter)"
                    list.next += 1
                } else {
                    marker = ["•", "◦", "▪"][(lists.count - 1) % 3]
                }
            }
            let task = d.is_task != 0
                ? (checked: d.task_mark != 0x20, offset: Int(d.task_mark_offset) + byteOffset) : nil
            items.append(ItemState(marker: marker, task: task))

        case MD_BLOCK_HR:
            closeImplicit()
            let b = makeBlock()
            b.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
            b.setBorderColor(Theme.rule, for: .maxY)
            b.setWidth(round(size * 0.6), type: .absoluteValueType, for: .margin, edge: .minY)
            b.setWidth(round(size * 1.2), type: .absoluteValueType, for: .margin, edge: .maxY)
            openParagraph(.rule, block: b)
            closeParagraph()

        case MD_BLOCK_H:
            closeImplicit()
            let level = Int(detail!.assumingMemoryBound(to: MD_BLOCK_H_DETAIL.self).pointee.level)
            var b: NSTextBlock?
            if level <= 2 {
                let rb = makeBlock()
                rb.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
                rb.setBorderColor(Theme.rule, for: .maxY)
                rb.setWidth(round(size * 0.3), type: .absoluteValueType, for: .padding, edge: .maxY)
                rb.setWidth(out.length == 0 ? 0 : round(size * 1.1), type: .absoluteValueType, for: .margin, edge: .minY)
                rb.setWidth(round(size * 0.8), type: .absoluteValueType, for: .margin, edge: .maxY)
                b = rb
            }
            openParagraph(.heading(level), block: b)
            headingText = ""

        case MD_BLOCK_CODE:
            closeImplicit()
            openParagraph(.code, block: makeCodeBlock())

        case MD_BLOCK_HTML:
            closeImplicit()
            htmlBlock = ""

        case MD_BLOCK_P:
            closeImplicit()
            openParagraph(.body)

        case MD_BLOCK_TABLE:
            closeImplicit()
            let d = detail!.assumingMemoryBound(to: MD_BLOCK_TABLE_DETAIL.self).pointee
            let t = NSTextTable()
            t.numberOfColumns = max(1, Int(d.col_count))
            t.collapsesBorders = false
            t.hidesEmptyCells = false
            t.layoutAlgorithm = .automaticLayoutAlgorithm
            // Cells draw their right and bottom edges; the table draws top and left,
            // so every rule is exactly one line wide.
            t.setWidth(1, type: .absoluteValueType, for: .border, edge: .minX)
            t.setWidth(1, type: .absoluteValueType, for: .border, edge: .minY)
            t.setBorderColor(Theme.tableBorder)
            t.setWidth(blockSpacing, type: .absoluteValueType, for: .margin, edge: .maxY)
            // NSTextTable can't be nested inside other text blocks (AppKit throws while
            // drawing), so a table in a list or quote is indented with its own margin.
            let quoteIndent = CGFloat(quotes.count) * (3 + round(size * 0.9))
            t.setWidth(CGFloat(lists.count) * indentStep + quoteIndent, type: .absoluteValueType, for: .margin, edge: .minX)
            table = t
            tableRow = -1

        case MD_BLOCK_THEAD: inTableHead = true
        case MD_BLOCK_TBODY: inTableHead = false
        case MD_BLOCK_TR:
            tableRow += 1
            tableCol = 0

        case MD_BLOCK_TH, MD_BLOCK_TD:
            guard let t = table else { break }
            let align = detail!.assumingMemoryBound(to: MD_BLOCK_TD_DETAIL.self).pointee.align
            let cell = NSTextTableBlock(table: t, startingRow: tableRow, rowSpan: 1, startingColumn: tableCol, columnSpan: 1)
            cell.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxX)
            cell.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
            cell.setBorderColor(Theme.tableBorder)
            cell.setWidth(round(size * 0.35), type: .absoluteValueType, for: .padding, edge: .minY)
            cell.setWidth(round(size * 0.35), type: .absoluteValueType, for: .padding, edge: .maxY)
            cell.setWidth(round(size * 0.7), type: .absoluteValueType, for: .padding, edge: .minX)
            cell.setWidth(round(size * 0.7), type: .absoluteValueType, for: .padding, edge: .maxX)
            let header = type == MD_BLOCK_TH || inTableHead
            if header { cell.backgroundColor = Theme.tableHeaderBackground }
            switch align {
            case MD_ALIGN_CENTER: cellAlign = .center
            case MD_ALIGN_RIGHT: cellAlign = .right
            case MD_ALIGN_LEFT: cellAlign = .left
            default: cellAlign = .natural
            }
            openParagraph(.cell(header: header), block: cell)

        default:
            break
        }
    }

    private func leaveBlock(_ type: MD_BLOCKTYPE) {
        switch type {
        case MD_BLOCK_QUOTE:
            closeImplicit()
            setLastSpacing(0)
            quotes.removeLast()
        case MD_BLOCK_UL, MD_BLOCK_OL:
            closeImplicit()
            lists.removeLast()
            setLastSpacing(inTightItem ? tightSpacing : blockSpacing)
        case MD_BLOCK_LI:
            if let item = items.last, item.markerPending {
                openParagraph(.body) // empty item: still show its marker
            }
            closeImplicit()
            closeParagraph()
            items.removeLast()
        case MD_BLOCK_H:
            let loc = paraStart ?? out.length
            let text = headingText ?? ""
            closeParagraph()
            headingText = nil
            addAnchor(text, at: loc)
        case MD_BLOCK_CODE, MD_BLOCK_P:
            closeParagraph()
        case MD_BLOCK_HTML:
            let html = htmlBlock ?? ""
            htmlBlock = nil
            renderHTMLBlock(html)
        case MD_BLOCK_TH, MD_BLOCK_TD:
            closeParagraph()
            cellAlign = .natural
            tableCol += 1
        case MD_BLOCK_TABLE:
            table = nil
        default:
            break
        }
    }

    /// TextKit 1 only lays out and draws a plain NSTextBlock correctly when it has an explicit width.
    private static func fullWidthBlock() -> NSTextBlock {
        let b = NSTextBlock()
        b.setValue(100, type: .percentageValueType, for: .width)
        return b
    }

    /// TextKit treats blocks with identical settings as one, so adjacent blocks
    /// (two code blocks in a row) would merge; an invisible difference keeps them apart.
    private func makeBlock() -> NSTextBlock {
        let b = Self.fullWidthBlock()
        blockCounter += 1
        b.setWidth(blockCounter % 2 == 0 ? 0 : 0.01, type: .absoluteValueType, for: .margin, edge: .minY)
        return b
    }

    /// Margins on a full-width block misplace its background, so indentation inside
    /// lists comes from a transparent outer block's padding instead.
    private func indentBlock() -> NSTextBlock? {
        guard listDepthInQuote > 0 else { return nil }
        let b = makeBlock()
        b.setWidth(CGFloat(listDepthInQuote) * indentStep, type: .absoluteValueType, for: .padding, edge: .minX)
        return b
    }

    private func makeCodeBlock() -> NSTextBlock {
        let b = makeBlock()
        b.backgroundColor = Theme.codeBlockBackground
        b.setWidth(round(size * 0.8), type: .absoluteValueType, for: .padding, edge: .minY)
        b.setWidth(round(size * 0.8), type: .absoluteValueType, for: .padding, edge: .maxY)
        b.setWidth(round(size * 1.0), type: .absoluteValueType, for: .padding, edge: .minX)
        b.setWidth(round(size * 1.0), type: .absoluteValueType, for: .padding, edge: .maxX)
        b.setWidth(blockSpacing, type: .absoluteValueType, for: .margin, edge: .maxY)
        return b
    }

    // MARK: - Paragraphs

    private func openParagraph(_ kind: ParaKind, block: NSTextBlock? = nil, implicit: Bool = false) {
        if paraStart != nil { closeParagraph() }
        paraStart = out.length
        paraKind = kind
        paraBlock = block
        if case .cell = kind { paraIndentBlock = nil } else { paraIndentBlock = block == nil ? nil : indentBlock() }
        paraTall = false
        paraImplicit = implicit
        paraFirstInItem = false
        if case .cell = kind { paraAlign = cellAlign } else { paraAlign = htmlCenter ? .center : .natural }
        attrsCache = nil
        if let item = items.last, item.markerPending, kind != .rule {
            for other in items { other.markerPending = false }
            paraFirstInItem = true
            emitMarker(item)
        }
    }

    private func ensureParagraph() {
        if paraStart == nil { openParagraph(htmlNextKind ?? .body, implicit: true) }
    }

    private func closeImplicit() {
        if paraStart != nil && paraImplicit { closeParagraph() }
    }

    private func closeParagraph() {
        guard let start = paraStart else { return }
        let verbatim = paraKind == .code || paraKind == .frontMatter
        if verbatim && out.length > start && out.mutableString.character(at: out.length - 1) == 10 {
            // Code text already ends with its own newline.
        } else {
            var a = currentAttrs()
            a[.link] = nil
            a[.backgroundColor] = nil
            if paraKind == .rule { a[.font] = fonts.font(size: 1) }
            out.append(NSAttributedString(string: "\n", attributes: a))
        }
        let range = NSRange(location: start, length: out.length - start)
        let style = makeStyle(atStart: start == 0)
        out.addAttribute(.paragraphStyle, value: style, range: range)
        last = (range, style)
        lastAdjustable = paraBlock == nil
        paraStart = nil
        markStart = nil
        lastMark = nil
        paraBlock = nil
        paraIndentBlock = nil
        paraImplicit = false
        paraFirstInItem = false
        htmlNextKind = nil
        // Unbalanced inline HTML never leaks past a paragraph.
        hStrong = 0; hEm = 0; hCode = 0; hDel = 0
        if hLinks > 0 { links.removeLast(min(hLinks, links.count)); hLinks = 0 }
        attrsCache = nil
    }

    private func setLastSpacing(_ v: CGFloat) {
        guard let l = last, lastAdjustable, let ps = l.style.mutableCopy() as? NSMutableParagraphStyle else { return }
        ps.paragraphSpacing = v
        out.addAttribute(.paragraphStyle, value: ps, range: l.range)
        last = (l.range, ps)
    }

    private func makeStyle(atStart: Bool) -> NSParagraphStyle {
        let ps = NSMutableParagraphStyle()
        var blocks: [NSTextBlock] = paraKind.isCell ? [] : quotes.flatMap(\.blocks)
        if let b = paraIndentBlock { blocks.append(b) }
        if let b = paraBlock { blocks.append(b) }
        ps.textBlocks = blocks
        ps.alignment = paraAlign

        // Blocks carry their own indentation as a margin; plain paragraphs indent directly.
        let indent = paraBlock == nil ? CGFloat(listDepthInQuote) * indentStep : 0
        ps.headIndent = indent
        ps.firstLineHeadIndent = indent
        ps.defaultTabInterval = indentStep
        ps.tabStops = []
        if paraFirstInItem && paraBlock == nil {
            ps.firstLineHeadIndent = max(0, indent - indentStep)
            ps.tabStops = [NSTextTab(textAlignment: .right, location: indent - round(size * 0.45)),
                           NSTextTab(textAlignment: .left, location: indent)]
        }

        switch paraKind {
        case .body:
            ps.lineHeightMultiple = paraTall ? 1.0 : 1.2
            ps.paragraphSpacing = inTightItem ? tightSpacing : blockSpacing
        case .heading(let level):
            ps.lineHeightMultiple = 1.1
            if level > 2 {
                ps.paragraphSpacingBefore = atStart ? 0 : round(size * 1.1)
                ps.paragraphSpacing = round(size * 0.5)
            }
        case .code, .frontMatter:
            ps.lineHeightMultiple = 1.15
            ps.defaultTabInterval = round(size * 0.88 * 0.6 * 4)
        case .cell:
            ps.lineHeightMultiple = 1.15
        case .rule:
            break
        }
        return ps
    }

    private func emitMarker(_ item: ItemState) {
        let font = fonts.font(size: size)
        if let task = item.task {
            out.append(NSAttributedString(string: "\t", attributes: [.font: font]))
            out.append(checkbox(checked: task.checked, offset: task.offset, font: font))
            out.append(NSAttributedString(string: "\t", attributes: [.font: font]))
        } else {
            let ordered = lists.last?.ordered ?? false
            out.append(NSAttributedString(string: "\t\(item.marker)\t", attributes: [
                .font: font,
                .foregroundColor: ordered ? Theme.text : Theme.secondaryText,
            ]))
        }
    }

    private func checkbox(checked: Bool, offset: Int, font: NSFont) -> NSAttributedString {
        let name = checked ? "checkmark.square.fill" : "square"
        let color: NSColor = checked ? .controlAccentColor : .secondaryLabelColor
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: color))
        let att = NSTextAttachment()
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: checked ? "Done" : "To do")?
            .withSymbolConfiguration(config) {
            att.image = img
            att.bounds = CGRect(x: 0, y: font.descender * 0.6, width: img.size.width, height: img.size.height)
        }
        let s = NSMutableAttributedString(attachment: att)
        s.addAttributes([.markyTask: offset, .font: font, .cursor: NSCursor.pointingHand,
                         .toolTip: checked ? "Mark as not done" : "Mark as done"],
                        range: NSRange(location: 0, length: s.length))
        return s
    }

    private func addAnchor(_ text: String, at loc: Int) {
        var slug = ""
        for ch in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(ch) || ch == "-" || ch == "_" {
                slug.unicodeScalars.append(ch)
            } else if ch == " " {
                slug += "-"
            }
        }
        if let n = slugCounts[slug] {
            slugCounts[slug] = n + 1
            anchors["\(slug)-\(n)"] = loc
        } else {
            slugCounts[slug] = 1
            anchors[slug] = loc
        }
    }

    // MARK: - Spans & text

    private func enterSpan(_ type: MD_SPANTYPE, _ detail: UnsafeMutableRawPointer?) {
        attrsCache = nil
        switch type {
        case MD_SPAN_EM: em += 1
        case MD_SPAN_STRONG: strong += 1
        case MD_SPAN_CODE, MD_SPAN_LATEXMATH, MD_SPAN_LATEXMATH_DISPLAY: codeSpan += 1
        case MD_SPAN_DEL: del += 1
        case MD_SPAN_A:
            let d = detail!.assumingMemoryBound(to: MD_SPAN_A_DETAIL.self).pointee
            links.append(resolveURL(attr(d.href)))
        case MD_SPAN_WIKILINK:
            let d = detail!.assumingMemoryBound(to: MD_SPAN_WIKILINK_DETAIL.self).pointee
            links.append(resolveWikiLink(attr(d.target)))
        case MD_SPAN_IMG:
            let d = detail!.assumingMemoryBound(to: MD_SPAN_IMG_DETAIL.self).pointee
            if imageDepth == 0 { imageAlt = "" }
            imageDepth += 1
            imageSrcs.append(attr(d.src))
        default: break
        }
    }

    private func leaveSpan(_ type: MD_SPANTYPE) {
        attrsCache = nil
        switch type {
        case MD_SPAN_EM: em -= 1
        case MD_SPAN_STRONG: strong -= 1
        case MD_SPAN_CODE, MD_SPAN_LATEXMATH, MD_SPAN_LATEXMATH_DISPLAY: codeSpan -= 1
        case MD_SPAN_DEL: del -= 1
        case MD_SPAN_A, MD_SPAN_WIKILINK: if !links.isEmpty { links.removeLast() }
        case MD_SPAN_IMG:
            imageDepth -= 1
            let src = imageSrcs.removeLast()
            if imageDepth == 0 { emitImage(src: src, alt: imageAlt) }
        default: break
        }
    }

    private func text(_ type: MD_TEXTTYPE, _ p: UnsafePointer<CChar>, _ n: Int) {
        switch type {
        case MD_TEXT_NULLCHAR: append("\u{FFFD}")
        case MD_TEXT_BR: append(imageDepth > 0 ? " " : "\u{2028}")
        case MD_TEXT_SOFTBR: append(" ")
        case MD_TEXT_ENTITY: append(Self.decodeEntity(p, n))
        case MD_TEXT_HTML:
            if htmlBlock != nil { htmlBlock! += Self.str(p, n) } else { inlineHTML(Self.str(p, n)) }
        case MD_TEXT_NORMAL where paraKind != .code && codeSpan + hCode == 0 && imageDepth == 0 && htmlBlock == nil:
            appendMarked(Self.str(p, n))
        default: append(Self.str(p, n))
        }
    }

    private var markStart: Int?
    private var lastMark: NSRange?

    /// `==text==` highlights; a following " (yellow|green|pink|blue)" label sets the color and is hidden.
    private func appendMarked(_ s: String) {
        guard s.contains("==") || lastMark != nil else { append(s); return }
        for (i, piece) in s.components(separatedBy: "==").enumerated() {
            if i > 0 {
                if let start = markStart {
                    let range = NSRange(location: start, length: out.length - start)
                    out.addAttribute(.backgroundColor, value: Self.markColor(.yellow), range: range)
                    lastMark = range
                    markStart = nil
                } else {
                    ensureParagraph()
                    markStart = out.length
                }
            }
            var seg = piece
            if let mark = lastMark, i > 0 || !s.hasPrefix("==") {
                if let m = seg.range(of: #"^ \((yellow|green|pink|blue)\)"#, options: .regularExpression) {
                    let name = seg[m].dropFirst(2).dropLast()
                    if let c = HighlightColor.highlightColors.first(where: { $0.name == name }) {
                        out.addAttribute(.backgroundColor, value: Self.markColor(c), range: mark)
                    }
                    seg.removeSubrange(m)
                }
                if markStart == nil { lastMark = nil }
            }
            if !seg.isEmpty { append(seg) }
        }
    }

    private static func markColor(_ c: HighlightColor) -> NSColor {
        let (r, g, b) = c.rgb
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 0.45)
    }

    private func append(_ s: String) {
        if imageDepth > 0 { imageAlt += s; return }
        if htmlBlock != nil { htmlBlock! += s; return }
        ensureParagraph()
        if headingText != nil { headingText! += s }
        out.append(NSAttributedString(string: s, attributes: currentAttrs()))
    }

    private func currentAttrs() -> [NSAttributedString.Key: Any] {
        if let a = attrsCache { return a }
        var a: [NSAttributedString.Key: Any] = [:]
        var fsize = size
        var weight: NSFont.Weight = .regular
        var mono = false
        var color = Theme.text
        switch paraKind {
        case .heading(let level):
            fsize = size * [2.0, 1.5, 1.25, 1.1, 1.0, 0.9][min(max(level, 1), 6) - 1]
            weight = level <= 2 ? .bold : .semibold
            if level == 6 { color = Theme.secondaryText }
        case .code:
            mono = true
            fsize = size * 0.88
        case .frontMatter:
            mono = true
            fsize = size * 0.85
            color = Theme.secondaryText
        case .cell(let header):
            if header { weight = .semibold }
        case .body, .rule:
            break
        }
        if strong + hStrong > 0 && weight == .regular { weight = .semibold }
        if codeSpan + hCode > 0 && !mono {
            mono = true
            fsize *= 0.88
            a[.backgroundColor] = Theme.inlineCodeBackground
        }
        if !quotes.isEmpty && color == Theme.text { color = Theme.secondaryText }
        a[.font] = fonts.font(size: (fsize * 2).rounded() / 2, weight: weight, italic: em + hEm > 0, mono: mono)
        a[.foregroundColor] = color
        if del + hDel > 0 { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let url = links.last(where: { $0 != nil }) ?? nil {
            a[.link] = url
            a[.toolTip] = url.isFileURL ? url.path : url.absoluteString
        }
        attrsCache = a
        return a
    }

    // MARK: - Links & images

    private func resolveURL(_ raw: String) -> URL? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("#") {
            return URL(string: s) ?? URL(string: "#" + (s.dropFirst().addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? ""))
        }
        if let u = URL(string: s), u.scheme != nil { return u }
        let encoded = URL(string: s) == nil
            ? s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.union(CharacterSet(charactersIn: "#?")))
            : s
        guard let rel = encoded else { return nil }
        if let base = baseURL { return URL(string: rel, relativeTo: base)?.absoluteURL }
        return URL(string: rel)
    }

    private func resolveWikiLink(_ target: String) -> URL? {
        var name = target
        var fragment = ""
        if let hash = name.firstIndex(of: "#") {
            fragment = String(name[name.index(after: hash)...])
            name = String(name[..<hash])
        }
        if name.isEmpty { return resolveURL("#" + fragment) }
        if (name as NSString).pathExtension.isEmpty { name += ".md" }
        guard let base = baseURL else { return nil }
        var url = base.appendingPathComponent(name)
        if !fragment.isEmpty, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            c.fragment = fragment
            url = c.url ?? url
        }
        return url
    }

    private func emitImage(src: String, alt: String) {
        guard let url = resolveURL(src) else { append(alt); return }
        if let img = ImageStore.shared.image(for: url) {
            ensureParagraph()
            let att = NSTextAttachment()
            att.image = img
            var w = img.size.width, h = img.size.height
            if w > maxImageWidth { h = (h * maxImageWidth / w).rounded(); w = maxImageWidth }
            // Keep one image from filling the whole window.
            let maxHeight = max(320, (maxImageWidth * 0.7).rounded())
            if h > maxHeight { w = (w * maxHeight / h).rounded(); h = maxHeight }
            // Small inline images (badges, icons) sit on the baseline like text.
            let y = h < size * 2 ? (size - h) / 2 - size * 0.2 : 0
            if h >= size * 2 { paraTall = true }
            att.bounds = CGRect(x: 0, y: y, width: w, height: h)
            let s = NSMutableAttributedString(attachment: att)
            var a = currentAttrs()
            a[.backgroundColor] = nil
            if !alt.isEmpty && a[.toolTip] == nil { a[.toolTip] = alt }
            s.addAttributes(a, range: NSRange(location: 0, length: s.length))
            out.append(s)
            return
        }
        if ImageStore.shared.shouldFetch(url) { pendingImages.append(url) }
        ensureParagraph()
        var a = currentAttrs()
        a[.foregroundColor] = Theme.secondaryText
        out.append(NSAttributedString(string: alt.isEmpty ? "[image]" : alt, attributes: a))
    }

    // MARK: - Raw HTML

    private struct Tag {
        let name: String
        let closing: Bool
        let raw: String

        init?(_ raw: String) {
            var chars = raw.unicodeScalars.makeIterator()
            guard chars.next() == "<" else { return nil }
            var c = chars.next()
            closing = c == "/"
            if closing { c = chars.next() }
            var name = ""
            while let ch = c, CharacterSet.alphanumerics.contains(ch) {
                name.unicodeScalars.append(ch)
                c = chars.next()
            }
            guard !name.isEmpty else { return nil }
            self.name = name.lowercased()
            self.raw = raw
        }

        func attr(_ key: String) -> String? {
            let pattern = "\\b\(key)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
            guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let m = re.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) else { return nil }
            for i in 1...3 {
                if let r = Range(m.range(at: i), in: raw) { return MarkdownRenderer.decodeEntities(in: String(raw[r])) }
            }
            return nil
        }
    }

    private func inlineHTML(_ raw: String) {
        guard let tag = Tag(raw) else { return }
        attrsCache = nil
        let d = tag.closing ? -1 : 1
        switch tag.name {
        case "br": append("\u{2028}")
        case "b", "strong": hStrong = max(0, hStrong + d)
        case "i", "em": hEm = max(0, hEm + d)
        case "code", "kbd", "tt", "samp": hCode = max(0, hCode + d)
        case "s", "del", "strike": hDel = max(0, hDel + d)
        case "a":
            if tag.closing {
                if hLinks > 0 { links.removeLast(); hLinks -= 1 }
            } else if let href = tag.attr("href") {
                links.append(resolveURL(href)); hLinks += 1
            }
        case "img":
            if let src = tag.attr("src") { emitImage(src: src, alt: tag.attr("alt") ?? "") }
        default: break
        }
    }

    private static let blockTags: Set<String> = [
        "p", "div", "br", "hr", "li", "ul", "ol", "table", "tr", "details", "summary", "section",
        "center", "blockquote", "pre", "h1", "h2", "h3", "h4", "h5", "h6", "header", "footer", "picture",
    ]
    private static let tagRegex = try! NSRegularExpression(pattern: "<[^>]*>")
    private static let commentRegex = try! NSRegularExpression(pattern: "<!--[\\s\\S]*?(-->|$)")

    /// Renders an HTML block approximately: text, images, links, headings and centering.
    private func renderHTMLBlock(_ html: String) {
        let ns = NSMutableString(string: html)
        Self.commentRegex.replaceMatches(in: ns, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        let s = ns as String
        guard !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        htmlCenter = s.range(of: "align\\s*=\\s*[\"']?center", options: [.regularExpression, .caseInsensitive]) != nil
        defer { htmlCenter = false; htmlNextKind = nil }

        let nss = s as NSString
        var pos = 0
        func emitText(_ t: String) {
            var text = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            if paraStart == nil { text = String(text.drop(while: { $0 == " " })) }
            guard !text.isEmpty else { return }
            append(Self.decodeEntities(in: text))
        }
        for m in Self.tagRegex.matches(in: s, range: NSRange(location: 0, length: nss.length)) {
            if m.range.location > pos {
                emitText(nss.substring(with: NSRange(location: pos, length: m.range.location - pos)))
            }
            pos = NSMaxRange(m.range)
            guard let tag = Tag(nss.substring(with: m.range)) else { continue }
            if Self.blockTags.contains(tag.name) {
                if tag.name == "br" && paraStart != nil { append("\u{2028}"); continue }
                closeParagraph()
                if tag.name == "hr" {
                    enterBlock(MD_BLOCK_HR, nil)
                } else if tag.name.count == 2, tag.name.hasPrefix("h"), let level = Int(tag.name.dropFirst()) {
                    htmlNextKind = tag.closing ? nil : .heading(level)
                } else if tag.name == "summary" {
                    hStrong = tag.closing ? 0 : 1
                }
            } else {
                inlineHTML(tag.raw)
            }
        }
        if pos < nss.length { emitText(nss.substring(from: pos)) }
        closeParagraph()
    }

    // MARK: - Front matter

    private struct FrontMatter { let contentStart: Int; let contentEnd: Int; let bodyStart: Int }

    /// Detects a YAML front matter block (`---` ... `---` or `...`) at the very top.
    private static func frontMatterEnd(_ b: UnsafeBufferPointer<UInt8>) -> FrontMatter? {
        func lineEnd(_ i: Int) -> Int { var j = i; while j < b.count && b[j] != 10 { j += 1 }; return j }
        func isFence(_ s: Int, _ e: Int, allowDots: Bool) -> Bool {
            var e = e
            while e > s && (b[e - 1] == 13 || b[e - 1] == 32 || b[e - 1] == 9) { e -= 1 }
            guard e - s == 3 else { return false }
            return (b[s] == 45 && b[s + 1] == 45 && b[s + 2] == 45) || (allowDots && b[s] == 46 && b[s + 1] == 46 && b[s + 2] == 46)
        }
        guard b.count >= 7 else { return nil }
        let first = lineEnd(0)
        guard isFence(0, first, allowDots: false), first < b.count else { return nil }
        let contentStart = first + 1
        var i = contentStart
        while i < b.count {
            let e = lineEnd(i)
            if isFence(i, e, allowDots: true) {
                guard i > contentStart else { return nil } // "---\n---" is two rules, not front matter
                return FrontMatter(contentStart: contentStart, contentEnd: i, bodyStart: min(e + 1, b.count))
            }
            i = e + 1
        }
        return nil
    }

    private func renderFrontMatter(_ yaml: String) {
        let b = makeCodeBlock()
        openParagraph(.frontMatter, block: b)
        var text = yaml.replacingOccurrences(of: "\r\n", with: "\n")
        if !text.hasSuffix("\n") { text += "\n" }
        append(text)
        closeParagraph()
    }
}
