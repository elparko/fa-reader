import AppKit
import FACore
import PDFKit
import SwiftUI

final class HighlightPDFView: PDFView {
    var onHit: ((String?) -> Void)?
    var onFirstDraw: (() -> Void)?
    private var drawn = false

    func configure() {
        displayMode = .singlePageContinuous
        displayDirection = .vertical
        displaysPageBreaks = true
        autoScales = true
        minScaleFactor = 0.2
        maxScaleFactor = 8
        backgroundColor = .underPageBackgroundColor
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let page = page(for: point, nearest: false) {
            let local = convert(point, to: page)
            if let hit = page.annotations.last(where: { $0.userName?.hasPrefix("fa:") == true && $0.bounds.contains(local) }),
               let name = hit.userName {
                onHit?(String(name.dropFirst(3)))
                if hit.type?.hasSuffix("Text") == true { return }
                super.mouseDown(with: event)
                return
            }
        }
        onHit?(nil)
        super.mouseDown(with: event)
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
