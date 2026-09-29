import FACore
import SwiftUI

func swatch(_ c: HighlightColor) -> Color {
    let (r, g, b) = c.rgb
    return Color(red: r, green: g, blue: b)
}

struct SidebarView: View {
    @ObservedObject var model: AppModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Search book, highlights, notes", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .onChange(of: model.focusSearchTick) { searchFocused = true }
                filters
                if model.isSearching, let ms = model.searchMs {
                    Text("\(model.results.count) results, \(String(format: "%.1f", ms)) ms")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            Divider()
            if model.isSearching {
                resultsList
            } else {
                chapters
            }
            Divider()
            footer
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
        }
        .labelsHidden()
        .controlSize(.small)
    }

    private var resultsList: some View {
        List(model.results) { r in
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: icon(r.kind))
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
                if let c = r.color {
                    Circle().fill(swatch(c)).frame(width: 9, height: 9).padding(.top, 4)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.label(r.page)).font(.caption).foregroundStyle(.secondary)
                    Text(model.styled(r.snippet)).lineLimit(4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { model.open(result: r) }
        }
        .listStyle(.sidebar)
    }

    private func icon(_ kind: ResultKind) -> String {
        switch kind {
        case .book: "book"
        case .highlight: "highlighter"
        case .note: "note.text"
        }
    }

    private var chapters: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Go to page (346 or pdf 367)", text: $model.goToText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.goToEntered() }
            }
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
                Text("Synced from \(model.syncedDevices) other device\(model.syncedDevices == 1 ? "" : "s") at \(last.formatted(date: .omitted, time: .standard))")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
    }
}
