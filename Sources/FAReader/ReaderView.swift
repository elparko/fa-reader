import AppKit
import FACore
import PDFKit
import SwiftUI

final class HighlightPDFView: PDFView {
    var onHit: ((String?) -> Void)?
    var onFirstDraw: (() -> Void)?
    var onSelectionEnded: (() -> Void)?
    var onColor: ((HighlightColor) -> Void)?
    var onEditNote: (() -> Void)?
    var onDelete: (() -> Void)?
    var onDeleteID: ((String) -> Void)?
    var onErase: (() -> Void)?
    var onCopyHighlight: (() -> Bool)?
    var selectedHighlight: () -> String? = { nil }
    var selectionTouchesHighlights: () -> Bool = { false }
    var describeHighlight: (String) -> String = { $0 }
    private var drawn = false
    private var selecting = false
    private var lineBoxes: [ObjectIdentifier: [CGRect]] = [:]
    private var charBoxes: [ObjectIdentifier: [CGRect]] = [:]
    private var pageTexts: [ObjectIdentifier: PageText] = [:]

    override var document: PDFDocument? {
        didSet {
            lineBoxes = [:]
            charBoxes = [:]
            pageTexts = [:]
        }
    }

    func configure() {
        displayMode = .singlePageContinuous
        displayDirection = .vertical
        displaysPageBreaks = true
        autoScales = true
        minScaleFactor = 0.2
        maxScaleFactor = 8
        backgroundColor = .underPageBackgroundColor
    }

    /// Highlights under the mouse, topmost first.
    private func highlightHits(_ event: NSEvent) -> [(id: String, note: Bool)] {
        let point = convert(event.locationInWindow, from: nil)
        guard let page = page(for: point, nearest: false) else { return [] }
        let local = convert(point, to: page)
        var seen = Set<String>()
        return page.annotations.reversed().compactMap { a in
            guard let name = a.userName, name.hasPrefix("fa:"), a.bounds.contains(local) else { return nil }
            let id = String(name.dropFirst(3))
            guard seen.insert(id).inserted else { return nil }
            return (id, a.type?.hasSuffix("Text") == true)
        }
    }

    /// The topmost highlight, or the one under the selected highlight when they overlap,
    /// so clicking the same spot again steps down through stacked highlights.
    private func highlightHit(_ event: NSEvent, stepDown: Bool) -> (id: String, note: Bool)? {
        let hits = highlightHits(event)
        guard let current = selectedHighlight(), let i = hits.firstIndex(where: { $0.id == current }) else { return hits.first }
        return stepDown ? hits[(i + 1) % hits.count] : hits[i]
    }

    override func mouseDown(with event: NSEvent) {
        if let hit = highlightHit(event, stepDown: true) {
            onHit?(hit.id)
            if hit.note { return }
        } else {
            onHit?(nil)
        }
        selecting = true
        if event.clickCount == 1, !event.modifierFlags.contains(.shift), let start = lineStart(event) {
            trackSelection(from: start)
        } else {
            super.mouseDown(with: event)
        }
        if NSEvent.pressedMouseButtons & 1 == 0 { endSelection() }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let page = page(for: point, nearest: true) {
            for a in page.annotations where a.url != nil { page.removeAnnotation(a) }
        }
        super.mouseMoved(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        endSelection()
    }

    private func lineStart(_ event: NSEvent) -> (page: PDFPage, x: CGFloat, line: CGRect)? {
        let point = convert(event.locationInWindow, from: nil)
        guard let page = page(for: point, nearest: false) else { return nil }
        let local = convert(point, to: page)
        guard let line = lines(on: page).first(where: { $0.insetBy(dx: -2, dy: 0).contains(local) }) else { return nil }
        return (page, local.x, line)
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

    /// The selection widened to whole words, with whitespace at either end left out.
    /// Holding Option keeps the selection as dragged.
    func snapped(_ selection: PDFSelection) -> PDFSelection {
        guard !NSEvent.modifierFlags.contains(.option), let document, let first = selection.pages.first,
              let last = selection.pages.last else { return selection }
        if first == last {
            let chars = chars(of: selection, on: first)
            let text = pageText(first)
            let snapped = text.snap(chars)
            guard !chars.isEmpty, snapped != chars, !snapped.isEmpty else { return selection }
            let out = PDFSelection(document: document)
            for r in text.runs(snapped) {
                if let part = first.selection(for: NSRange(location: r.lowerBound, length: r.count)) { out.add(part) }
            }
            return out.pages.isEmpty ? selection : out
        }
        guard let out = selection.copy() as? PDFSelection else { return selection }
        let head = chars(of: selection, on: first), tail = chars(of: selection, on: last)
        if let start = head.first, let end = tail.last {
            let a = pageText(first), b = pageText(last)
            let before = start - a.snap(start..<(start + 1)).lowerBound
            let after = b.snap(end..<(end + 1)).upperBound - (end + 1)
            if before > 0 { out.extend(atStart: before) }
            if after > 0 { out.extend(atEnd: after) }
        }
        return out
    }

    /// Text lines in the PDF overlap, so PDFKit's own drag picks up the next line as soon as the mouse drifts a little low.
    /// This drag stays on the starting line until the mouse is 0.75 of a line height away from it.
    private func trackSelection(from start: (page: PDFPage, x: CGFloat, line: CGRect)) {
        window?.makeFirstResponder(self)
        clearSelection()
        while let event = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if event.type == .leftMouseDragged { documentView?.autoscroll(with: event) }
            let point = convert(event.locationInWindow, from: nil)
            if let document, let page = page(for: point, nearest: true) {
                var local = convert(point, to: page)
                if page == start.page, abs(local.y - start.line.midY) < start.line.height * 0.75 { local.y = start.line.midY }
                let from = CGPoint(x: start.x, y: start.line.midY)
                let raw = document.selection(from: start.page, at: from, to: page, at: local)
                setCurrentSelection(raw.map(snapped), animate: false)
            }
            if event.type == .leftMouseUp { break }
        }
    }

    private func endSelection() {
        guard selecting else { return }
        selecting = false
        onSelectionEnded?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let hasText = !(currentSelection?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let menu = super.menu(for: event) ?? NSMenu()
        var items: [NSMenuItem] = []
        let hits = hasText ? [] : highlightHits(event)
        let hit = hasText ? nil : highlightHit(event, stepDown: false)
        if let hit {
            clearSelection()
            onHit?(hit.id)
        }
        if hasText || hit != nil {
            for c in HighlightColor.highlightColors {
                let item = NSMenuItem(title: (hasText ? "Highlight " : "Make ") + c.name.capitalized,
                                      action: #selector(colorFromMenu(_:)), keyEquivalent: "\(c.rawValue)")
                item.keyEquivalentModifierMask = .command
                item.tag = c.rawValue
                item.target = self
                item.image = swatchImage(c)
                items.append(item)
            }
        }
        if hasText, selectionTouchesHighlights() {
            items.append(.separator())
            let erase = NSMenuItem(title: "Remove Highlight", action: #selector(eraseFromMenu), keyEquivalent: "")
            erase.target = self
            erase.image = NSImage(systemSymbolName: "eraser", accessibilityDescription: nil)
            items.append(erase)
        }
        if hit != nil {
            items.append(.separator())
            let note = NSMenuItem(title: "Edit Note", action: #selector(noteFromMenu), keyEquivalent: "")
            note.target = self
            items.append(note)
            let copy = NSMenuItem(title: "Copy Text", action: #selector(copyFromMenu), keyEquivalent: "")
            copy.target = self
            items.append(copy)
            if hits.count > 1 {
                for h in hits {
                    let delete = NSMenuItem(title: "Delete \(describeHighlight(h.id))", action: #selector(deleteIDFromMenu(_:)), keyEquivalent: "")
                    delete.representedObject = h.id
                    delete.target = self
                    items.append(delete)
                }
            } else {
                let delete = NSMenuItem(title: "Delete Highlight", action: #selector(deleteFromMenu), keyEquivalent: "")
                delete.target = self
                items.append(delete)
            }
        }
        guard !items.isEmpty else { return menu }
        items.append(.separator())
        for (i, item) in items.enumerated() { menu.insertItem(item, at: i) }
        return menu
    }

    private func swatchImage(_ c: HighlightColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            let (r, g, b) = c.rgb
            NSColor(srgbRed: r, green: g, blue: b, alpha: 1).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

    @objc private func colorFromMenu(_ sender: NSMenuItem) {
        if let c = HighlightColor(rawValue: sender.tag) { onColor?(c) }
    }

    @objc private func noteFromMenu() { onEditNote?() }
    @objc private func eraseFromMenu() { onErase?() }
    @objc private func copyFromMenu() { _ = onCopyHighlight?() }

    override func copy(_ sender: Any?) {
        if (currentSelection?.string ?? "").isEmpty, onCopyHighlight?() == true { return }
        super.copy(sender)
    }
    @objc private func deleteFromMenu() { onDelete?() }
    @objc private func deleteIDFromMenu(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { onDeleteID?(id) }
    }

    override func draw(_ page: PDFPage, to context: CGContext) {
        super.draw(page, to: context)
        if !drawn {
            drawn = true
            DispatchQueue.main.async { [weak self] in self?.onFirstDraw?() }
        }
    }
}

struct ReaderView: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> HighlightPDFView { model.pdfView }

    func updateNSView(_ nsView: HighlightPDFView, context: Context) {}
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @AppStorage("sidebarShown") private var sidebarShown = false

    private var visibility: Binding<NavigationSplitViewVisibility> {
        Binding(get: { sidebarShown ? .all : .detailOnly },
                set: { v in if !model.isTestRun { sidebarShown = v != .detailOnly } })
    }

    var body: some View {
        NavigationSplitView(columnVisibility: visibility) {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 110, ideal: model.pagesOnly ? 150 : model.sidebarMode == .highlights ? 320 : 290, max: 480)
        } detail: {
            HSplitView {
            ReaderView(model: model)
                .overlay(alignment: .topTrailing) {
                    if !sidebarShown, model.isSearching, model.showResultsPanel {
                        SearchResultsView(model: model, pagesOnly: false, onClose: { model.showResultsPanel = false })
                            .frame(width: 340)
                            .frame(maxHeight: 520)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                            .shadow(radius: 8)
                            .padding(10)
                    }
                }
                .overlay(alignment: .bottom) { UndoNotice(model: model) }
                .overlay {
                    if model.document == nil {
                        VStack(spacing: 12) {
                            Text("No PDF open")
                            Button("Open…") { model.openPanel() }
                        }
                    }
                }
                .frame(minWidth: 300)
                if model.notesShown {
                    NotesPane(model: model)
                        .frame(minWidth: 260, idealWidth: 380)
                }
            }
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Text(model.pageLabel.isEmpty ? " " : model.pageLabel).monospacedDigit()
                    }
                    ToolbarItemGroup {
                        Toggle(isOn: $model.highlighterOn) {
                            Label("Highlighter", systemImage: "highlighter")
                        }
                        .toggleStyle(.button)
                        .help(model.highlighterOn ? "Highlighter on: selected text is highlighted \(model.penColor.name). Esc turns it off."
                                                  : "Highlighter off: turn on to highlight text as you select it")
                        ForEach(HighlightColor.highlightColors, id: \.self) { c in
                            Button { model.toolbarColor(c) } label: {
                                ColorDot(color: c, current: model.penColor == c, armed: model.highlighterOn)
                            }
                            .help("\(c.name.capitalized) (⌘\(c.rawValue))")
                        }
                    }
                    ToolbarItemGroup {
                        ControlGroup {
                            Button { model.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                                .help("Zoom out (Cmd+-)")
                            Button { model.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                                .help("Zoom in (Cmd+=)")
                        }
                        Button { model.showHighlightList() } label: {
                            Label("Highlights", systemImage: "list.bullet.rectangle")
                        }
                        .help("List highlights by color, section and page (⇧⌘H)")
                        Toggle(isOn: $model.notesShown) { Label("Notes", systemImage: "note.text") }
                            .toggleStyle(.button)
                            .help("Show the markdown notes for this section (Cmd+Option+N)")
                        Menu {
                            Button("Actual Size") { model.actualSize() }
                            Button("Fit Width") { model.fitWidth() }
                        } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                            .help("Zoom options")
                    }
                }
        }
        .searchable(text: $model.query, placement: .toolbar, prompt: SidebarView.searchPlaceholder)
        .onSubmit(of: .search) {
            model.showResultsPanel = true
            if model.selectedResultID == nil { model.moveResult(1) } else { model.openSelectedResult() }
        }
        .sheet(isPresented: $model.showHistory) { HistoryView(model: model) }
        .sheet(isPresented: $model.showImport) { ImportView(model: model) }
        .navigationTitle(model.bookTitle)
        .task { model.start() }
    }
}

enum BarItem: Hashable {
    case color(HighlightColor), divider, erase, note, copy, delete

    var width: CGFloat { self == .divider ? 9 : 28 }
}

/// The bar that pops up over selected text (colors, and an eraser when the text is already highlighted)
/// or over a clicked highlight (colors, note, copy, delete).
struct HighlightBar: View {
    static let padding: CGFloat = 5
    static let height: CGFloat = 36

    @ObservedObject var model: AppModel

    static func size(_ items: [BarItem]) -> CGSize {
        CGSize(width: padding * 2 + items.reduce(0) { $0 + $1.width }, height: height)
    }

    /// The item under `x`, measured from the bar's left edge.
    static func item(at x: CGFloat, in items: [BarItem]) -> BarItem? {
        var left = padding
        for item in items {
            if x >= left, x < left + item.width { return item == .divider ? nil : item }
            left += item.width
        }
        return nil
    }

    /// The center of `item`, measured from the bar's left edge.
    static func center(of item: BarItem, in items: [BarItem]) -> CGFloat? {
        var left = padding
        for i in items {
            if i == item { return left + i.width / 2 }
            left += i.width
        }
        return nil
    }

    var body: some View {
        let items = model.barItems
        let size = Self.size(items)
        HStack(spacing: 0) {
            ForEach(items, id: \.self) { item in
                BarCell(item: item, model: model).frame(width: item.width, height: Self.height)
            }
        }
        .padding(.horizontal, Self.padding)
        .frame(width: size.width, height: size.height)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
    }
}

private struct BarCell: View {
    let item: BarItem
    @ObservedObject var model: AppModel
    @State private var hovering = false

    var body: some View {
        Group {
            switch item {
            case .color(let c):
                ZStack {
                    Circle()
                        .fill(swatch(c))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.15)))
                        .frame(width: 20, height: 20)
                    if model.barMode == .highlight, model.selected?.highlightColor == c {
                        Circle().strokeBorder(Color.primary.opacity(0.7), lineWidth: 2).frame(width: 26, height: 26)
                    }
                }
                .scaleEffect(hovering ? 1.15 : 1)
                .help("\(c.name.capitalized) (\(c.rawValue))")
            case .divider:
                Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 1, height: 20)
            case .erase:
                icon("eraser").help("Remove highlighting from the selected text (Delete)")
            case .note:
                icon(model.selected?.note.isEmpty == false ? "note.text" : "square.and.pencil")
                    .foregroundStyle(model.selected?.note.isEmpty == false ? Color.accentColor : Color.primary)
                    .help(model.selected?.note.isEmpty == false ? "Edit note (N): \(model.selected?.note.prefix(80) ?? "")" : "Add a note (N)")
            case .copy:
                icon("doc.on.doc").help("Copy the highlighted text (⌘C)")
            case .delete:
                icon("trash").help("Delete this highlight (Delete)")
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: hovering)
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .medium))
            .frame(width: 24, height: 24)
            .background(hovering ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Hosts the bar as an AppKit subview of the PDF view and handles its clicks itself,
/// so a click works even when the window is not yet active.
final class HighlightBarHost: NSHostingView<HighlightBar> {
    var pick: ((BarItem) -> Void)?
    var items: () -> [BarItem] = { [] }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        if let item = HighlightBar.item(at: x, in: items()) { pick?(item) }
    }
}

/// A short message at the bottom of the page after a change that removed highlighting, with an Undo button.
struct UndoNotice: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let notice = model.notice {
            HStack(spacing: 12) {
                Text(notice.message).lineLimit(1)
                Button("Undo") { model.undo() }
                    .buttonStyle(.borderless)
                    .fontWeight(.semibold)
                    .help("Undo (⌘Z)")
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
            .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
            .padding(.bottom, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(notice.id)
        }
    }
}

struct ColorDot: View {
    let color: HighlightColor
    let current: Bool
    let armed: Bool

    var body: some View {
        ZStack {
            Circle().fill(swatch(color)).frame(width: 14, height: 14)
            if current {
                Circle().stroke(armed ? Color.accentColor : Color.secondary, lineWidth: 2).frame(width: 20, height: 20)
            }
        }
        .frame(width: 22, height: 22)
        .contentShape(Rectangle())
    }
}
