import FACore
import PDFKit
import SwiftUI

func swatch(_ c: HighlightColor) -> Color {
    let (r, g, b) = c.rgb
    return Color(red: r, green: g, blue: b)
}

struct SidebarView: View {
    static let searchPlaceholder = "Search book, highlights, notes"
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("Sidebar", selection: $model.pagesOnly) {
                Image(systemName: "list.bullet").help("Chapters and result text").tag(false)
                Image(systemName: "rectangle.grid.1x2").help("Page images only").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()
            if model.isSearching {
                SearchResultsView(model: model, pagesOnly: model.pagesOnly)
            } else if model.pagesOnly {
                GeometryReader { geo in
                    PageThumbnails(pdfView: model.pdfView, width: geo.size.width)
                }
            } else {
                chapters
            }
            if !model.pagesOnly {
                Divider()
                footer
            }
        }
    }

    private var chapters: some View {
        VStack(spacing: 0) {
            TextField("Go to page (book page, or pdf 12)", text: $model.goToText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.goToEntered() }
                .padding(10)
            List(model.sections) { s in
                Text(s.title)
                    .fontWeight(s.parent == nil ? .semibold : .regular)
                    .padding(.leading, s.parent == nil ? 0 : 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { model.goTo(page: s.start) }
            }
            .listStyle(.sidebar)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let (done, total) = model.indexProgress {
                Text("Indexing book text \(done)/\(total)")
            }
            if let last = model.lastSync {
                Text("Synced from \(model.syncedDevices) other device\(model.syncedDevices == 1 ? "" : "s") at \(last.formatted(date: .omitted, time: .shortened))")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
    }
}

struct SearchResultsView: View {
    @ObservedObject var model: AppModel
    let pagesOnly: Bool
    var onClose: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !pagesOnly {
                VStack(alignment: .leading, spacing: 4) {
                    filters
                    if let ms = model.searchMs {
                        Text("\(model.results.count) results, \(String(format: "%.1f", ms)) ms")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
            }
            ScrollViewReader { proxy in
                List(model.results, selection: $model.selectedResultID) { r in
                    row(r).tag(r.id)
                }
                .listStyle(.sidebar)
                .onChange(of: model.selectedResultID) { _, id in
                    guard let id else { return }
                    model.openSelectedResult()
                    proxy.scrollTo(id)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ r: SearchResult) -> some View {
        if pagesOnly {
            ResultThumbnail(model: model, result: r, width: nil)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
                .help("\(model.label(r.page)): \(r.snippet.replacingOccurrences(of: Searcher.matchStart, with: "").replacingOccurrences(of: Searcher.matchEnd, with: ""))")
        } else {
            HStack(alignment: .top, spacing: 8) {
                ResultThumbnail(model: model, result: r, width: 64)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: icon(r.kind)).foregroundStyle(.secondary)
                        if let c = r.color {
                            Circle().fill(swatch(c)).frame(width: 9, height: 9)
                        }
                        Text(model.label(r.page)).foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    Text(model.styled(r.snippet)).lineLimit(4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var filters: some View {
        HStack(spacing: 4) {
            Picker("Color", selection: $model.colorFilter) {
                Text("Any color").tag(HighlightColor?.none)
                ForEach(HighlightColor.highlightColors, id: \.self) { c in
                    Text(c.name.capitalized).tag(HighlightColor?.some(c))
                }
            }
            Picker("Section", selection: $model.sectionFilter) {
                Text("Any section").tag(Int?.none)
                ForEach(model.sections) { s in
                    Text(s.title).tag(Int?.some(s.id))
                }
            }
            Picker("Tag", selection: $model.tagFilter) {
                Text("Any tag").tag(String?.none)
                ForEach(model.tags, id: \.self) { t in
                    Text("#\(t)").tag(String?.some(t))
                }
            }
            if let onClose {
                Button(action: onClose) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Hide results (Cmd+G still steps through them)")
            }
        }
        .labelsHidden()
        .controlSize(.small)
    }

    private func icon(_ kind: ResultKind) -> String {
        switch kind {
        case .book: "book"
        case .highlight: "highlighter"
        case .note: "note.text"
        }
    }
}

struct ResultThumbnail: View {
    @ObservedObject var model: AppModel
    let result: SearchResult
    let width: CGFloat?
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Rectangle().fill(.quaternary).aspectRatio(0.78, contentMode: .fit)
            }
        }
        .frame(width: width)
        .overlay(Rectangle().stroke(.separator, lineWidth: 0.5))
        .task(id: "\(result.id)|\(model.query)") {
            let terms = PageMatches.terms(model.query)
            image = await model.thumbnailer?.thumbnail(page: result.page, marks: model.marks(for: result), terms: terms)
        }
    }
}

struct PageThumbnails: NSViewRepresentable {
    let pdfView: PDFView
    let width: CGFloat

    func makeNSView(context: Context) -> PDFThumbnailView {
        let view = PDFThumbnailView()
        view.pdfView = pdfView
        view.maximumNumberOfColumns = 1
        view.backgroundColor = .clear
        view.thumbnailSize = CGSize(width: 110, height: 142)
        return view
    }

    func updateNSView(_ view: PDFThumbnailView, context: Context) {
        let width = max(60, self.width - 30)
        let size = CGSize(width: width, height: width * 1.3)
        if abs(view.thumbnailSize.width - size.width) > 4 { view.thumbnailSize = size }
    }
}
