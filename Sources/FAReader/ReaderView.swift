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
                .overlay {
                    if let at = model.colorPopupAt {
                        ColorPopup { model.pickColor($0) }
                            .position(at)
                    }
                }
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
    let pick: (HighlightColor) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(HighlightColor.highlightColors, id: \.self) { c in
                ColorPopupButton(color: c) { pick(c) }
            }
        }
        .frame(width: AppModel.colorPopupSize.width, height: AppModel.colorPopupSize.height)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
    }
}

private struct ColorPopupButton: View {
    let color: HighlightColor
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(swatch(color))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.15)))
                .frame(width: 20, height: 20)
                .scaleEffect(hovering ? 1.2 : 1)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
