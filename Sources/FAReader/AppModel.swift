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

enum BarMode: Equatable {
    case selection(erase: Bool), highlight
}

struct Notice: Equatable {
    var message: String
    var id = UUID()
}

enum SidebarMode: Int {
    case chapters, pages, highlights
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

    @Published var query = "" {
        didSet {
            if query != oldValue, !query.isEmpty { showResultsPanel = true }
            runSearch()
        }
    }
    @Published var showResultsPanel = false
    @Published var notesShown = UserDefaults.standard.bool(forKey: "notesShown") {
        didSet {
            if !isTestRun { UserDefaults.standard.set(notesShown, forKey: "notesShown") }
            if notesShown { refreshNotes(force: true) } else { saveNotes() }
        }
    }
    @Published var notesMode = UserDefaults.standard.integer(forKey: "notesMode") {
        didSet {
            if !isTestRun { UserDefaults.standard.set(notesMode, forKey: "notesMode") }
            marky.mode = MarkyView.Mode(rawValue: notesMode) ?? .preview
        }
    }
    @Published var notesTitle = "Notes"
    lazy var marky: MarkyView = makeMarky()
    private(set) var notesURL: URL?
    private var notesSectionID: Int?
    private var notesDirty = false
    private var notesSaveWork: DispatchWorkItem?
    private var exportWork: DispatchWorkItem?
    /// Reads and writes in the book's folder that can wait on iCloud run here, off the main thread.
    private let folderQueue = DispatchQueue(label: "fa-reader.folder", qos: .userInitiated)
    private var syncing = false
    private var popover: NSPopover?
    private var scrollObserver: Any?
    private var ignoreScrollUntil = Date.distantPast
    @Published var sidebarMode = SidebarMode(rawValue: UserDefaults.standard.integer(forKey: "sidebarMode")) ?? .chapters {
        didSet { if !isTestRun { UserDefaults.standard.set(sidebarMode.rawValue, forKey: "sidebarMode") } }
    }
    var pagesOnly: Bool { sidebarMode == .pages }
    let browser = HighlightBrowser()
    @Published private(set) var allHighlights: [Highlight] = []
    @Published private(set) var notice: Notice?
    @Published var colorFilter: HighlightColor? { didSet { runSearch() } }
    @Published var sectionFilter: Int? { didSet { runSearch() } }
    @Published var tagFilter: String? { didSet { runSearch() } }
    @Published var results: [SearchResult] = []
    @Published var highlighterOn = UserDefaults.standard.bool(forKey: "highlighterOn") {
        didSet { if !isTestRun { UserDefaults.standard.set(highlighterOn, forKey: "highlighterOn") } }
    }
    @Published var penColor = HighlightColor(rawValue: UserDefaults.standard.integer(forKey: "penColor")).flatMap { $0 == .noteOnly ? nil : $0 } ?? .yellow {
        didSet { if !isTestRun { UserDefaults.standard.set(penColor.rawValue, forKey: "penColor") } }
    }
    /// What the bar over the selected text or the selected highlight shows. Nil when there is no bar.
    @Published private(set) var barMode: BarMode?
    /// Center of the bar, in the PDF view with the origin at the top left. Nil when hidden or scrolled out of view.
    private(set) var colorPopupAt: CGPoint? { didSet { moveColorPopupView() } }
    private(set) lazy var colorPopupView: NSView = {
        let host = HighlightBarHost(rootView: HighlightBar(model: self))
        host.pick = { [weak self] in self?.barAction($0) }
        host.items = { [weak self] in self?.barItems ?? [] }
        host.frame.size = barSize
        host.wantsLayer = true
        let shadow = NSShadow()
        shadow.shadowColor = .black.withAlphaComponent(0.2)
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        host.shadow = shadow
        return host
    }()
    var barSize: CGSize { HighlightBar.size(barItems) }

    var barItems: [BarItem] {
        let colors = HighlightColor.highlightColors.map(BarItem.color)
        switch barMode {
        case .selection(let erase): return colors + (erase ? [.divider, .erase] : [])
        case .highlight: return colors + [.divider, .note, .copy, .delete]
        case nil: return colors
        }
    }
    @Published var recentBooks: [String] = UserDefaults.standard.stringArray(forKey: "recentPDFs") ?? []
    @Published var selectedResultID: String?
    private(set) var thumbnailer: Thumbnailer?
    private var keyMonitor: Any?
    @Published var searchMs: Double?

    private var rendered: [Int: [Highlight]] = [:]
    private var renderedAnnotations: [Int: [PDFAnnotation]] = [:]
    @Published private var undoStack: [[PendingOp]] = []
    @Published private var redoStack: [[PendingOp]] = []
    private var noticeWork: DispatchWorkItem?
    private var previewRects: [Int: [CGRect]] = [:]
    private var outline: (page: PDFPage, annotation: PDFAnnotation)?
    private(set) var runner: SearchRunner?
    private var printedCache: [Int: String?] = [:]
    private var pendingURL: URL?
    private var started = false
    private var openReported = false
    fileprivate var searchReported = false
    private var timer: Timer?
    private let arguments = CommandLine.arguments
    var selfCheck: SelfCheck?

    var measureOpen: Bool { arguments.contains("--measure-open") }
    var isTestRun: Bool { measureOpen || selfCheck != nil }
    private var exitAfterMeasure: Bool { arguments.contains("--exit") }

    private init() {
        pdfView.configure()
        installKeyMonitor()
        pdfView.onHit = { [weak self] id in
            self?.showResultsPanel = false
            self?.select(id)
        }
        pdfView.onSelectionEnded = { [weak self] in self?.selectionEnded() }
        pdfView.onColor = { [weak self] c in self?.applyColor(c) }
        pdfView.onEditNote = { [weak self] in self?.focusNote() }
        pdfView.onDelete = { [weak self] in self?.deleteSelected() }
        pdfView.onDeleteID = { [weak self] id in self?.delete(id) }
        pdfView.onErase = { [weak self] in self?.eraseSelection() }
        pdfView.onCopyHighlight = { [weak self] in self?.copySelectedHighlight() ?? false }
        pdfView.selectedHighlight = { [weak self] in self?.selectedID }
        pdfView.selectionTouchesHighlights = { [weak self] in self?.selectionTouchesHighlights() ?? false }
        pdfView.describeHighlight = { [weak self] id in
            guard let h = (try? self?.store?.highlight(id: id)) ?? nil else { return "Highlight" }
            let text = h.text.count > 30 ? h.text.prefix(30) + "…" : h.text
            return "“\(text)” (\(h.highlightColor.name.capitalized))"
        }
        if let i = arguments.firstIndex(of: "--self-check"), i + 1 < arguments.count {
            selfCheck = SelfCheck(report: URL(fileURLWithPath: arguments[i + 1]))
        }
        if measureOpen || selfCheck != nil {
            pdfView.onFirstDraw = { [weak self] in self?.reportOpenTime() }
        }
        let center = NotificationCenter.default
        center.addObserver(forName: .PDFViewPageChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePageLabel() }
        }
        center.addObserver(forName: .PDFViewSelectionChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushNote()
                if self?.hasTextSelection == false, case .selection = self?.barMode { self?.hideColorPopup() }
            }
        }
        center.addObserver(forName: .PDFViewScaleChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.placeColorPopup() }
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
        newStore.logQueue = folderQueue
        folderQueue.async { try? newStore.flushLog() }
        store = newStore
        undoStack = (try? newStore.recentChanges()) ?? []
        redoStack = []
        notice = nil
        let lastPage = UserDefaults.standard.object(forKey: "lastPage:\(url.path)") as? Int
        pdfURL = url
        document = doc
        pdfView.document = doc
        pdfView.autoScales = true
        watchScrolling()
        if let lastPage, let page = doc.page(at: lastPage) {
            pdfView.go(to: page)
        }
        printedCache = [:]
        results = []
        query = ""
        if !isTestRun {
            UserDefaults.standard.set(url.path, forKey: "lastPDF")
            recentBooks = [url.path] + recentBooks.filter { $0 != url.path }.prefix(9)
            UserDefaults.standard.set(recentBooks, forKey: "recentPDFs")
        }
        runner = try? SearchRunner(databasePath: newStore.folder.databaseURL.path)
        thumbnailer = Thumbnailer(url: url)
        loadPreviewRects()
        reconcile()
        updatePageLabel()
        sections = Sections.from(document: doc)
        refreshHistory()
        syncedDevices = otherDevices
        lastSync = Date()
        startIndexing(url: url, pageCount: doc.pageCount)
        notesSectionID = nil
        refreshNotes(force: true)
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
        selfCheck?.run(openMs: ms)
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
        refreshNotes()
        if let url = pdfURL, !isTestRun { UserDefaults.standard.set(index, forKey: "lastPage:\(url.path)") }
        let pdf = "PDF \(index + 1) of \(pageCount)"
        pageLabel = printed(index).map { "p. \($0) · \(index + 1)/\(pageCount)" } ?? pdf
    }

    func goTo(page: Int) {
        guard let p = document?.page(at: page) else { return }
        pdfView.go(to: p)
    }

    func goToEntered() {
        guard !goToText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if let page = pageIndex(for: goToText) { goTo(page: page) } else { beep() }
    }

    /// A PDF page index from a printed book page (`346`) or a PDF page (`pdf 367`).
    func pageIndex(for entered: String) -> Int? {
        let text = entered.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if text.lowercased().hasPrefix("pdf") {
            guard let n = Int(text.dropFirst(3).trimmingCharacters(in: .whitespaces)), (1...max(1, pageCount)).contains(n) else { return nil }
            return n - 1
        }
        if let store, let page = (try? BookIndex.pdfPage(forPrinted: text, db: store.db)) ?? nil { return page }
        if let n = Int(text), (1...max(1, pageCount)).contains(n) { return n - 1 }
        return nil
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
        if allHighlights != all { allHighlights = all }
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
            for a in page.annotations where a.userName?.hasPrefix("fa:") != true && a.userName != "fa-selection" {
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

    func select(_ id: String?, showNote: Bool = true) {
        if id == selectedID {
            if id != nil, barMode != .highlight { showHighlightBar() }
            return
        }
        flushNote()
        hideDetails()
        selectedID = id
        selected = id.flatMap { try? store?.highlight(id: $0) } ?? nil
        if selected == nil { selectedID = nil }
        noteDraft = selected?.note ?? ""
        updateOutline()
        if selected != nil {
            showHighlightBar()
            if showNote, selected?.note.isEmpty == false { showDetails() }
        } else if barMode == .highlight {
            hideColorPopup()
        }
    }

    /// Opens the note popover under the selected highlight.
    func showDetails() {
        popover?.close()
        popover = nil
        guard let h = selected, let page = document?.page(at: h.page), !h.rects.isEmpty, pdfView.window != nil else { return }
        let rect = pdfView.convert(union(h.rects), from: page)
        guard rect.intersects(pdfView.bounds) else { return }
        if isTestRun {
            detailsAnchor = rect
            return
        }
        let p = NSPopover()
        p.behavior = .applicationDefined
        p.animates = false
        p.contentViewController = NSHostingController(rootView: InspectorView(model: self).frame(width: 280))
        p.show(relativeTo: rect.intersection(pdfView.bounds), of: pdfView, preferredEdge: pdfView.isFlipped ? .maxY : .minY)
        popover = p
        ignoreScrollUntil = Date().addingTimeInterval(0.4)
    }

    func hideDetails() {
        detailsAnchor = nil
        guard let p = popover else { return }
        flushNote()
        popover = nil
        p.close()
    }

    var detailsShown: Bool { popover?.isShown ?? false }
    private(set) var detailsAnchor: CGRect?

    private func union(_ rects: [Rect]) -> CGRect {
        rects.map { CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h) }.reduce(CGRect.null) { $0.union($1) }
    }

    private func watchScrolling() {
        guard let clip = pdfView.documentView?.enclosingScrollView?.contentView, scrollObserver == nil else { return }
        clip.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { _ in
            MainActor.assumeIsolated {
                let model = AppModel.shared
                if Date() > model.ignoreScrollUntil { model.hideDetails() }
                model.placeColorPopup()
            }
        }
    }

    private func refreshSelected() {
        guard let id = selectedID else { return }
        guard let fresh = (try? store?.highlight(id: id)) ?? nil else {
            selectedID = nil
            selected = nil
            noteDraft = ""
            hideDetails()
            updateOutline()
            if barMode == .highlight { hideColorPopup() }
            return
        }
        if noteDraft == selected?.note { noteDraft = fresh.note }
        if selected != fresh {
            selected = fresh
            updateOutline()
            placeColorPopup()
        }
    }

    private func updateOutline() {
        if let o = outline {
            o.page.removeAnnotation(o.annotation)
            pdfView.annotationsChanged(on: o.page)
            outline = nil
        }
        guard let h = selected, let page = document?.page(at: h.page), !h.rects.isEmpty else { return }
        let a = PDFAnnotation(bounds: union(h.rects).insetBy(dx: -2, dy: -2), forType: .square, withProperties: nil)
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
        let opening = !detailsShown
        if opening { showDetails() }
        popover?.contentViewController?.view.window?.makeKey()
        DispatchQueue.main.asyncAfter(deadline: .now() + (opening ? 0.1 : 0)) { [weak self] in
            self?.noteFocusTick += 1
        }
    }

    var hasTextSelection: Bool {
        !(pdfView.currentSelection?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func toolbarColor(_ color: HighlightColor) {
        penColor = color
        if hasTextSelection || selectedID != nil {
            applyColor(color)
        } else {
            highlighterOn = true
        }
    }

    func selectionEnded() {
        guard hasTextSelection, let selection = pdfView.currentSelection else { return }
        select(nil)
        let lines = selection.selectionsByLine().count
        if highlighterOn, selection.pages.count == 1, lines <= Self.highlighterMaxLines {
            applyColor(penColor)
        } else {
            showSelectionBar()
        }
    }

    /// In highlighter mode a selection longer than this shows the bar instead of being highlighted at once,
    /// so a slipped drag does not paint half a page.
    static let highlighterMaxLines = 12

    func showSelectionBar() {
        barMode = .selection(erase: selectionTouchesHighlights())
        placeColorPopup()
    }

    func showHighlightBar() {
        guard selected != nil else { return }
        barMode = .highlight
        placeColorPopup()
    }

    /// Puts the bar above the selected text or highlight, or below it when there is no room above.
    /// Hides it while that is scrolled out of view.
    func placeColorPopup() {
        guard let mode = barMode else { colorPopupAt = nil; return }
        var rect = CGRect.null
        switch mode {
        case .selection:
            guard hasTextSelection, let selection = pdfView.currentSelection else { hideColorPopup(); return }
            rect = selection.pages.map { pdfView.convert(selection.bounds(for: $0), from: $0) }.reduce(CGRect.null) { $0.union($1) }
        case .highlight:
            guard let h = selected, let page = document?.page(at: h.page) else { hideColorPopup(); return }
            rect = pdfView.convert(union(h.rects), from: page)
        }
        let bounds = pdfView.bounds
        rect = rect.intersection(bounds)
        guard !rect.isNull, !rect.isEmpty else { colorPopupAt = nil; return }
        let size = barSize
        let gap: CGFloat = 6
        let top = pdfView.isFlipped ? rect.minY - bounds.minY : bounds.maxY - rect.maxY
        var y = top - gap - size.height / 2
        if y - size.height / 2 < gap { y = top + rect.height + gap + size.height / 2 }
        y = min(y, bounds.height - gap - size.height / 2)
        let x = min(max(rect.midX - bounds.minX, gap + size.width / 2), bounds.width - gap - size.width / 2)
        colorPopupAt = CGPoint(x: x, y: y)
    }

    private func moveColorPopupView() {
        guard let at = colorPopupAt else { colorPopupView.removeFromSuperview(); return }
        let size = barSize
        let bounds = pdfView.bounds
        let y = pdfView.isFlipped ? bounds.minY + at.y : bounds.maxY - at.y
        colorPopupView.frame = CGRect(x: bounds.minX + at.x - size.width / 2, y: y - size.height / 2, width: size.width, height: size.height)
        if colorPopupView.superview !== pdfView { pdfView.addSubview(colorPopupView) }
    }

    func hideColorPopup() {
        if barMode != nil { barMode = nil }
        if colorPopupAt != nil { colorPopupAt = nil }
    }

    func barAction(_ item: BarItem) {
        switch item {
        case .color(let c): pickColor(c)
        case .erase: eraseSelection()
        case .note: focusNote()
        case .copy: _ = copySelectedHighlight()
        case .delete: deleteSelected()
        case .divider: break
        }
    }

    func pickColor(_ color: HighlightColor) {
        penColor = color
        applyColor(color)
    }

    func applyColor(_ color: HighlightColor) {
        if let selection = pdfView.currentSelection, !(selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            highlightSelection(selection, color: color)
        } else if let id = selectedID, let store, selected?.highlightColor != .noteOnly {
            commit { confirmed in try store.setColor([id], color, confirmed: confirmed) }
        }
    }

    /// Removes highlighting from the selected text, trimming or splitting the highlights it covers.
    func eraseSelection() {
        guard let selection = pdfView.currentSelection, hasTextSelection else { beep(); return }
        highlightSelection(selection, color: nil)
    }

    func copySelectedHighlight() -> Bool {
        guard let h = selected, !h.text.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(h.text, forType: .string)
        return true
    }

    /// The highlights on a page with the characters each covers.
    private func pageHighlights(_ index: Int, page: PDFPage) -> [PageHighlight] {
        let hs = rendered[index] ?? ((try? store?.highlights(page: index)) ?? [])
        return hs.map { PageHighlight($0, chars: pdfView.chars(in: $0.rects, on: page)) }
    }

    func selectionTouchesHighlights() -> Bool {
        guard let selection = pdfView.currentSelection, let document else { return false }
        for page in selection.pages {
            let index = document.index(for: page)
            guard rendered[index] != nil else { continue }
            let chars = pdfView.chars(of: selection, on: page)
            if pageHighlights(index, page: page).contains(where: { $0.highlight.highlightColor != .noteOnly && !$0.chars.intersection(chars).isEmpty }) {
                return true
            }
        }
        return false
    }

    /// Highlights the selection in `color`, or removes highlighting from it when `color` is nil.
    /// Same-color highlights it overlaps or touches are merged into it; other colors keep only the part outside it.
    private func highlightSelection(_ selection: PDFSelection, color: HighlightColor?) {
        guard let store, let document else { return }
        let selection = pdfView.snapped(selection)
        var ops: [PendingOp] = []
        var made: [String] = []
        var removedCount = 0
        for page in selection.pages {
            let index = document.index(for: page)
            let chars = pdfView.chars(of: selection, on: page)
            guard !chars.isEmpty else { continue }
            let text = pdfView.pageText(page)
            let plan = HighlightMerge.plan(chars, color: color, existing: pageHighlights(index, page: page), text: text)
            let pieces = plan.pieces.compactMap { highlight(from: $0, page: page, index: index, text: text) }
            if color == nil { removedCount += plan.removed.count }
            ops += plan.removed.map(PendingOp.delete) + pieces.map(PendingOp.add)
            if let color, let first = pieces.first(where: { $0.highlightColor == color }) { made.append(first.id) }
        }
        guard !ops.isEmpty else {
            if color == nil { beep() } else { pdfView.clearSelection(); hideColorPopup() }
            return
        }
        guard commit({ confirmed in try store.commit(Plan(kind: .edit, label: "Edit", ops: ops), confirmed: confirmed) }) else { return }
        pdfView.clearSelection()
        hideColorPopup()
        if color == nil {
            showNotice(removedCount == 1 ? "Highlighting removed" : "Highlighting removed from \(removedCount) highlights")
        } else if !highlighterOn, let first = made.first {
            select(first)
        }
    }

    /// Builds a highlight from page characters, one box per text line.
    private func highlight(from piece: Piece, page: PDFPage, index: Int, text: PageText) -> Highlight? {
        var rects: [Rect] = []
        var strings: [String] = []
        for r in text.runs(piece.chars) {
            for line in pdfView.lineBoxes(for: r, on: page) {
                rects.append(Rect(x: line.rect.minX, y: line.rect.minY, w: line.rect.width, h: line.rect.height))
                strings.append(line.text)
            }
        }
        guard !rects.isEmpty else { return nil }
        let joined = strings.joined(separator: " ").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return Highlight(id: piece.id ?? Highlight.newID(), page: index, rects: rects, text: joined, color: piece.color,
                         note: piece.note, created: piece.created ?? Date().timeIntervalSince1970, source: piece.source ?? "app")
    }

    /// Merges overlapping highlights and widens partial words on every page, as one change that Cmd+Z undoes.
    func tidyHighlights() {
        guard let store, let document else { return }
        let byPage = Dictionary(grouping: (try? store.highlights()) ?? [], by: \.page)
        var ops: [PendingOp] = []
        var before = 0, after = 0
        var pages = 0
        for index in byPage.keys.sorted() {
            guard let page = document.page(at: index) else { continue }
            let text = pdfView.pageText(page)
            let plan = HighlightMerge.tidy(pageHighlights(index, page: page), text: text)
            guard !plan.isEmpty else { continue }
            let pieces = plan.pieces.compactMap { highlight(from: $0, page: page, index: index, text: text) }
            ops += plan.removed.map(PendingOp.delete) + pieces.map(PendingOp.add)
            before += plan.removed.count
            after += pieces.count
            pages += 1
        }
        guard !ops.isEmpty else {
            notify("Nothing to tidy", info: "No highlights overlap and none stop partway through a word.")
            return
        }
        let message = "Tidy \(before) highlight\(before == 1 ? "" : "s") on \(pages) page\(pages == 1 ? "" : "s") into \(after)?"
        let info = "Overlapping highlights of one color are merged. Where colors overlap, the newer color wins. "
            + "Highlights that stop partway through a word are widened to the whole word. Cmd+Z undoes this."
        guard confirm(message, info: info, ok: "Tidy") else { return }
        if commit({ _ in try store.commit(Plan(kind: .edit, label: "Edit", ops: ops), confirmed: true) }) {
            select(nil)
            showNotice("Tidied \(before) highlights into \(after)")
        }
    }

    func deleteFromMenu() {
        if NSApp.keyWindow?.firstResponder is NSText {
            NSApp.sendAction(#selector(NSResponder.deleteToBeginningOfLine(_:)), to: nil, from: nil)
        } else if hasTextSelection, selectionTouchesHighlights() {
            eraseSelection()
        } else {
            deleteSelected()
        }
    }

    func deleteSelected() {
        if let id = selectedID { delete(id) }
    }

    func delete(_ id: String) {
        guard let store else { return }
        if commit({ confirmed in try store.delete([id], confirmed: confirmed) }) { showNotice("Highlight deleted") }
    }

    /// Shows `message` with an Undo button at the bottom of the page for a few seconds.
    func showNotice(_ message: String) {
        let n = Notice(message: message)
        withAnimation(.easeOut(duration: 0.15)) { notice = n }
        noticeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard self?.notice?.id == n.id else { return }
                withAnimation(.easeIn(duration: 0.2)) { self?.notice = nil }
            }
        }
        noticeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    @discardableResult
    func commit(_ body: (Bool) throws -> Void) -> Bool {
        commit(recordUndo: true, body)
    }

    private func commit(recordUndo: Bool, _ body: (Bool) throws -> Void) -> Bool {
        let before = store?.commitCount
        defer {
            if recordUndo, let store, store.commitCount != before, !store.lastCommitted.isEmpty {
                undoStack.append(store.lastCommitted)
                if undoStack.count > 100 { undoStack.removeFirst(undoStack.count - 100) }
                redoStack = []
            }
        }
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
        scheduleExport()
        return true
    }

    var undoTitle: String { undoStack.last.map { "Undo \(PendingOp.describe($0))" } ?? "Undo" }
    var redoTitle: String { redoStack.last.map { "Redo \(PendingOp.describe($0))" } ?? "Redo" }

    func undo() {
        if NSApp.keyWindow?.firstResponder is NSText { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil); return }
        step(from: &undoStack, to: &redoStack)
    }

    func redo() {
        if NSApp.keyWindow?.firstResponder is NSText { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil); return }
        step(from: &redoStack, to: &undoStack)
    }

    /// Reverts the newest change on one stack and pushes the reverting change onto the other.
    /// A change that no longer applies, because its highlight changed in another way since, is dropped.
    private func step(from source: inout [[PendingOp]], to target: inout [[PendingOp]]) {
        flushNote()
        guard let store else { return }
        while let ops = source.popLast() {
            guard let back = try? store.revert(ops), !back.isEmpty else { continue }
            if commit(recordUndo: false, { confirmed in try store.commit(Plan(kind: .edit, label: "Edit", ops: back), confirmed: confirmed) }) {
                target.append(back)
                pdfView.clearSelection()
                hideColorPopup()
                withAnimation { notice = nil }
                if let page = back.first?.page, !isTestRun, !visiblePages.contains(page) { goTo(page: page) }
            } else {
                source.append(ops)
            }
            return
        }
        beep()
    }

    private var visiblePages: Set<Int> {
        guard let document else { return [] }
        return Set(pdfView.visiblePages.map { document.index(for: $0) })
    }

    func confirm(_ message: String, info: String = "", ok: String = "Continue") -> Bool {
        if let check = selfCheck { check.alerts.append(message); return true }
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.addButton(withTitle: ok)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// The alert sound, silent while the self-check or a measurement runs.
    func beep() {
        if !isTestRun { NSSound.beep() }
    }

    func notify(_ message: String, info: String = "") {
        if let check = selfCheck { check.alerts.append("\(message) \(info)"); return }
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.runModal()
    }

    // MARK: Navigation to highlights and results

    func goToHighlight(id: String, page: Int, showNote: Bool = true) {
        goTo(page: page)
        if let h = (try? store?.highlight(id: id)) ?? nil, let first = h.rects.first, let p = document?.page(at: h.page) {
            pdfView.go(to: PDFDestination(page: p, at: CGPoint(x: max(0, first.x - 40), y: first.y + first.h + 120)))
        }
        select(id, showNote: showNote)
    }

    func open(result r: SearchResult) {
        hideColorPopup()
        if let id = r.highlightID {
            goToHighlight(id: id, page: r.page, showNote: false)
        } else {
            goTo(page: r.page)
            showMatch(page: r.page)
        }
    }

    private func showMatch(page index: Int) {
        guard let page = document?.page(at: index) else { return }
        let matches = PageMatches.selections(page: page, terms: PageMatches.terms(query))
        for m in matches { m.color = .systemYellow }
        pdfView.highlightedSelections = matches.isEmpty ? nil : matches
        guard let first = matches.first else { return }
        pdfView.setCurrentSelection(first, animate: false)
        pdfView.go(to: first)
    }

    func clearMatches() {
        pdfView.highlightedSelections = nil
        pdfView.clearSelection()
    }

    func moveResult(_ delta: Int) {
        guard !results.isEmpty else { return }
        let current = selectedResultID.flatMap { id in results.firstIndex { $0.id == id } }
        let next = current.map { min(max($0 + delta, 0), results.count - 1) } ?? (delta < 0 ? results.count - 1 : 0)
        selectedResultID = results[next].id
    }

    func openSelectedResult() {
        guard let id = selectedResultID, let r = results.first(where: { $0.id == id }) else { return }
        open(result: r)
    }

    func marks(for r: SearchResult) -> [CGRect]? {
        guard let id = r.highlightID, let h = (try? store?.highlight(id: id)) ?? nil else { return nil }
        return h.rects.map { CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h) }
    }

    func focusSearch() {
        guard let window = pdfView.window else { return }
        func find(_ view: NSView) -> NSSearchField? {
            if let f = view as? NSSearchField, f.placeholderString == SidebarView.searchPlaceholder { return f }
            for sub in view.subviews { if let f = find(sub) { return f } }
            return nil
        }
        if let root = window.contentView?.superview, let field = find(root) {
            window.makeFirstResponder(field)
            showResultsPanel = true
        }
    }

    var searchFieldFocused: Bool {
        guard let editor = pdfView.window?.firstResponder as? NSTextView,
              let field = editor.delegate as? NSTextField else { return false }
        return field.placeholderString == SidebarView.searchPlaceholder
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let code = event.keyCode
            let plain = event.modifierFlags.intersection([.command, .option, .control]).isEmpty
            let window = event.window
            let digit = event.charactersIgnoringModifiers.flatMap { Int($0) }
            let handled = MainActor.assumeIsolated { () -> Bool in
                let model = AppModel.shared
                if model.colorPopupAt != nil, plain, window === model.pdfView.window, !(window?.firstResponder is NSText) {
                    let onHighlight = model.barMode == .highlight
                    let canErase = model.barMode == .selection(erase: true)
                    switch code {
                    case 53:
                        if onHighlight { model.select(nil) } else { model.hideColorPopup() }
                        return true
                    case 51, 117:
                        if onHighlight { model.deleteSelected(); return true }
                        if canErase { model.eraseSelection(); return true }
                    case 45, 36:
                        if onHighlight { model.focusNote(); return true }
                    default:
                        break
                    }
                    if digit == 0, canErase {
                        model.eraseSelection()
                        return true
                    }
                    if let c = digit.flatMap(HighlightColor.init(rawValue:)), c != .noteOnly {
                        model.pickColor(c)
                        return true
                    }
                }
                if code == 53, plain, let window, window === model.popover?.contentViewController?.view.window {
                    model.select(nil)
                    return true
                }
                if code == 53, plain, window === model.pdfView.window, model.pdfView.highlightedSelections != nil,
                   model.searchFieldFocused || !(window?.firstResponder is NSText) {
                    model.clearMatches()
                    return true
                }
                if code == 53, plain, window === model.pdfView.window, model.highlighterOn, !model.searchFieldFocused {
                    model.highlighterOn = false
                    return true
                }
                guard plain, window != nil, window === model.pdfView.window, model.isSearching,
                      !model.results.isEmpty, model.searchFieldFocused else { return false }
                switch code {
                case 125: model.moveResult(1)
                case 126: model.moveResult(-1)
                default: return false
                }
                return true
            }
            return handled ? nil : event
        }
    }

    func handle(url: URL) {
        if url.isFileURL {
            open(url)
            return
        }
        guard url.scheme == "fa-reader" else { return }
        guard store != nil else { pendingURL = url; return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let path = items.first(where: { $0.name == "pdf" })?.value, path != pdfURL?.path,
           FileManager.default.fileExists(atPath: path) {
            open(URL(fileURLWithPath: path))
        }
        let page = items.first { $0.name == "page" }?.value.flatMap(Int.init)
        let id = items.first { $0.name == "highlight" }?.value
        if let id, let h = try? store?.highlight(id: id) {
            goToHighlight(id: id, page: h.page)
        } else if let page {
            goTo(page: page - 1)
        }
        if isTestRun {
            print("handled_url book=\(pdfURL?.lastPathComponent ?? "") page=\(currentPageIndex)")
            fflush(stdout)
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: Search

    func runSearch() {
        guard let runner else { return }
        let text = query.trimmingCharacters(in: .whitespaces)
        let filter = self.filter
        guard !text.isEmpty || !filter.isEmpty else {
            runner.cancel()
            results = []
            selectedResultID = nil
            pdfView.highlightedSelections = nil
            searchMs = nil
            return
        }
        runner.run(text, filter: filter) { [weak self] found, ms in
            Task { @MainActor in
                if self?.results.map(\.id) != found.map(\.id) { self?.selectedResultID = nil }
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
        guard let store, !syncing else { return }
        syncing = true
        folderQueue.async {
            let reads = (try? store.readLogs()) ?? []
            let devices = store.folder.logFiles().filter { $0.deletingPathExtension().lastPathComponent != store.device }.count
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let model = AppModel.shared
                    model.syncing = false
                    guard model.store === store else { return }
                    let changed = (try? store.apply(reads)) ?? 0
                    model.lastSync = Date()
                    model.syncedDevices = devices
                    if changed > 0 {
                        model.loadPreviewRects()
                        model.reconcile()
                        model.refreshHistory()
                        model.scheduleExport()
                    }
                }
            }
        }
    }

    /// Waits for log lines still queued for the log file. Called when the app quits.
    func flushLog() {
        guard let store else { return }
        folderQueue.sync { try? store.flushLog() }
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
            guard let fresh = PDFDocument(url: url) else { return }
            let scanned = await Task.detached(priority: .userInitiated) { PreviewImporter.scan(fresh) }.value
            guard showImport, let store else { return }
            let already = (try? store.importedHighlightIDs()) ?? []
            importPreview = PreviewImporter.preview(annotations: scanned, alreadyImported: already)
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

    var exportDirectory: URL? {
        if let path = UserDefaults.standard.string(forKey: "exportFolder"), let pdfURL {
            return URL(fileURLWithPath: path, isDirectory: true)
                .appendingPathComponent(pdfURL.deletingPathExtension().lastPathComponent, isDirectory: true)
        }
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
            let result = try MarkdownExporter.export(store: store, sections: sections, to: dir, printedPage: { page in
                try? BookIndex.printedPage(db: store.db, page: page)
            }, pdf: pdfURL)
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

extension AppModel {
    var bookTitle: String { pdfURL?.deletingPathExtension().lastPathComponent ?? "FA Reader" }

    func openRecent(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else {
            recentBooks.removeAll { $0 == path }
            UserDefaults.standard.set(recentBooks, forKey: "recentPDFs")
            notify("\((path as NSString).lastPathComponent) is no longer at \(path)")
            return
        }
        open(URL(fileURLWithPath: path))
    }

    func clearRecent() {
        recentBooks = pdfURL.map { [$0.path] } ?? []
        UserDefaults.standard.set(recentBooks, forKey: "recentPDFs")
    }
}

extension AppModel {
    func makeMarky() -> MarkyView {
        let m = MarkyView()
        m.mode = MarkyView.Mode(rawValue: notesMode) ?? .preview
        m.onTextChange = { [weak self] in self?.notesChanged() }
        m.openURL = { [weak self] url in
            guard url.scheme == "fa-reader" else { return false }
            self?.handle(url: url)
            return true
        }
        m.openMarkdownLink = { [weak self] file, _ in self?.showNotesFile(file) }
        return m
    }

    private func notesChanged() {
        notesDirty = true
        notesSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.saveNotes() } }
        notesSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func saveNotes() {
        notesSaveWork?.cancel()
        guard notesDirty, let url = notesURL else { return }
        notesDirty = false
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(marky.text.utf8).write(to: url, options: .atomic)
        } catch {
            notify("Could not save notes", info: "\(error.localizedDescription)")
        }
    }

    func refreshNotes(force: Bool = false) {
        guard notesShown, let store, let dir = exportDirectory else { return }
        let section = Sections.section(for: currentPageIndex, in: sections)
        guard force || section?.id != notesSectionID else { return }
        saveNotes()
        notesSectionID = section?.id
        guard let section else {
            notesURL = nil
            notesTitle = "Notes"
            marky.text = ""
            return
        }
        let url = dir.appendingPathComponent(MarkdownExporter.fileName(for: section))
        let existing = try? String(contentsOf: url, encoding: .utf8)
        var text = existing ?? ""
        if existing == nil || existing.map(MarkdownExporter.hasMarker) == true {
            let highlights = ((try? store.highlights()) ?? []).filter { section.pages.contains($0.page) }
            text = MarkdownExporter.merge(existing: existing, section: section, highlights: highlights,
                                          printedPage: { [weak self] in self?.printed($0) }, pdf: pdfURL)
            if existing != nil, existing != text { try? Data(text.utf8).write(to: url, options: .atomic) }
        }
        notesURL = url
        notesTitle = section.title
        marky.baseURL = dir
        if marky.text != text { marky.text = text }
    }

    func showNotesFile(_ file: URL) {
        saveNotes()
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { beep(); return }
        notesURL = file
        notesSectionID = -1
        notesTitle = file.deletingPathExtension().lastPathComponent
        marky.baseURL = file.deletingLastPathComponent()
        marky.text = text
    }

    func revealNotes() {
        guard let target = notesURL ?? exportDirectory else { return }
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    func scheduleExport() {
        exportWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.exportQuietly() } }
        exportWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    func exportQuietly() {
        exportWork?.cancel()
        guard let store, let dir = exportDirectory else { return }
        saveNotes()
        let highlights = allHighlights, sections = sections, pdf = pdfURL
        var printedPages: [Int: String] = [:]
        for page in Set(highlights.map(\.page)) { printedPages[page] = printed(page) }
        let write = { _ = try? MarkdownExporter.export(highlights: highlights, sections: sections, to: dir, printedPage: { printedPages[$0] }, pdf: pdf) }
        if isTestRun {
            write()
            refreshNotes(force: true)
            return
        }
        folderQueue.async {
            write()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let model = AppModel.shared
                    if model.store === store { model.refreshNotes(force: true) }
                }
            }
        }
    }
}
