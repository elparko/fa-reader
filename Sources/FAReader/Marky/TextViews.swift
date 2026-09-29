import AppKit

/// Builds a TextKit 1 text view in a scroll view. TextKit 1 is required for
/// NSTextBlock/NSTextTable rendering and is fast for plain-text editing.
func makeScrollingTextView(_ make: (NSRect, NSTextContainer) -> NSTextView, frame: NSRect) -> NSScrollView {
    let storage = NSTextStorage()
    let layout = NSLayoutManager()
    storage.addLayoutManager(layout)
    let container = NSTextContainer(containerSize: NSSize(width: frame.width, height: .greatestFiniteMagnitude))
    container.widthTracksTextView = true
    container.lineFragmentPadding = 0
    layout.addTextContainer(container)

    let tv = make(NSRect(origin: .zero, size: frame.size), container)
    tv.minSize = NSSize(width: 0, height: frame.height)
    tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
    tv.isVerticallyResizable = true
    tv.isHorizontallyResizable = false
    tv.autoresizingMask = [.width]
    tv.drawsBackground = true
    tv.backgroundColor = .textBackgroundColor
    tv.usesFindBar = true
    tv.isIncrementalSearchingEnabled = true

    let scroll = NSScrollView(frame: frame)
    scroll.hasVerticalScroller = true
    scroll.borderType = .noBorder
    scroll.drawsBackground = true
    scroll.backgroundColor = .textBackgroundColor
    scroll.documentView = tv
    scroll.autoresizingMask = [.width, .height]
    return scroll
}

/// Keeps text in a centered, readable column however wide the window is.
private func centeredInset(for width: CGFloat, column: CGFloat, minSide: CGFloat, top: CGFloat) -> NSSize {
    NSSize(width: max(minSide, floor((width - column) / 2)), height: top)
}

// MARK: - Preview

final class PreviewTextView: NSTextView {
    var onToggleTask: ((Int) -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { updateInset() }
    }

    func updateInset() {
        let inset = centeredInset(for: bounds.width, column: Theme.previewColumnWidth, minSide: 28, top: 26)
        if inset != textContainerInset { textContainerInset = inset }
    }

    /// Width available to content (for sizing images).
    var contentWidth: CGFloat {
        let w = bounds.width > 0 ? bounds.width : Theme.previewColumnWidth
        return max(120, min(Theme.previewColumnWidth, w - 56))
    }

    override func mouseDown(with event: NSEvent) {
        if let offset = taskOffset(at: convert(event.locationInWindow, from: nil)) {
            onToggleTask?(offset)
            return
        }
        super.mouseDown(with: event)
    }

    private func taskOffset(at p: NSPoint) -> Int? {
        guard let lm = layoutManager, let tc = textContainer, let ts = textStorage, ts.length > 0 else { return nil }
        let pt = NSPoint(x: p.x - textContainerOrigin.x, y: p.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyph = lm.glyphIndex(for: pt, in: tc, fractionOfDistanceThroughGlyph: &fraction)
        let rect = lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tc)
        guard rect.insetBy(dx: -3, dy: -3).contains(pt) else { return nil }
        return ts.attribute(.markyTask, at: lm.characterIndexForGlyph(at: glyph), effectiveRange: nil) as? Int
    }

    // Browser-style paging for a read-only view.
    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        if mods.isEmpty, event.charactersIgnoringModifiers == " " {
            if event.modifierFlags.contains(.shift) { scrollPageUp(nil) } else { scrollPageDown(nil) }
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - Editor

final class EditorTextView: NSTextView {
    weak var highlighter: MarkdownHighlighter?

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { updateInset() }
    }

    func updateInset() {
        let inset = centeredInset(for: bounds.width, column: Theme.editorColumnWidth, minSide: 22, top: 22)
        if inset != textContainerInset { textContainerInset = inset }
    }

    override func shouldChangeText(in range: NSRange, replacementString: String?) -> Bool {
        if range.length > 0, let hl = highlighter {
            let removed = (string as NSString).substring(with: range)
            if removed.contains("```") || removed.contains("~~~") || removed.contains("---") { hl.forceFullPass = true }
        }
        return super.shouldChangeText(in: range, replacementString: replacementString)
    }

    /// Applies an edit through the undo-aware path.
    @discardableResult
    func replace(_ range: NSRange, with text: String, select: NSRange? = nil) -> Bool {
        guard shouldChangeText(in: range, replacementString: text), let ts = textStorage else { return false }
        ts.replaceCharacters(in: range, with: text)
        didChangeText()
        if let select { setSelectedRange(select) }
        return true
    }

    private var ns: NSString { string as NSString }

    // MARK: Lists

    private static let listRegex = try! NSRegularExpression(
        pattern: "^([ \\t]*)(?:([-*+])|(\\d{1,9})([.)]))([ \\t]+)(\\[[ xX]\\][ \\t]+)?")
    private static let quoteRegex = try! NSRegularExpression(pattern: "^([ \\t]*(?:>[ \\t]?)+)")

    override func insertNewline(_ sender: Any?) {
        let sel = selectedRange()
        guard sel.length == 0, !hasMarkedText() else { return super.insertNewline(sender) }
        let line = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        var contentEnd = NSMaxRange(line)
        while contentEnd > line.location, [0x0A, 0x0D].contains(ns.character(at: contentEnd - 1)) { contentEnd -= 1 }
        let lineText = ns.substring(with: NSRange(location: line.location, length: contentEnd - line.location))
        let lineNS = lineText as NSString
        let caretInLine = sel.location - line.location

        if let m = Self.listRegex.firstMatch(in: lineText, range: NSRange(location: 0, length: lineNS.length)),
           caretInLine >= m.range.length {
            if m.range.length == lineNS.length {
                // Empty item: end the list instead of continuing it.
                replace(NSRange(location: line.location, length: m.range.length), with: "",
                        select: NSRange(location: line.location, length: 0))
                return
            }
            let indent = lineNS.substring(with: m.range(at: 1))
            let space = lineNS.substring(with: m.range(at: 5))
            var marker: String
            if m.range(at: 2).location != NSNotFound {
                marker = lineNS.substring(with: m.range(at: 2))
            } else {
                let n = Int(lineNS.substring(with: m.range(at: 3))) ?? 0
                marker = "\(n + 1)" + lineNS.substring(with: m.range(at: 4))
            }
            let task = m.range(at: 6).location != NSNotFound ? "[ ] " : ""
            insertText("\n" + indent + marker + space + task, replacementRange: sel)
            return
        }
        if let m = Self.quoteRegex.firstMatch(in: lineText, range: NSRange(location: 0, length: lineNS.length)),
           caretInLine >= m.range.length {
            if m.range.length == lineNS.length {
                replace(NSRange(location: line.location, length: m.range.length), with: "",
                        select: NSRange(location: line.location, length: 0))
                return
            }
            insertText("\n" + lineNS.substring(with: m.range), replacementRange: sel)
            return
        }
        // Keep the current indentation.
        var i = 0
        while i < lineNS.length, i < caretInLine, lineNS.character(at: i) == 0x20 || lineNS.character(at: i) == 0x09 { i += 1 }
        if i > 0 {
            insertText("\n" + lineNS.substring(to: i), replacementRange: sel)
            return
        }
        super.insertNewline(sender)
    }

    /// Lines touched by the selection, as ranges without their line endings.
    private func selectedLineStarts() -> [Int] {
        let sel = selectedRange()
        var starts: [Int] = []
        var loc = ns.lineRange(for: NSRange(location: sel.location, length: 0)).location
        let end = max(sel.location, NSMaxRange(sel) - (sel.length > 0 ? 1 : 0))
        repeat {
            starts.append(loc)
            loc = NSMaxRange(ns.lineRange(for: NSRange(location: loc, length: 0)))
        } while loc <= end && loc < ns.length
        return starts
    }

    private func isListLine(_ start: Int) -> Bool {
        let line = ns.lineRange(for: NSRange(location: start, length: 0))
        return Self.listRegex.firstMatch(in: string, range: line) != nil
    }

    override func insertTab(_ sender: Any?) {
        let sel = selectedRange()
        let starts = selectedLineStarts()
        guard sel.length > 0 && starts.count > 1 || isListLine(starts[0]) else { return super.insertTab(sender) }
        indent(starts, by: 1)
    }

    override func insertBacktab(_ sender: Any?) {
        indent(selectedLineStarts(), by: -1)
    }

    private func indent(_ starts: [Int], by direction: Int) {
        let unit = "    "
        var sel = selectedRange()
        undoManager?.beginUndoGrouping()
        for start in starts.reversed() {
            if direction > 0 {
                guard replace(NSRange(location: start, length: 0), with: unit) else { continue }
                if start <= sel.location { sel.location += unit.count } else if start < NSMaxRange(sel) { sel.length += unit.count }
            } else {
                var n = 0
                while n < 4, start + n < ns.length, ns.character(at: start + n) == 0x20 { n += 1 }
                if n == 0, start < ns.length, ns.character(at: start) == 0x09 { n = 1 }
                guard n > 0, replace(NSRange(location: start, length: n), with: "") else { continue }
                if start < sel.location { sel.location -= min(n, sel.location - start) }
                else if start < NSMaxRange(sel) { sel.length = max(0, sel.length - n) }
            }
        }
        undoManager?.endUndoGrouping()
        setSelectedRange(NSRange(location: min(sel.location, ns.length), length: min(sel.length, ns.length - min(sel.location, ns.length))))
    }

    // MARK: Formatting

    @objc func markyBold(_ sender: Any?) { toggleWrap("**") }
    @objc func markyItalic(_ sender: Any?) { toggleWrap("*") }
    @objc func markyStrikethrough(_ sender: Any?) { toggleWrap("~~") }
    @objc func markyCode(_ sender: Any?) { toggleWrap("`") }

    @objc func markyLink(_ sender: Any?) {
        let sel = selectedRange()
        let text = ns.substring(with: sel)
        if text.hasPrefix("http://") || text.hasPrefix("https://") {
            replace(sel, with: "[](\(text))", select: NSRange(location: sel.location + 1, length: 0))
        } else {
            let urlStart = sel.location + (text as NSString).length + 3
            replace(sel, with: "[\(text)]()", select: NSRange(location: urlStart, length: 0))
        }
    }

    private func toggleWrap(_ marker: String) {
        let sel = selectedRange()
        let m = (marker as NSString).length
        // Already wrapped just outside the selection: unwrap.
        if sel.location >= m, NSMaxRange(sel) + m <= ns.length,
           ns.substring(with: NSRange(location: sel.location - m, length: m)) == marker,
           ns.substring(with: NSRange(location: NSMaxRange(sel), length: m)) == marker {
            let outer = NSRange(location: sel.location - m, length: sel.length + 2 * m)
            replace(outer, with: ns.substring(with: sel), select: NSRange(location: outer.location, length: sel.length))
            return
        }
        let text = ns.substring(with: sel)
        let t = text as NSString
        // Selection includes the markers: unwrap.
        if t.length >= 2 * m, text.hasPrefix(marker), text.hasSuffix(marker) {
            let inner = t.substring(with: NSRange(location: m, length: t.length - 2 * m))
            replace(sel, with: inner, select: NSRange(location: sel.location, length: (inner as NSString).length))
            return
        }
        replace(sel, with: marker + text + marker, select: NSRange(location: sel.location + m, length: sel.length))
    }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(markyBold(_:)), #selector(markyItalic(_:)), #selector(markyStrikethrough(_:)),
             #selector(markyCode(_:)), #selector(markyLink(_:)):
            return isEditable
        default:
            return super.validateMenuItem(item)
        }
    }
}
