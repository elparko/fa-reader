import AppKit
import FACore
import PDFKit
import SwiftUI

final class SearchRunner: @unchecked Sendable {
    private let queue = DispatchQueue(label: "fa-reader.search")
    private let lock = NSLock()
    private var generation = 0
    private let searcher: Searcher

    init(databasePath: String) throws {
        searcher = try Searcher(databasePath: databasePath)
    }

    private var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    @discardableResult
    private func bump() -> Int {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        return generation
    }

    func cancel() { bump() }

    func run(_ text: String, filter: SearchFilter, completion: @escaping @Sendable ([SearchResult], Double) -> Void) {
        let gen = bump()
        queue.async {
            guard self.current == gen else { return }
            let start = DispatchTime.now().uptimeNanoseconds
            let out = (try? self.searcher.search(text, filter: filter)) ?? []
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
            guard self.current == gen else { return }
            completion(out, ms)
        }
    }

    func benchmark(_ queries: [String], completion: @escaping @Sendable ([Double]) -> Void) {
        queue.async {
            var times: [Double] = []
            for q in queries {
                let start = DispatchTime.now().uptimeNanoseconds
                _ = try? self.searcher.search(q)
                times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            }
            completion(times)
        }
    }
}

struct PendingUndo: Equatable {
    var sessionID: String
    var revert: Int
    var skipped: Int
    var plan: Plan

    static func == (a: PendingUndo, b: PendingUndo) -> Bool { a.sessionID == b.sessionID && a.revert == b.revert && a.skipped == b.skipped }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let pdfView = HighlightPDFView()
    private(set) var store: Store? { didSet { objectWillChange.send() } }

    @Published var document: PDFDocument?
    @Published var pdfURL: URL?
    @Published var sections: [FACore.Section] = []
    @Published var pageLabel = ""
    @Published var selectedID: String?
    @Published var selected: Highlight?
    @Published var noteDraft = ""
    @Published var noteFocused = false
    @Published var noteFocusTick = 0
    @Published var focusSearchTick = 0
    @Published var indexProgress: (Int, Int)?
    @Published var lastSync: Date?
    @Published var syncedDevices = 0
    @Published var tags: [String] = []
    @Published var goToText = ""
    @Published var showHistory = false
    @Published var history: [SessionSummary] = []
    @Published var pendingUndo: PendingUndo?
    @Published var showImport = false
    @Published var importPreview: ImportPreview?

    @Published var query = "" { didSet { runSearch() } }
    @Published var colorFilter: HighlightColor? { didSet { runSearch() } }
    @Published var sectionFilter: Int? { didSet { runSearch() } }
    @Published var tagFilter: String? { didSet { runSearch() } }
    @Published var results: [SearchResult] = []
    @Published var searchMs: Double?

    private var rendered: [Int: [Highlight]] = [:]
    private var renderedAnnotations: [Int: [PDFAnnotation]] = [:]
    private var previewRects: [Int: [CGRect]] = [:]
    private var outline: (page: PDFPage, annotation: PDFAnnotation)?
    private var runner: SearchRunner?
    private var printedCache: [Int: String?] = [:]
    private var pendingURL: URL?
    private var started = false
    private var openReported = false
    fileprivate var searchReported = false
    private var timer: Timer?
    private let arguments = CommandLine.arguments

    private var measureOpen: Bool { arguments.contains("--measure-open") }
    private var exitAfterMeasure: Bool { arguments.contains("--exit") }

    private init() {
        pdfView.configure()
        pdfView.onHit = { [weak self] id in self?.select(id) }
        if measureOpen {
            pdfView.onFirstDraw = { [weak self] in self?.reportOpenTime() }
        }
        let center = NotificationCenter.default
        center.addObserver(forName: .PDFViewPageChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePageLabel() }
        }
        center.addObserver(forName: .PDFViewSelectionChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushNote() }
        }
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
    }

    var pageCount: Int { document?.pageCount ?? 0 }

    var filter: SearchFilter {
        let pages = sectionFilter.flatMap { id in sections.first { $0.id == id }?.pages }
        return SearchFilter(color: colorFilter, pages: pages, tag: tagFilter)
    }

    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty || !filter.isEmpty }

    // MARK: Launch and open

    func start() {
        guard !started else { return }
        started = true
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sync() }
        }
        if let i = arguments.firstIndex(of: "--pdf"), i + 1 < arguments.count {
            open(URL(fileURLWithPath: arguments[i + 1]))
        } else if let last = UserDefaults.standard.string(forKey: "lastPDF"), FileManager.default.fileExists(atPath: last) {
            open(URL(fileURLWithPath: last))
        } else {
            let fallback = ("~/Library/Mobile Documents/com~apple~CloudDocs/School/MS1/Textbooks/first aid.pdf" as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: fallback) {
                open(URL(fileURLWithPath: fallback))
            } else {
                openPanel()
            }
        }
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func open(_ url: URL) {
        flushNote()
        guard let doc = PDFDocument(url: url) else {
            notify("Cannot open \(url.lastPathComponent)")
            return
        }
        let newStore: Store
        do {
            newStore = try Store(pdfURL: url, device: deviceID, deviceName: Host.current().localizedName ?? "Mac")
        } catch {
            notify("Cannot open the annotation store", info: "\(error)")
            return
        }
        select(nil)
        clearRendered()
        store = newStore
        pdfURL = url
        document = doc
        pdfView.document = doc
        printedCache = [:]
        results = []
        query = ""
        UserDefaults.standard.set(url.path, forKey: "lastPDF")
        runner = try? SearchRunner(databasePath: newStore.folder.databaseURL.path)
        loadPreviewRects()
        reconcile()
        updatePageLabel()
        sections = Sections.from(document: doc)
        refreshHistory()
        syncedDevices = otherDevices
        lastSync = Date()
        startIndexing(url: url, pageCount: doc.pageCount)
        if let pending = pendingURL {
            pendingURL = nil
            handle(url: pending)
        }
    }

    private var deviceID: String {
        if let id = UserDefaults.standard.string(forKey: "deviceID") { return id }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: "deviceID")
        return id
    }

    private func clearRendered() {
        rendered = [:]
        renderedAnnotations = [:]
        previewRects = [:]
        outline = nil
    }

    // MARK: Timing

    private func processStartMs() -> Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        sysctl(&mib, 4, &info, &size, nil, 0)
        let t = info.kp_proc.p_un.__p_starttime
        return Double(t.tv_sec) * 1000 + Double(t.tv_usec) / 1000
    }

    private func reportOpenTime() {
        pdfView.onFirstDraw = nil
        let ms = Date().timeIntervalSince1970 * 1000 - processStartMs()
        print("open_ms=\(Int(ms.rounded()))")
        fflush(stdout)
        openReported = true
        exitIfDone()
    }

    fileprivate func exitIfDone() {
        let waitingForOpen = measureOpen && !openReported
        let waitingForSearch = arguments.contains("--measure-search") && !searchReported
        if exitAfterMeasure, !waitingForOpen, !waitingForSearch { exit(0) }
    }

    private func runSearchMeasurement() {
        guard arguments.contains("--measure-search"), let runner else { return }
        let words = ["thyroid hormone", "myocardial infarction", "renal tubular acidosis", "beta blocker", "hepatitis virus",
                     "cranial nerve", "insulin receptor", "collagen synthesis", "pulmonary embolism", "aminoglycoside toxicity"]
        var queries: [String] = []
        outer: for w in words {
            for n in 1...w.count {
                queries.append(String(w.prefix(n)))
                if queries.count == 100 { break outer }
            }
        }
        runner.benchmark(queries) { times in
            let sorted = times.sorted()
            let p50 = sorted[sorted.count / 2]
            let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            print(String(format: "search_ms n=%d p50=%.2f p95=%.2f", sorted.count, p50, p95))
            fflush(stdout)
            Task { @MainActor in
                AppModel.shared.searchReported = true
                AppModel.shared.exitIfDone()
            }
        }
    }

    // MARK: Book index

    private func startIndexing(url: URL, pageCount: Int) {
        guard let dbPath = store?.folder.databaseURL.path else { return }
        indexProgress = nil
        DispatchQueue.global(qos: .utility).async {
            do {
                let db = try Database(path: dbPath)
                if try !BookIndex.isIndexed(db: db, pageCount: pageCount) {
                    guard let doc = PDFDocument(url: url) else { return }
                    try BookIndex.index(document: doc, into: db) { done, total in
                        DispatchQueue.main.async { MainActor.assumeIsolated { AppModel.shared.indexProgress = (done, total) } }
                    }
                }
            } catch {
                DispatchQueue.main.async { MainActor.assumeIsolated { AppModel.shared.indexProgress = nil } }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let model = AppModel.shared
                    model.indexProgress = nil
                    model.printedCache = [:]
                    model.updatePageLabel()
                    model.runSearchMeasurement()
                }
            }
        }
    }

    // MARK: Pages and labels

    func printed(_ page: Int) -> String? {
        if let cached = printedCache[page] { return cached }
        guard let store else { return nil }
        let value = (try? BookIndex.printedPage(db: store.db, page: page)) ?? nil
        printedCache[page] = .some(value)
        return value
    }

    func label(_ page: Int) -> String {
        printed(page).map { "p. \($0)" } ?? "PDF \(page + 1)"
    }

    var currentPageIndex: Int {
        guard let doc = document, let page = pdfView.currentPage else { return 0 }
        return doc.index(for: page)
    }

    func updatePageLabel() {
        guard document != nil else { pageLabel = ""; return }
        let index = currentPageIndex
        let pdf = "PDF \(index + 1) of \(pageCount)"
        pageLabel = printed(index).map { "p. \($0) · \(pdf)" } ?? pdf
    }

    func goTo(page: Int) {
        guard let p = document?.page(at: page) else { return }
        pdfView.go(to: p)
    }

    func goToEntered() {
        let text = goToText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        if text.lowercased().hasPrefix("pdf") {
            if let n = Int(text.dropFirst(3).trimmingCharacters(in: .whitespaces)), (1...max(1, pageCount)).contains(n) {
                goTo(page: n - 1)
            } else {
                NSSound.beep()
            }
            return
        }
        if let store, let page = (try? BookIndex.pdfPage(forPrinted: text, db: store.db)) ?? nil {
            goTo(page: page)
        } else if let n = Int(text), (1...max(1, pageCount)).contains(n) {
            goTo(page: n - 1)
        } else {
            NSSound.beep()
        }
    }

    // MARK: Zoom

    func zoomIn() { pdfView.autoScales = false; pdfView.zoomIn(nil) }
    func zoomOut() { pdfView.autoScales = false; pdfView.zoomOut(nil) }
    func actualSize() { pdfView.autoScales = false; pdfView.scaleFactor = 1 }
    func fitWidth() { pdfView.autoScales = true }

    // MARK: Rendering highlights

    private func color(_ c: HighlightColor, alpha: CGFloat = 1) -> NSColor {
        let (r, g, b) = c.rgb
        return NSColor(srgbRed: r, green: g, blue: b, alpha: alpha)
    }

    private func annotations(for h: Highlight) -> [PDFAnnotation] {
        let name = "fa:\(h.id)"
        if h.highlightColor == .noteOnly {
            let r = h.rects.first ?? Rect(x: 20, y: 20, w: 20, h: 20)
            let a = PDFAnnotation(bounds: CGRect(x: r.x, y: r.y + r.h - 20, width: 20, height: 20), forType: .text, withProperties: nil)
            a.color = color(.yellow)
            a.contents = h.note.isEmpty ? h.text : h.note
            a.userName = name
            return [a]
        }
        return h.rects.map { r in
            let bounds = CGRect(x: r.x, y: r.y, width: r.w, height: r.h)
            let a = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
            a.color = color(h.highlightColor, alpha: 0.6)
            a.quadrilateralPoints = [
                NSValue(point: CGPoint(x: 0, y: bounds.height)), NSValue(point: CGPoint(x: bounds.width, y: bounds.height)),
                NSValue(point: CGPoint(x: 0, y: 0)), NSValue(point: CGPoint(x: bounds.width, y: 0)),
            ]
            a.contents = h.note
            a.userName = name
            return a
        }
    }

    private func render(page index: Int, highlights: [Highlight]) {
        guard let page = document?.page(at: index) else { return }
        for a in renderedAnnotations[index] ?? [] { page.removeAnnotation(a) }
        var added: [PDFAnnotation] = []
        for h in highlights { added += annotations(for: h) }
        for a in added { page.addAnnotation(a) }
        renderedAnnotations[index] = added.isEmpty ? nil : added
        rendered[index] = highlights.isEmpty ? nil : highlights
        pdfView.annotationsChanged(on: page)
    }

    func reconcile() {
        guard let store else { return }
        let all = (try? store.highlights()) ?? []
        let byPage = Dictionary(grouping: all, by: \.page)
        for page in Set(rendered.keys).union(byPage.keys) {
            let new = byPage[page] ?? []
            if rendered[page] ?? [] != new { render(page: page, highlights: new) }
        }
        tags = (try? store.allTags()) ?? []
        refreshSelected()
    }

    private func loadPreviewRects() {
        guard let store, let document else { return }
        let ids = (try? store.importedHighlightIDs()) ?? []
        guard !ids.isEmpty else { return }
        let rows = (try? store.db.query("SELECT body FROM ops WHERE kind='add' AND highlight LIKE 'pv-%'")) ?? []
        var map: [Int: [CGRect]] = [:]
        for row in rows {
            guard let op = try? JSONDecoder().decode(Op.self, from: Data(row.string("body").utf8)),
                  ids.contains(op.highlight), let snap = op.snapshot else { continue }
            let union = snap.rects.map { CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h) }.reduce(CGRect.null) { $0.union($1) }
            if !union.isNull { map[op.page, default: []].append(union) }
        }
        previewRects = map
        for (index, rects) in map {
            guard let page = document.page(at: index) else { continue }
            var changed = false
            for a in page.annotations where a.userName?.hasPrefix("fa") != true {
                guard let type = a.type, ["Highlight", "FreeText", "Text"].contains(where: { type.hasSuffix($0) }) else { continue }
                if rects.contains(where: { close($0, a.bounds) }) {
                    page.removeAnnotation(a)
                    changed = true
                }
            }
            if changed { pdfView.annotationsChanged(on: page) }
        }
    }

    private func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 4 && abs(a.maxX - b.maxX) < 4 && abs(a.minY - b.minY) < 4 && abs(a.maxY - b.maxY) < 4
    }

    // MARK: Selection and editing

    func select(_ id: String?) {
        if id == selectedID { return }
        flushNote()
        selectedID = id
        selected = id.flatMap { try? store?.highlight(id: $0) } ?? nil
        if selected == nil { selectedID = nil }
        noteDraft = selected?.note ?? ""
        updateOutline()
    }

    private func refreshSelected() {
        guard let id = selectedID else { return }
        guard let fresh = (try? store?.highlight(id: id)) ?? nil else {
            selectedID = nil
            selected = nil
            noteDraft = ""
            updateOutline()
            return
        }
        if noteDraft == selected?.note { noteDraft = fresh.note }
        if selected != fresh {
            selected = fresh
            updateOutline()
        }
    }

    private func updateOutline() {
        if let o = outline {
            o.page.removeAnnotation(o.annotation)
            pdfView.annotationsChanged(on: o.page)
            outline = nil
        }
        guard let h = selected, let page = document?.page(at: h.page), !h.rects.isEmpty else { return }
        let union = h.rects.map { CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h) }.reduce(CGRect.null) { $0.union($1) }
        let a = PDFAnnotation(bounds: union.insetBy(dx: -2, dy: -2), forType: .square, withProperties: nil)
        a.color = .controlAccentColor
        let border = PDFBorder()
        border.lineWidth = 1.5
        a.border = border
        a.userName = "fa-selection"
        page.addAnnotation(a)
        pdfView.annotationsChanged(on: page)
        outline = (page, a)
    }

    func flushNote() {
        guard let id = selectedID, let h = selected, noteDraft != h.note, let store else { return }
        let draft = noteDraft
        commit { _ in try store.setNote(id, draft) }
    }

    func focusNote() {
        guard selectedID != nil else { return }
        noteFocusTick += 1
    }

    func applyColor(_ color: HighlightColor) {
        if let selection = pdfView.currentSelection, !(selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            highlightSelection(selection, color: color)
        } else if let id = selectedID, let store, selected?.highlightColor != .noteOnly {
            commit { confirmed in try store.setColor([id], color, confirmed: confirmed) }
        }
    }

    private func highlightSelection(_ selection: PDFSelection, color: HighlightColor) {
        guard let store, let document else { return }
        var rects: [Int: [Rect]] = [:]
        var texts: [Int: [String]] = [:]
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let b = line.bounds(for: page)
                guard b.width >= 1, b.height >= 1 else { continue }
                let index = document.index(for: page)
                rects[index, default: []].append(Rect(x: b.minX, y: b.minY, w: b.width, h: b.height))
                if let s = line.string { texts[index, default: []].append(s) }
            }
        }
        let made = rects.keys.sorted().map { index in
            let text = (texts[index] ?? []).joined(separator: " ").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            return Highlight(page: index, rects: rects[index] ?? [], text: text, color: color)
        }
        guard !made.isEmpty else { return }
        if commit({ confirmed in try store.add(made, confirmed: confirmed) }) { pdfView.clearSelection() }
    }

    func deleteSelected() {
        guard let id = selectedID, let store else { return }
        commit { confirmed in try store.delete([id], confirmed: confirmed) }
    }

    @discardableResult
    func commit(_ body: (Bool) throws -> Void) -> Bool {
        do {
            try body(false)
        } catch GuardError.needsConfirmation(let pages) {
            guard confirm("This will change \(pages) pages. Continue?") else { return false }
            do { try body(true) } catch { notify("Change failed", info: "\(error)"); return false }
        } catch {
            notify("Change failed", info: "\(error)")
            return false
        }
        reconcile()
        refreshHistory()
        return true
    }

    func confirm(_ message: String, ok: String = "Continue") -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: ok)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func notify(_ message: String, info: String = "") {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.runModal()
    }

    // MARK: Navigation to highlights and results

    func goToHighlight(id: String, page: Int) {
        goTo(page: page)
        select(id)
        guard let h = selected, let first = h.rects.first, let p = document?.page(at: h.page) else { return }
        pdfView.go(to: PDFDestination(page: p, at: CGPoint(x: max(0, first.x - 40), y: first.y + first.h + 120)))
    }

    func open(result r: SearchResult) {
        if let id = r.highlightID {
            goToHighlight(id: id, page: r.page)
        } else {
            goTo(page: r.page)
            showMatch(page: r.page)
        }
    }

    private func showMatch(page index: Int) {
        let term = query.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).first.map(String.init) ?? ""
        guard !term.isEmpty, let page = document?.page(at: index), let text = page.string,
              let range = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]),
              let selection = page.selection(for: NSRange(range, in: text)) else { return }
        pdfView.setCurrentSelection(selection, animate: true)
    }

    func handle(url: URL) {
        guard url.scheme == "fa-reader" else { return }
        guard store != nil else { pendingURL = url; return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let page = items.first { $0.name == "page" }?.value.flatMap(Int.init)
        let id = items.first { $0.name == "highlight" }?.value
        if let id, let h = try? store?.highlight(id: id) {
            goToHighlight(id: id, page: h.page)
        } else if let page {
            goTo(page: page - 1)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Search

    func runSearch() {
        guard let runner else { return }
        let text = query.trimmingCharacters(in: .whitespaces)
        let filter = self.filter
        guard !text.isEmpty || !filter.isEmpty else {
            runner.cancel()
            results = []
            searchMs = nil
            return
        }
        runner.run(text, filter: filter) { [weak self] found, ms in
            Task { @MainActor in
                self?.results = found
                self?.searchMs = ms
            }
        }
    }

    func styled(_ snippet: String) -> AttributedString {
        var out = AttributedString()
        var buffer = ""
        var bold = false
        func flush() {
            var piece = AttributedString(buffer)
            if bold { piece.font = .body.bold() }
            out += piece
            buffer = ""
        }
        for ch in snippet {
            if String(ch) == Searcher.matchStart {
                flush()
                bold = true
            } else if String(ch) == Searcher.matchEnd {
                flush()
                bold = false
            } else {
                buffer.append(ch)
            }
        }
        flush()
        return out
    }

    // MARK: Sync

    private var otherDevices: Int {
        guard let store else { return 0 }
        return store.folder.logFiles().filter { $0.deletingPathExtension().lastPathComponent != store.device }.count
    }

    func sync() {
        guard let store else { return }
        let changed = (try? store.sync()) ?? 0
        lastSync = Date()
        syncedDevices = otherDevices
        if changed > 0 {
            loadPreviewRects()
            reconcile()
            refreshHistory()
        }
    }

    // MARK: History

    func refreshHistory() {
        history = (try? store?.sessions()) ?? []
    }

    func prepareUndo(_ session: SessionSummary) {
        guard let store, let plan = try? store.undoPlan(session: session.id) else { return }
        pendingUndo = PendingUndo(sessionID: session.id, revert: plan.ops.count, skipped: plan.skipped, plan: plan)
    }

    func confirmUndo() {
        guard let store, let pending = pendingUndo else { return }
        if commit({ confirmed in try store.commit(pending.plan, confirmed: confirmed) }) { pendingUndo = nil }
    }

    // MARK: Import

    func beginImport() {
        guard store != nil, let url = pdfURL else { return }
        importPreview = nil
        showImport = true
        Task { @MainActor in
            await Task.yield()
            guard let store = self.store, let fresh = PDFDocument(url: url) else { return }
            do {
                self.importPreview = try PreviewImporter.preview(document: fresh, store: store)
            } catch {
                self.showImport = false
                self.notify("Scan failed", info: "\(error)")
            }
        }
    }

    func runImport(_ preview: ImportPreview, bursts: Set<Int>) {
        guard let store else { return }
        let plan = preview.plan(includingBursts: bursts)
        if commit({ confirmed in try store.commit(plan, confirmed: confirmed) }) {
            loadPreviewRects()
            showImport = false
        }
    }

    // MARK: Export

    private var exportDirectory: URL? {
        if let path = UserDefaults.standard.string(forKey: "exportFolder") { return URL(fileURLWithPath: path, isDirectory: true) }
        return store?.folder.markdownURL
    }

    func chooseExportFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { UserDefaults.standard.set(url.path, forKey: "exportFolder") }
    }

    func exportMarkdown() {
        guard let store, let dir = exportDirectory else { return }
        do {
            let result = try MarkdownExporter.export(store: store, sections: sections, to: dir) { page in
                try? BookIndex.printedPage(db: store.db, page: page)
            }
            let alert = NSAlert()
            alert.messageText = "Markdown exported"
            alert.informativeText = "\(result.written.count) written, \(result.unchanged.count) unchanged, \(result.removed.count) removed\n\(dir.path)"
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Show in Finder")
            if alert.runModal() == .alertSecondButtonReturn {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                NSWorkspace.shared.activateFileViewerSelecting([dir])
            }
        } catch {
            notify("Export failed", info: "\(error)")
        }
    }
}
