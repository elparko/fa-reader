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
    let geometry = PageGeometry()

    override var document: PDFDocument? {
        didSet {
            geometry.reset()
        }
    }

    func configure() {
        displayMode = .singlePageContinuous
        displayDirection = .vertical
        displaysPageBreaks = true
        autoScales = true
        interpolationQuality = .high
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

    func lines(on page: PDFPage) -> [CGRect] { geometry.lines(on: page) }

    func trimLine(_ box: CGRect, on page: PDFPage) -> CGRect { geometry.trimLine(box, on: page) }

    func pageText(_ page: PDFPage) -> PageText { geometry.pageText(page) }

    func chars(in rects: [Rect], on page: PDFPage) -> IndexSet { geometry.chars(in: rects, on: page) }

    func lineBoxes(for range: Range<Int>, on page: PDFPage) -> [(rect: CGRect, text: String)] { geometry.lineBoxes(for: range, on: page) }

    func chars(of selection: PDFSelection, on page: PDFPage) -> IndexSet { geometry.chars(of: selection, on: page) }

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
                        VStack(spacing: 14) {
                            Text(Branding.displayName)
                                .font(.largeTitle.weight(.semibold))
                            Text("Open a PDF to read, highlight, and keep notes.")
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            Button("Open PDF…") { model.openPanel() }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                        }
                        .padding(32)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.background)
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
                        PageLabelText(page: model.pageState)
                    }
                    ToolbarItemGroup {
                        Toggle(isOn: $model.highlighterOn) {
                            Label("Highlighter", systemImage: "highlighter")
                        }
                        .toggleStyle(.button)
                        .disabled(model.document == nil)
                        .help(model.highlighterOn ? "Highlighter on: selected text is highlighted \(model.penColor.name). Esc turns it off."
                                                  : "Highlighter off: turn on to highlight text as you select it")
                        ForEach(HighlightColor.highlightColors, id: \.self) { c in
                            Button { model.toolbarColor(c) } label: {
                                ColorDot(color: c, current: model.penColor == c, armed: model.highlighterOn)
                            }
                            .accessibilityLabel(c.name.capitalized)
                            .disabled(model.document == nil)
                            .help("\(c.name.capitalized) (⌘\(c.rawValue))")
                        }
                    }
                    ToolbarItemGroup {
                        ControlGroup {
                            Button { model.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                                .help("Zoom out (Cmd+-)")
                                .disabled(model.document == nil)
                            Button { model.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                                .help("Zoom in (Cmd+=)")
                                .disabled(model.document == nil)
                        }
                        Button { model.showHighlightList() } label: {
                            Label("Highlights", systemImage: "list.bullet.rectangle")
                        }
                        .help("List highlights by color, section and page (⇧⌘H)")
                        Toggle(isOn: $model.notesShown) { Label("Notes", systemImage: "note.text") }
                            .toggleStyle(.button)
                            .disabled(model.document == nil)
                            .help("Show the markdown notes for this section (Cmd+Option+N)")
                        Menu {
                            Button("Actual Size") { model.actualSize() }
                            Button("Fit Width") { model.fitWidth() }
                        } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                            .disabled(model.document == nil)
                            .help("Zoom options")
                    }
                }
        }
        .searchable(text: $model.query, placement: .toolbar, prompt: SidebarView.searchPlaceholder)
        .onSubmit(of: .search) {
            model.showResultsPanel = true
            model.moveResult(1)
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
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(item == .divider ? [] : .isButton)
        .accessibilityLabel(label)
        .accessibilityAction { model.barAction(item) }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: hovering)
    }

    private var label: String {
        switch item {
        case .color(let c): return c.name.capitalized
        case .divider: return ""
        case .erase: return "Remove highlighting"
        case .note: return model.selected?.note.isEmpty == false ? "Edit note" : "Add note"
        case .copy: return "Copy highlighted text"
        case .delete: return "Delete highlight"
        }
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

private struct PageLabelText: View {
    @ObservedObject var page: PageState

    var body: some View {
        Text(page.label.isEmpty ? " " : page.label).monospacedDigit()
    }
}
