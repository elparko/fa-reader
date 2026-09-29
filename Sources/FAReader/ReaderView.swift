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
        super.mouseDown(with: event)
        if NSEvent.pressedMouseButtons & 1 == 0 { endSelection() }
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        endSelection()
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

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
        } detail: {
            ReaderView(model: model)
                .overlay {
                    if model.document == nil {
                        VStack(spacing: 12) {
                            Text("No PDF open")
                            Button("Open…") { model.openPanel() }
                        }
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
                        Button { model.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                            .help("Zoom out")
                        Button { model.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                            .help("Zoom in")
                        Button { model.actualSize() } label: { Image(systemName: "1.magnifyingglass") }
                            .help("Actual size")
                        Button { model.fitWidth() } label: { Image(systemName: "arrow.left.and.right") }
                            .help("Zoom to fit width")
                    }
                }
                .inspector(isPresented: Binding(
                    get: { model.selected != nil },
                    set: { if !$0 { model.select(nil) } }
                )) {
                    InspectorView(model: model)
                        .inspectorColumnWidth(min: 260, ideal: 300, max: 400)
                }
        }
        .sheet(isPresented: $model.showHistory) { HistoryView(model: model) }
        .sheet(isPresented: $model.showImport) { ImportView(model: model) }
        .navigationTitle(model.bookTitle)
        .task { model.start() }
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
