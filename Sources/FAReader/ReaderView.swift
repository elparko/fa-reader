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
    private var drawn = false
    private var selecting = false
    private var lineBoxes: [ObjectIdentifier: [CGRect]] = [:]

    override var document: PDFDocument? {
        didSet { lineBoxes = [:] }
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

    private func highlightHit(_ event: NSEvent) -> PDFAnnotation? {
        let point = convert(event.locationInWindow, from: nil)
        guard let page = page(for: point, nearest: false) else { return nil }
        let local = convert(point, to: page)
        return page.annotations.last { $0.userName?.hasPrefix("fa:") == true && $0.bounds.contains(local) }
    }

    override func mouseDown(with event: NSEvent) {
        if let hit = highlightHit(event), let name = hit.userName {
            onHit?(String(name.dropFirst(3)))
            if hit.type?.hasSuffix("Text") == true { return }
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
    static func trimLine(_ box: CGRect, among lines: [CGRect]) -> CGRect {
        var r = box
        for o in lines where o != box && box.height > o.height * 1.5 && o.maxX > box.minX && o.minX < box.maxX {
            guard o.maxY > r.minY, o.minY < r.maxY else { continue }
            if o.midY < r.midY { r.origin.y = o.maxY; r.size.height = box.maxY - o.maxY } else { r.size.height = o.minY - r.minY }
        }
        return r.height >= box.height * 0.3 ? r : box
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
                setCurrentSelection(document.selection(from: start.page, at: from, to: page, at: local), animate: false)
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
        let menu = super.menu(for: event) ?? NSMenu()
        var items: [NSMenuItem] = []
        let hasText = !(currentSelection?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hit = hasText ? nil : highlightHit(event)
        if let hit, let name = hit.userName { onHit?(String(name.dropFirst(3))) }
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
        if hit != nil {
            items.append(.separator())
            let note = NSMenuItem(title: "Edit Note", action: #selector(noteFromMenu), keyEquivalent: "")
            note.target = self
            let delete = NSMenuItem(title: "Delete Highlight", action: #selector(deleteFromMenu), keyEquivalent: "")
            delete.target = self
            items += [note, delete]
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
    @objc private func deleteFromMenu() { onDelete?() }

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
                .navigationSplitViewColumnWidth(min: 110, ideal: model.pagesOnly ? 150 : 290, max: 420)
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

/// The bar of color dots that pops up over selected text.
struct ColorPopup: View {
    static let dot: CGFloat = 26
    static let gap: CGFloat = 4

    var body: some View {
        HStack(spacing: Self.gap) {
            ForEach(HighlightColor.highlightColors, id: \.self) { ColorPopupDot(color: $0) }
        }
        .frame(width: AppModel.colorPopupSize.width, height: AppModel.colorPopupSize.height)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
    }
}

/// Hosts the color popup as an AppKit subview of the PDF view and handles its clicks itself,
/// so a click works even when the window is not yet active.
final class ColorPopupHost: NSHostingView<ColorPopup> {
    var pick: ((HighlightColor) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let colors = HighlightColor.highlightColors
        let x = convert(event.locationInWindow, from: nil).x
        let left = (bounds.width - CGFloat(colors.count) * ColorPopup.dot - CGFloat(colors.count - 1) * ColorPopup.gap) / 2
        let i = Int(((x - left + ColorPopup.gap / 2) / (ColorPopup.dot + ColorPopup.gap)).rounded(.down))
        if colors.indices.contains(i) { pick?(colors[i]) }
    }
}

private struct ColorPopupDot: View {
    let color: HighlightColor
    @State private var hovering = false

    var body: some View {
        Circle()
            .fill(swatch(color))
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.15)))
            .frame(width: 20, height: 20)
            .scaleEffect(hovering ? 1.2 : 1)
            .frame(width: ColorPopup.dot, height: ColorPopup.dot)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.1), value: hovering)
            .help("\(color.name.capitalized) (\(color.rawValue))")
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
