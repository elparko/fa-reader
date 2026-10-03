import AppKit
import FACore
import SwiftUI

/// Filters, grouping and order of the highlights list in the sidebar.
@MainActor
final class HighlightBrowser: ObservableObject {
    @Published var colors: Set<HighlightColor> = []
    @Published var sectionID: Int?
    @Published var from = ""
    @Published var to = ""
    @Published var text = ""
    @Published var tag: String?
    @Published var withNotes = false
    @Published var selectedID: String?
    @Published var grouping = HighlightGrouping(rawValue: UserDefaults.standard.integer(forKey: "listGrouping")) ?? .section {
        didSet { save(grouping.rawValue, "listGrouping") }
    }
    @Published var order = HighlightOrder(rawValue: UserDefaults.standard.integer(forKey: "listOrder")) ?? .book {
        didSet { save(order.rawValue, "listOrder") }
    }
    @Published var showContext = UserDefaults.standard.object(forKey: "listContext") as? Bool ?? true {
        didSet { save(showContext, "listContext") }
    }

    private func save(_ value: Any, _ key: String) {
        if !AppModel.shared.isTestRun { UserDefaults.standard.set(value, forKey: key) }
    }

    var isFiltered: Bool {
        !colors.isEmpty || sectionID != nil || !from.isEmpty || !to.isEmpty || !text.isEmpty || tag != nil || withNotes
    }

    func reset() {
        colors = []
        sectionID = nil
        from = ""
        to = ""
        text = ""
        tag = nil
        withNotes = false
    }
}

extension AppModel {
    /// A section's pages; a top-level section with subsections covers all of them.
    func pages(ofSection id: Int) -> ClosedRange<Int>? {
        guard let s = sections.first(where: { $0.id == id }) else { return nil }
        if s.parent == nil, let last = sections.last(where: { $0.parent == s.title }) { return s.start...max(s.end, last.end) }
        return s.pages
    }

    var browserFilter: HighlightFilter {
        var range = browser.sectionID.flatMap(pages(ofSection:))
        let from = pageIndex(for: browser.from), to = pageIndex(for: browser.to)
        if from != nil || to != nil {
            let lo = from ?? 0, hi = to ?? max(0, pageCount - 1)
            let typed = min(lo, hi)...max(lo, hi)
            if let r = range {
                let a = max(r.lowerBound, typed.lowerBound), b = min(r.upperBound, typed.upperBound)
                range = a <= b ? a...b : -1 ... -1
            } else {
                range = typed
            }
        }
        return HighlightFilter(colors: browser.colors, pages: range, tag: browser.tag, text: browser.text, withNotes: browser.withNotes)
    }

    var browserGroups: [HighlightGroup] {
        HighlightList.groups(HighlightList.filter(allHighlights, browserFilter), by: browser.grouping, order: browser.order,
                             sections: sections, pageLabel: { [unowned self] in label($0) })
    }

    func showHighlightList() {
        if !isTestRun {
            let shown = UserDefaults.standard.bool(forKey: "sidebarShown")
            if shown, sidebarMode == .highlights {
                UserDefaults.standard.set(false, forKey: "sidebarShown")
                return
            }
            UserDefaults.standard.set(true, forKey: "sidebarShown")
        }
        sidebarMode = .highlights
    }

    func setColor(_ id: String, _ color: HighlightColor) {
        guard let store else { return }
        commit { confirmed in try store.setColor([id], color, confirmed: confirmed) }
    }

    func copyMarkdown(_ groups: [HighlightGroup]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(HighlightList.markdown(groups, pageLabel: { [unowned self] in label($0) }), forType: .string)
    }

    func sectionTitle(_ page: Int) -> String? { Sections.section(for: page, in: sections)?.title }
}

struct HighlightsPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var browser: HighlightBrowser

    var body: some View {
        let groups = model.browserGroups
        let shown = groups.reduce(0) { $0 + $1.highlights.count }
        VStack(spacing: 0) {
            controls(groups: groups, shown: shown)
            Divider()
            if model.allHighlights.isEmpty {
                empty("No highlights yet", "Select text and pick a color in the bar that pops up.")
            } else if groups.isEmpty {
                VStack(spacing: 8) {
                    empty("No highlights match", "")
                    Button("Clear Filters") { browser.reset() }
                }
            } else {
                list(groups)
            }
        }
    }

    private func empty(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.headline).foregroundStyle(.secondary)
            if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center) }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Controls

    private func controls(groups: [HighlightGroup], shown: Int) -> some View {
        let counts = HighlightList.counts(model.allHighlights)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter highlights and notes", text: $browser.text)
                    .textFieldStyle(.plain)
                if !browser.text.isEmpty {
                    Button { browser.text = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))

            HStack(spacing: 4) {
                ForEach(HighlightColor.highlightColors, id: \.self) { c in
                    colorChip(c, count: counts[c] ?? 0)
                }
                Spacer(minLength: 2)
                optionsMenu(groups)
            }

            HStack(spacing: 4) {
                sectionMenu
                Spacer(minLength: 2)
                TextField("from", text: $browser.from)
                    .frame(width: 46)
                    .help("First page: a book page (346) or a PDF page (pdf 367)")
                Text("–").foregroundStyle(.secondary)
                TextField("to", text: $browser.to)
                    .frame(width: 46)
                    .help("Last page: a book page (346) or a PDF page (pdf 367)")
            }
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)

            HStack {
                Text(browser.isFiltered ? "\(shown) of \(model.allHighlights.count) highlights" : "\(shown) highlight\(shown == 1 ? "" : "s")")
                if let tag = browser.tag { Text("#\(tag)").foregroundStyle(Color.accentColor) }
                Spacer()
                if browser.isFiltered {
                    Button("Clear Filters") { browser.reset() }.buttonStyle(.link)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(10)
    }

    private func colorChip(_ c: HighlightColor, count: Int) -> some View {
        let on = browser.colors.contains(c)
        return Button {
            if on { browser.colors.remove(c) } else { browser.colors.insert(c) }
        } label: {
            HStack(spacing: 3) {
                Circle().fill(swatch(c)).frame(width: 11, height: 11)
                Text("\(count)").font(.caption.monospacedDigit())
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(on ? swatch(c).opacity(0.35) : Color.primary.opacity(0.05), in: Capsule())
            .overlay(Capsule().strokeBorder(on ? swatch(c) : Color.clear, lineWidth: 1.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(on ? "Showing \(c.name). Click to stop filtering by it." : "Show only \(c.name) (combine colors by clicking more)")
    }

    private var sectionMenu: some View {
        let current = Sections.section(for: model.currentPageIndex, in: model.sections)
        let title = browser.sectionID.flatMap { id in model.sections.first { $0.id == id }?.title } ?? "Whole book"
        return Menu {
            Button("Whole book") { browser.sectionID = nil }
            if let current {
                Button("This section: \(current.title)") { browser.sectionID = current.id }
            }
            Divider()
            ForEach(model.sections.filter { $0.parent == nil }) { top in
                let children = model.sections.filter { $0.parent == top.title }
                if children.isEmpty {
                    Button(top.title) { browser.sectionID = top.id }
                } else {
                    Menu(top.title) {
                        Button("All of \(top.title)") { browser.sectionID = top.id }
                        Divider()
                        ForEach(children) { child in
                            Button(child.title) { browser.sectionID = child.id }
                        }
                    }
                }
            }
        } label: {
            Text(title).lineLimit(1).truncationMode(.middle)
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
        .help("Show highlights from one section")
    }

    private func optionsMenu(_ groups: [HighlightGroup]) -> some View {
        Menu {
            Picker("Group by", selection: $browser.grouping) {
                ForEach(HighlightGrouping.allCases) { Text($0.name).tag($0) }
            }
            Picker("Sort", selection: $browser.order) {
                ForEach(HighlightOrder.allCases) { Text($0.name).tag($0) }
            }
            Divider()
            Toggle("Only Highlights with Notes", isOn: $browser.withNotes)
            if !model.tags.isEmpty {
                Picker("Tag", selection: $browser.tag) {
                    Text("Any tag").tag(String?.none)
                    ForEach(model.tags, id: \.self) { Text("#\($0)").tag(String?.some($0)) }
                }
            }
            Toggle("Show Page Images", isOn: $browser.showContext)
            Divider()
            Button("Copy List as Markdown") { model.copyMarkdown(groups) }
            Button("Tidy Overlapping Highlights…") { model.tidyHighlights() }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Group, sort, tag filter, page images, copy, tidy")
    }

    // MARK: List

    private func list(_ groups: [HighlightGroup]) -> some View {
        ScrollViewReader { proxy in
            List(selection: $browser.selectedID) {
                ForEach(groups) { g in
                    if g.title.isEmpty {
                        rows(g)
                    } else {
                        Section {
                            rows(g)
                        } header: {
                            HStack(spacing: 5) {
                                if let c = g.color { Circle().fill(swatch(c)).frame(width: 9, height: 9) }
                                Text(g.title).lineLimit(1)
                                Spacer()
                                Text("\(g.highlights.count)").monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .onChange(of: browser.selectedID) { _, id in
                guard let id, id != model.selectedID, let h = model.allHighlights.first(where: { $0.id == id }) else { return }
                model.goToHighlight(id: id, page: h.page)
            }
            .onChange(of: model.selectedID) { _, id in
                guard let id, browser.selectedID != id else { return }
                browser.selectedID = id
                withAnimation { proxy.scrollTo(id) }
            }
        }
    }

    private func rows(_ g: HighlightGroup) -> some View {
        ForEach(g.highlights) { h in
            HighlightRow(model: model, highlight: h, showContext: browser.showContext,
                         showSection: browser.grouping != .section)
                .tag(h.id)
                .id(h.id)
                .contextMenu { menu(h) }
        }
    }

    @ViewBuilder
    private func menu(_ h: Highlight) -> some View {
        ForEach(HighlightColor.highlightColors, id: \.self) { c in
            Button("Make \(c.name.capitalized)") { model.setColor(h.id, c) }
                .disabled(h.highlightColor == c)
        }
        Divider()
        Button("Edit Note") {
            model.goToHighlight(id: h.id, page: h.page)
            model.focusNote()
        }
        Button("Copy Text") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(h.text, forType: .string)
        }
        Divider()
        Button("Delete Highlight", role: .destructive) { model.delete(h.id) }
    }
}

private struct HighlightRow: View {
    let model: AppModel
    let highlight: Highlight
    let showContext: Bool
    let showSection: Bool

    var body: some View {
        let h = highlight
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(swatch(h.highlightColor))
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 4) {
                Text(h.highlightColor == .noteOnly && h.text.isEmpty ? "Note" : h.text)
                    .font(.callout)
                    .lineLimit(5)
                if !h.note.isEmpty {
                    Label {
                        Text(h.note).lineLimit(4)
                    } icon: {
                        Image(systemName: "note.text")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if showContext, h.highlightColor != .noteOnly, !h.rects.isEmpty {
                    HighlightCrop(model: model, highlight: h)
                }
                HStack(spacing: 4) {
                    Text(model.label(h.page))
                    if showSection, let title = model.sectionTitle(h.page) {
                        Text("·")
                        Text(title).lineLimit(1).truncationMode(.tail)
                    }
                    Spacer(minLength: 4)
                    Text(Date(timeIntervalSince1970: h.created), format: .dateTime.month(.abbreviated).day())
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

/// The part of the page around a highlight.
struct HighlightCrop: View {
    let model: AppModel
    let highlight: Highlight
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Rectangle().fill(.quaternary).frame(height: 48)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5))
        .task(id: "\(highlight.id)|\(highlight.color)|\(highlight.rects.hashValue)") {
            let rects = highlight.rects.map { CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h) }
            image = await model.thumbnailer?.crop(page: highlight.page, rects: rects, color: highlight.highlightColor.rgb, width: 280)
        }
    }
}
