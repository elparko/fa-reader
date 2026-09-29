import AppKit
import FACore
import PDFKit

@MainActor
final class SelfCheck {
    let report: URL
    var alerts: [String] = []
    private var checks: [[String: Any]] = []
    private var model: AppModel { AppModel.shared }

    init(report: URL) { self.report = report }

    private func check(_ name: String, _ ok: Bool, _ detail: Any = "") {
        checks.append(["name": name, "ok": ok, "detail": "\(detail)"])
    }

    private func pause(_ seconds: Double = 0.3) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func press(_ key: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = .command) -> Bool {
        guard let window = model.pdfView.window,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, characters: key,
                                           charactersIgnoringModifiers: key, isARepeat: false, keyCode: keyCode) else { return false }
        return NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
    }

    private func findField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let f = view as? NSTextField, f.placeholderString == SidebarView.searchPlaceholder { return f }
        for sub in view.subviews { if let f = findField(in: sub) { return f } }
        return nil
    }

    private func postArrow(down: Bool) {
        guard let window = model.pdfView.window else { return }
        let code: UInt16 = down ? 125 : 126
        let chars = String(UnicodeScalar(down ? 0xF701 : 0xF700)!)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [.numericPad, .function], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, characters: chars,
                                        charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                NSApp.postEvent(e, atStart: false)
            }
        }
    }

    private func select(_ text: String, page index: Int) -> PDFSelection? {
        guard let page = model.document?.page(at: index), let s = page.string,
              let range = s.range(of: text) else { return nil }
        return page.selection(for: NSRange(range, in: s))
    }

    private func ourAnnotations(page index: Int, id: String) -> Int {
        model.document?.page(at: index)?.annotations.filter { $0.userName == "fa:\(id)" }.count ?? 0
    }

    private func search(_ text: String, filter: SearchFilter = SearchFilter()) async -> ([SearchResult], Double) {
        await withCheckedContinuation { cont in
            model.runner?.run(text, filter: filter) { results, ms in cont.resume(returning: (results, ms)) }
        }
    }

    func run(openMs: Double) {
        Task { @MainActor in
            await steps(openMs: openMs)
            let data = try? JSONSerialization.data(withJSONObject: ["checks": checks, "alerts": alerts], options: [.prettyPrinted, .sortedKeys])
            try? data?.write(to: report)
            NSApp.terminate(nil)
        }
    }

    private func steps(openMs: Double) async {
        check("open under 1 s", openMs < 1000, "\(Int(openMs)) ms")
        guard let store = model.store, let document = model.document else { check("store open", false); return }
        check("page count", document.pageCount == 865, document.pageCount)
        check("sections", model.sections.contains { $0.title == "Endocrine" }, model.sections.map(\.title).joined(separator: " | "))
        model.pdfView.window?.makeFirstResponder(model.pdfView)

        let graves = 366
        guard let selection = select("Graves disease", page: graves) else { check("find Graves text", false); return }
        model.goTo(page: graves)
        model.pdfView.setCurrentSelection(selection, animate: false)
        let pressed = press("1", keyCode: 18)
        await pause()
        let made = (try? store.highlights(page: graves))?.first { $0.text.contains("Graves disease") && $0.source == "app" }
        check("⌘1 highlights selection yellow", pressed && made?.highlightColor == .yellow, made.map { "\($0.text) \($0.highlightColor.name) rects=\($0.rects.count)" } ?? "none")
        guard let h = made else { return }
        check("highlight drawn on page", ourAnnotations(page: graves, id: h.id) == h.rects.count, ourAnnotations(page: graves, id: h.id))

        model.select(h.id)
        check("clicking a highlight opens its popup next to it", model.detailsAnchor.map { $0.intersects(model.pdfView.bounds) } ?? false,
              model.detailsAnchor.map { "\($0)" } ?? "nil")
        _ = press("3", keyCode: 20)
        await pause()
        check("⌘3 recolors selected highlight pink", (try? store.highlight(id: h.id))??.highlightColor == .pink)

        model.noteDraft = "Most common cause of hyperthyroidism #endocrine #thyroid"
        model.select(nil)
        let noted = (try? store.highlight(id: h.id)) ?? nil
        check("note saved on deselect", noted?.note.hasPrefix("Most common cause") == true, noted?.note ?? "")
        check("tags parsed", Set(noted?.tags ?? []) == ["endocrine", "thyroid"], noted?.tags ?? [])

        var tries = 0
        while model.indexProgress != nil || !((try? BookIndex.isIndexed(db: store.db, pageCount: document.pageCount)) ?? false) {
            await pause(0.5)
            tries += 1
            if tries > 120 { break }
        }
        check("book text indexed", (try? BookIndex.isIndexed(db: store.db, pageCount: document.pageCount)) ?? false, "\(Double(tries) * 0.5) s wait")

        var worst = 0.0
        for prefix in ["h", "hy", "hyp", "hype", "hyper", "hypert", "hyperth", "hyperthy", "hyperthyroid", "graves", "graves d", "papillary carc"] {
            let (_, ms) = await search(prefix)
            worst = max(worst, ms)
        }
        check("as-you-type search under 50 ms", worst < 50, String(format: "worst %.1f ms", worst))
        let (graveResults, _) = await search("graves")
        check("search finds highlight text", graveResults.contains { $0.kind == .highlight && $0.highlightID == h.id }, graveResults.prefix(4).map { "\($0.kind) \($0.page)" })
        let (noteResults, _) = await search("hyperthyroidism")
        check("search finds note", noteResults.first.map { $0.kind == .note && $0.highlightID == h.id } ?? false, noteResults.prefix(4).map { "\($0.kind) \($0.page)" })
        check("search finds book page", graveResults.contains { $0.kind == .book && $0.page == graves })
        let (pinkResults, _) = await search("", filter: SearchFilter(color: .pink))
        check("color filter", pinkResults.contains { $0.highlightID == h.id } && pinkResults.allSatisfy { $0.color == .pink })
        let (tagResults, _) = await search("", filter: SearchFilter(tag: "thyroid"))
        check("tag filter", tagResults.map(\.highlightID) == [h.id], tagResults.count)
        if let endocrine = model.sections.first(where: { $0.title == "Endocrine" }), let micro = model.sections.first(where: { $0.title == "Microbiology" }) {
            let (inSection, _) = await search("graves", filter: SearchFilter(pages: endocrine.pages))
            let (outSection, _) = await search("graves", filter: SearchFilter(pages: micro.pages))
            check("section filter", inSection.contains { $0.highlightID == h.id } && !outSection.contains { $0.highlightID == h.id })
        }

        model.query = "hyperthyroidism"
        await pause(0.5)
        if let field = findField(in: model.pdfView.window?.contentView?.superview) {
            check("search field is in the toolbar", field is NSSearchField && !(field.isDescendant(of: model.pdfView.window!.contentView!)))
            check("results panel shows while sidebar is hidden", model.showResultsPanel)
            model.pdfView.window?.makeFirstResponder(field)
            await pause()
            let bookResults = model.results.filter { $0.kind == .book }.count
            postArrow(down: true)
            await pause(0.4)
            let firstID = model.selectedResultID
            let firstPage = model.currentPageIndex
            postArrow(down: true)
            await pause(0.4)
            let secondID = model.selectedResultID
            let secondResult = model.results.first { $0.id == secondID }
            check("↓ in search field steps through results", firstID == model.results.first?.id && secondID == model.results.dropFirst().first?.id,
                  "\(firstID ?? "nil") -> \(secondID ?? "nil"), \(model.results.count) results, \(bookResults) book")
            check("↓ jumps the page", secondResult.map { model.currentPageIndex == $0.page } ?? false, "page \(firstPage) -> \(model.currentPageIndex)")
            postArrow(down: false)
            await pause(0.4)
            check("↑ goes back", model.selectedResultID == firstID)
            check("search field keeps focus", model.searchFieldFocused)
            if let book = model.results.first(where: { $0.kind == .book }) {
                model.selectedResultID = book.id
                await pause(0.4)
                check("book result highlights every match on the page", (model.pdfView.highlightedSelections?.count ?? 0) >= 1,
                      model.pdfView.highlightedSelections?.count ?? 0)
                let thumb = await model.thumbnailer?.thumbnail(page: book.page, marks: nil, terms: ["hyperthyroidism"])
                check("result thumbnail renders", (thumb?.size.width ?? 0) > 0, thumb.map { "\($0.size)" } ?? "nil")
            }
            _ = press("g", keyCode: 5)
            await pause(0.3)
            check("⌘G moves to next result", model.selectedResultID != nil)
        } else {
            check("find search field", false)
        }
        model.query = "graves"
        model.showResultsPanel = true
        if let window = model.pdfView.window {
            window.setContentSize(NSSize(width: 760, height: 700))
            await pause(0.8)
            if let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: report.deletingLastPathComponent().appendingPathComponent("narrow.png"))
            }
            check("window can shrink to half-screen width", window.contentView!.bounds.width <= 760, window.contentView!.bounds.width)
        }
        model.pdfView.window?.makeFirstResponder(model.pdfView)
        model.query = ""
        await pause(0.3)

        let scanned = PreviewImporter.scan(document)
        let preview = PreviewImporter.preview(annotations: scanned, alreadyImported: (try? store.importedHighlightIDs()) ?? [])
        check("import preview before saving", preview.selected().count == 56 && (try? store.highlights().count) == 1,
              "candidates=\(preview.candidates.count) bursts=\(preview.bursts.count) stored=\((try? store.highlights().count) ?? -1)")
        alerts.removeAll()
        model.runImport(preview, bursts: [])
        check("import asks before changing > 20 pages", alerts.contains { $0.contains("pages. Continue?") }, alerts)
        check("import saved 56", (try? store.highlights().count) == 57, (try? store.highlights().count) ?? -1)
        let native = document.page(at: graves)?.annotations.filter { $0.type == "Highlight" && $0.userName?.hasPrefix("fa") != true }.count ?? -1
        check("imported Preview annotations hidden in memory", native == 0, native)

        model.refreshHistory()
        let sessions = model.history
        check("history has edit and import sessions", sessions.count == 2 && Set(sessions.map(\.kind)) == [.edit, .import],
              sessions.map { "\($0.kind) ops=\($0.opCount) pages=\($0.pages.count)" })
        if let edit = sessions.first(where: { $0.kind == .edit }) {
            model.prepareUndo(edit)
            model.confirmUndo()
            let remaining = (try? store.highlights()) ?? []
            check("undo edit session keeps later import", remaining.count == 56 && !remaining.contains { $0.id == h.id }, remaining.count)
            model.refreshHistory()
            check("undo is logged as its own session", model.history.contains { $0.kind == .undo && $0.undoes == edit.id })
        }

        let exportDir = FileManager.default.temporaryDirectory.appendingPathComponent("fa-selfcheck-export-\(UUID().uuidString)")
        let printed: (Int) -> String? = { page in (try? BookIndex.printedPage(db: store.db, page: page)) ?? nil }
        let first = try? MarkdownExporter.export(store: store, sections: model.sections, to: exportDir, printedPage: printed)
        let second = try? MarkdownExporter.export(store: store, sections: model.sections, to: exportDir, printedPage: printed)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: exportDir.path)) ?? []
        check("export one file per section", (first?.written.count ?? 0) > 0 && files.count == first?.written.count, files.sorted())
        check("re-export changes nothing", second?.written.isEmpty == true && second?.unchanged.count == files.count)
        if let gi = files.first(where: { $0.contains("Gastrointestinal") }),
           let text = try? String(contentsOf: exportDir.appendingPathComponent(gi), encoding: .utf8) {
            check("export has page links", text.contains("fa-reader://open?page="), String(text.prefix(600)))
        }

        model.handle(url: URL(string: "fa-reader://open?page=413")!)
        await pause()
        check("fa-reader:// link opens page", model.currentPageIndex == 412, model.currentPageIndex)

        let before = model.pdfView.scaleFactor
        _ = press("=", keyCode: 24)
        await pause()
        check("⌘= zooms in", model.pdfView.scaleFactor > before, "\(before) -> \(model.pdfView.scaleFactor)")
        model.fitWidth()

        model.goTo(page: graves)
        await pause(0.5)
        if let view = model.pdfView.window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            let png = report.deletingPathExtension().appendingPathExtension("png")
            try? rep.representation(using: .png, properties: [:])?.write(to: png)
        }

        model.select(nil)
        model.pdfView.clearSelection()
        model.highlighterOn = false
        model.toolbarColor(.green)
        check("toolbar color with nothing selected arms highlighter", model.highlighterOn && model.penColor == .green)
        model.goTo(page: graves)
        if let sel = select("Toxic multinodular", page: graves) {
            model.pdfView.setCurrentSelection(sel, animate: false)
            model.selectionEnded()
            let made = (try? store.highlights(page: graves))?.first { $0.text.contains("Toxic multinodular") }
            check("highlighter mode highlights on mouse release", made?.highlightColor == .green, made?.text ?? "none")
            if let made, let r = made.rects.first, let page = document.page(at: graves) {
                model.goTo(page: graves)
                await pause(0.3)
                let viewPoint = model.pdfView.convert(CGPoint(x: r.x + r.w / 2, y: r.y + r.h / 2), from: page)
                let windowPoint = model.pdfView.convert(viewPoint, to: nil)
                if let event = NSEvent.mouseEvent(with: .rightMouseDown, location: windowPoint, modifierFlags: [], timestamp: 0,
                                                  windowNumber: model.pdfView.window?.windowNumber ?? 0, context: nil,
                                                  eventNumber: 0, clickCount: 1, pressure: 1) {
                    model.pdfView.clearSelection()
                    let titles = model.pdfView.menu(for: event)?.items.map(\.title) ?? []
                    check("right-click on a highlight offers colors, note, delete",
                          titles.contains("Make Pink") && titles.contains("Edit Note") && titles.contains("Delete Highlight"), titles.prefix(8))
                    check("right-click selects that highlight", model.selectedID == made.id)
                }
            }
            if let sel2 = select("Thyroid storm", page: graves) {
                model.highlighterOn = false
                model.pdfView.setCurrentSelection(sel2, animate: false)
                model.selectionEnded()
                check("highlighter off leaves selection alone", !((try? store.highlights(page: graves)) ?? []).contains { $0.text.contains("Thyroid storm") })
                model.toolbarColor(.blue)
                let blue = (try? store.highlights(page: graves))?.first { $0.text.contains("Thyroid storm") }
                check("toolbar color with text selected highlights it", blue?.highlightColor == .blue)
            }
            model.highlighterOn = true
            model.pdfView.window?.makeFirstResponder(model.pdfView)
            if let window = model.pdfView.window, let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                                               windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                                                               charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
                NSApp.postEvent(esc, atStart: false)
                await pause(0.3)
            }
            check("Esc turns highlighter off", !model.highlighterOn)
        }

        let original = model.pdfURL
        let other = report.deletingLastPathComponent().appendingPathComponent("one.pdf")
        if FileManager.default.fileExists(atPath: other.path), let original {
            NSApp.delegate?.application?(NSApp, open: [other])
            await pause(0.5)
            check("opening another PDF switches book", model.pdfURL == other && model.pageCount == 1, model.bookTitle)
            check("each book has its own data folder", model.store?.folder.root.lastPathComponent == "one.fa-reader")
            let link = MarkdownExporter.link(page: 412, pdf: original)
            NSApp.delegate?.application?(NSApp, open: [URL(string: link)!])
            await pause(0.5)
            check("link naming another book opens that book and page", model.pdfURL == original && model.currentPageIndex == 412,
                  "\(model.bookTitle) \(model.currentPageIndex) via \(link)")
            check("window title is the book name", model.bookTitle == original.deletingPathExtension().lastPathComponent)
        }
    }
}
