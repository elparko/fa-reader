import AppKit
import FACore
import PDFKit
import SwiftUI

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

    private func select(_ text: String, page index: Int, within: String? = nil) -> PDFSelection? {
        guard let page = model.document?.page(at: index), let s = page.string else { return nil }
        let area = within.flatMap { s.range(of: $0) } ?? s.startIndex..<s.endIndex
        guard let range = s.range(of: text, range: area) else { return nil }
        return page.selection(for: NSRange(range, in: s))
    }

    private func popupAboveSelection() -> Bool {
        let view = model.pdfView
        guard let at = model.colorPopupAt, let sel = view.currentSelection, let page = sel.pages.first else { return false }
        let r = view.convert(sel.bounds(for: page), from: page)
        let top = view.isFlipped ? r.minY : view.bounds.maxY - r.maxY
        return at.y < top && abs(at.x - r.midX) < model.barSize.width
    }

    /// A point in window coordinates at the center of a bar item.
    private func barPoint(_ item: BarItem) -> NSPoint? {
        guard let x = HighlightBar.center(of: item, in: model.barItems) else { return nil }
        return popupPoint(dx: x - model.barSize.width / 2)
    }

    /// With --visible, a screenshot of the window as drawn on screen, highlights included.
    private func capture(_ name: String) async {
        guard CommandLine.arguments.contains("--visible"), let window = model.pdfView.window else { return }
        await pause(0.6)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", report.deletingLastPathComponent().appendingPathComponent(name).path]
        try? task.run()
        task.waitUntilExit()
    }

    private func snapshot(_ view: NSView, _ name: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: report.deletingLastPathComponent().appendingPathComponent(name))
    }

    /// Whether any two highlights on a page cover the same characters.
    private func overlapping(page index: Int) -> [String] {
        guard let page = model.document?.page(at: index), let store = model.store else { return [] }
        let hs = ((try? store.highlights(page: index)) ?? []).filter { $0.highlightColor != .noteOnly }
        let sets = hs.map { model.pdfView.chars(in: $0.rects, on: page) }
        var out: [String] = []
        for i in hs.indices { for j in hs.indices where j > i && !sets[i].intersection(sets[j]).isEmpty { out.append("\(hs[i].text) / \(hs[j].text)") } }
        return out
    }

    /// A point in window coordinates, offset from the center of the color popup (dy grows downward).
    private func popupPoint(dx: CGFloat, dy: CGFloat = 0) -> NSPoint? {
        let view = model.pdfView
        guard let at = model.colorPopupAt else { return nil }
        let p = CGPoint(x: at.x + dx, y: view.isFlipped ? at.y + dy : view.bounds.height - at.y - dy)
        return view.convert(p, to: nil)
    }

    private func hitsPDF(_ point: NSPoint) -> Bool {
        guard let content = model.pdfView.window?.contentView, let frame = content.superview else { return false }
        guard let hit = content.hitTest(frame.convert(point, from: nil)) else { return false }
        return hit.isDescendant(of: model.pdfView) && !hit.isDescendant(of: model.colorPopupView)
    }

    private func click(_ point: NSPoint) {
        guard let window = model.pdfView.window else { return }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let e = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                          pressure: type == .leftMouseDown ? 1 : 0) {
                NSApp.postEvent(e, atStart: false)
            }
        }
    }

    /// Queues the drag and release, then presses the mouse; the PDF view reads the queued events in its own drag loop.
    private func drag(_ points: [NSPoint]) {
        guard let window = model.pdfView.window, let first = points.first, let last = points.last else { return }
        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                               pressure: type == .leftMouseUp ? 0 : 1)
        }
        for p in points.dropFirst() { if let e = event(.leftMouseDragged, p) { NSApp.postEvent(e, atStart: false) } }
        if let e = event(.leftMouseUp, last) { NSApp.postEvent(e, atStart: false) }
        if let e = event(.leftMouseDown, first) { model.pdfView.mouseDown(with: e) }
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

        if let page = document.page(at: graves), let window = model.pdfView.window {
            let before = page.annotations.filter { $0.url != nil }.count
            let header = model.pdfView.convert(model.pdfView.convert(CGPoint(x: 300, y: 842), from: page), to: nil)
            if let move = NSEvent.mouseEvent(with: .mouseMoved, location: header, modifierFlags: [], timestamp: 0,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                model.pdfView.mouseMoved(with: move)
            }
            let after = page.annotations.filter { $0.url != nil }.count
            if before > 0 { check("hovering a page drops its web links", after == 0, "\(before) -> \(after)") }
        }

        check("highlighting selects the new highlight and shows its bar", model.selectedID == h.id && model.barMode == .highlight && model.colorPopupAt != nil,
              "\(model.selectedID ?? "nil") \(String(describing: model.barMode))")
        check("Undo menu names the change", model.undoTitle == "Undo Highlight", model.undoTitle)
        model.select(nil)
        model.select(h.id)
        await capture("shot-bar.png")
        check("clicking a highlight shows its bar with colors, note, copy and delete",
              model.barMode == .highlight && model.colorPopupAt != nil && model.barItems.contains(.note) && model.barItems.contains(.delete),
              "\(String(describing: model.barMode)) \(model.barItems)")
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
                check("selecting text shows the color popup above it", popupAboveSelection(), model.colorPopupAt.map { "\($0)" } ?? "nil")
                model.toolbarColor(.blue)
                let blue = (try? store.highlights(page: graves))?.first { $0.text.contains("Thyroid storm") }
                check("toolbar color with text selected highlights it", blue?.highlightColor == .blue)
                check("highlighting switches the bar to the new highlight", model.barMode == .highlight && model.selectedID == blue?.id)
                model.select(nil)
            }
            if let sel = select("Causes of goiter", page: graves) {
                model.pdfView.go(to: sel)
                model.pdfView.setCurrentSelection(sel, animate: false)
                model.selectionEnded()
                await pause(0.4)
                if let view = model.pdfView.window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: report.deletingLastPathComponent().appendingPathComponent("popup.png"))
                }
                let pinkDot = barPoint(.color(.pink))
                let page = popupPoint(dx: 0, dy: (model.colorPopupAt?.y ?? 0) > model.pdfView.bounds.height / 2 ? -120 : 120)
                check("the popup takes clicks and the page around it still does",
                      pinkDot.map { !hitsPDF($0) } == true && page.map(hitsPDF) == true, "\(pinkDot.map { "\($0)" } ?? "nil") \(page.map { "\($0)" } ?? "nil")")
                if let pinkDot { click(pinkDot) }
                await pause(0.4)
                let pink = (try? store.highlights(page: graves))?.first { $0.text.contains("Causes of goiter") }
                check("clicking a color in the popup highlights the selection", pink?.highlightColor == .pink && model.selectedID == pink?.id && !model.hasTextSelection,
                      pink.map { "\($0.text) \($0.highlightColor.name)" } ?? "none")
                if let blueDot = barPoint(.color(.blue)) { click(blueDot) }
                await pause(0.4)
                let recolored = pink.flatMap { (try? store.highlight(id: $0.id)) ?? nil }
                check("clicking a color in a highlight's bar recolors it", recolored?.highlightColor == .blue, recolored?.highlightColor.name ?? "none")
                model.select(nil)
            }
            model.pdfView.window?.makeFirstResponder(model.pdfView)
            if let sel = select("Wolff-Chaikoff", page: graves), let window = model.pdfView.window,
               let two = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                          context: nil, characters: "2", charactersIgnoringModifiers: "2", isARepeat: false, keyCode: 19) {
                model.pdfView.go(to: sel)
                model.pdfView.setCurrentSelection(sel, animate: false)
                model.selectionEnded()
                NSApp.postEvent(two, atStart: false)
                await pause(0.3)
                let green = (try? store.highlights(page: graves))?.first { $0.text.contains("Wolff-Chaikoff") }
                check("pressing 2 with the popup open highlights green", green?.highlightColor == .green && model.selectedID == green?.id,
                      green.map { "\($0.text) \($0.highlightColor.name)" } ?? "none")
                model.select(nil)
            }
            if let sel = select("struma ovarii", page: graves), let window = model.pdfView.window,
               let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                          context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
                model.pdfView.go(to: sel)
                model.pdfView.setCurrentSelection(sel, animate: false)
                model.selectionEnded()
                let shown = model.colorPopupAt != nil
                NSApp.postEvent(esc, atStart: false)
                await pause(0.3)
                check("Esc closes the color popup and keeps the selection", shown && model.colorPopupAt == nil && model.hasTextSelection
                      && !((try? store.highlights(page: graves)) ?? []).contains { $0.text.contains("struma ovarii") })
                model.pdfView.clearSelection()
            }
            if let sel = select("Focal patches", page: graves), let page = document.page(at: graves),
               let line = page.selectionForLine(at: CGPoint(x: sel.bounds(for: page).midX, y: sel.bounds(for: page).midY))?.bounds(for: page) {
                model.pdfView.go(to: sel)
                await pause(0.3)
                func dragAlong(drop: CGFloat) async -> [String] {
                    model.pdfView.clearSelection()
                    let points = (0...10).map { i -> NSPoint in
                        let t = CGFloat(i) / 10
                        let p = CGPoint(x: line.minX + 2 + t * (line.width - 30), y: line.midY - t * drop * line.height)
                        return model.pdfView.convert(model.pdfView.convert(p, from: page), to: nil)
                    }
                    drag(points)
                    await pause(0.4)
                    return model.pdfView.currentSelection?.selectionsByLine().compactMap(\.string) ?? []
                }
                let drift = await dragAlong(drop: 0.6)
                check("a drag that drifts below its line selects that line only", drift.count == 1 && drift.first?.hasPrefix("Focal") == true, drift)
                let down = await dragAlong(drop: 1.3)
                check("a drag into the next line selects both lines", down.count == 2, down)
                model.hideColorPopup()
                model.pdfView.clearSelection()
            }
            let liver = 394
            if let sel = select("(centrilobular) zone", page: liver), let page = document.page(at: liver),
               let below = select("Affected 1st by ischemia", page: liver)?.bounds(for: page) {
                let tall = sel.bounds(for: page)
                model.pdfView.go(to: sel)
                await pause(0.3)
                let row = model.pdfView.trimLine(tall, on: page)
                let points = (0...10).map { i -> NSPoint in
                    let p = CGPoint(x: tall.minX + 2 + CGFloat(i) * (tall.width - 4) / 10, y: row.midY - CGFloat(i) * 0.4)
                    return model.pdfView.convert(model.pdfView.convert(p, from: page), to: nil)
                }
                drag(points)
                await pause(0.4)
                let dragged = model.pdfView.currentSelection?.selectionsByLine().compactMap(\.string) ?? []
                check("a drag on a line with an oversized box stays on that row", dragged.count == 1 && dragged.first?.contains("centrilob") == true, dragged)
                model.hideColorPopup()
                model.pdfView.setCurrentSelection(sel, animate: false)
                model.applyColor(.yellow)
                let made = (try? store.highlights(page: liver))?.first { $0.text.contains("centrilobular") }
                let r = made?.rects.first
                check("a highlight on a line with an oversized box covers one row",
                      tall.height > 20 && r.map { $0.h < 15 && $0.y >= below.maxY - 0.5 } == true, "box \(tall) stored \(r.map { "\($0)" } ?? "none")")
                model.pdfView.clearSelection()
                if let made {
                    model.select(made.id)
                    let opened = model.barMode == .highlight
                    model.deleteSelected()
                    await pause(0.3)
                    check("deleting a highlight closes its bar and offers Undo", opened && model.barMode == nil && model.selected == nil
                          && model.notice?.message == "Highlight deleted", model.notice?.message ?? "no notice")
                }
                func exists(_ id: String) -> Bool { ((try? store.highlight(id: id)) ?? nil) != nil }
                if let made {
                    model.undo()
                    let undone = exists(made.id)
                    model.redo()
                    let redone = !exists(made.id)
                    model.undo()
                    check("⌘Z brings back a deleted highlight and ⇧⌘Z deletes it again", undone && redone && exists(made.id))
                }
                if let made, let inner = select("centrilob", page: liver) {
                    model.select(nil)
                    model.pdfView.setCurrentSelection(inner, animate: false)
                    model.applyColor(.pink)
                    let mine = ((try? store.highlights(page: liver)) ?? []).filter { $0.source == "app" }
                    let pinkWord = mine.first { $0.highlightColor == .pink }
                    let rest = mine.first { $0.id == made.id }
                    check("a color inside another color splits it, and partial words widen to the whole word",
                          pinkWord?.text == "centrilobular" && rest?.highlightColor == .yellow && rest?.text.contains("zone") == true
                          && overlapping(page: liver).isEmpty, mine.map { "\($0.text)=\($0.highlightColor.name)" })
                    model.undo()
                    let back = ((try? store.highlights(page: liver)) ?? []).filter { $0.source == "app" }
                    check("⌘Z puts the split highlight back in one piece", back.count == 1 && back.first?.id == made.id && back.first?.text == made.text,
                          back.map(\.text))
                    model.pdfView.clearSelection()
                }
                let line = "Affected 1st by ischemia"
                if let a = select("Affected 1st", page: liver, within: line), let b = select("by ischemia", page: liver, within: line) {
                    model.select(nil)
                    model.pdfView.setCurrentSelection(a, animate: false)
                    model.applyColor(.green)
                    model.select(nil)
                    model.pdfView.setCurrentSelection(b, animate: false)
                    model.applyColor(.green)
                    let greens = ((try? store.highlights(page: liver)) ?? []).filter { $0.highlightColor == .green && $0.source == "app" }
                    await capture("shot-liver.png")
                    check("a highlight next to one of the same color joins it", greens.count == 1 && greens.first?.text == "Affected 1st by ischemia",
                          greens.map(\.text))
                    model.select(nil)
                    if let middle = select("1st by", page: liver, within: line) {
                        model.pdfView.setCurrentSelection(middle, animate: false)
                        model.selectionEnded()
                        let offered = model.barItems.contains(.erase)
                        await capture("shot-erase-bar.png")
                        if let window = model.pdfView.window,
                           let del = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                      context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51) {
                            NSApp.postEvent(del, atStart: false)
                            await pause(0.3)
                        }
                        await capture("shot-erased.png")
                        let left = ((try? store.highlights(page: liver)) ?? []).filter { $0.highlightColor == .green && $0.source == "app" }
                        check("Delete with highlighted text selected removes just that part", offered && left.map(\.text).sorted() == ["Affected", "ischemia"]
                              && model.notice != nil, "\(offered) \(left.map(\.text))")
                        model.undo()
                        let whole = ((try? store.highlights(page: liver)) ?? []).filter { $0.highlightColor == .green && $0.source == "app" }
                        check("⌘Z after removing restores the whole highlight", whole.map(\.text) == ["Affected 1st by ischemia"], whole.map(\.text))
                    }
                }
                if let made, let inner = select("centrilob", page: liver), let window = model.pdfView.window {
                    model.select(nil)
                    let b = model.pdfView.trimLine(inner.bounds(for: page), on: page)
                    let legacy = Highlight(page: liver, rects: [Rect(x: b.minX, y: b.minY, w: b.width, h: b.height)], text: "centrilob", color: .pink,
                                           created: Date().timeIntervalSince1970 + 1)
                    try? store.add([legacy])
                    model.reconcile()
                    let spot = model.pdfView.convert(model.pdfView.convert(CGPoint(x: b.minX + 4, y: b.midY), from: page), to: nil)
                    drag([spot, spot])
                    let first = model.selectedID
                    drag([spot, spot])
                    let second = model.selectedID
                    check("clicking the same spot again steps down through stacked highlights made by older versions",
                          first == legacy.id && second == made.id, "\(first ?? "nil") \(second ?? "nil")")
                    model.select(nil)
                    model.pdfView.clearSelection()
                    model.tidyHighlights()
                    let tidied = ((try? store.highlights(page: liver)) ?? []).filter { $0.source == "app" }
                    check("Tidy splits the stack so no two highlights overlap and fragments become whole words",
                          overlapping(page: liver).isEmpty && tidied.contains { $0.highlightColor == .pink && $0.text == "centrilobular" },
                          "\(tidied.map { "\($0.text)=\($0.highlightColor.name)" }) overlaps=\(overlapping(page: liver))")
                    model.undo()
                    check("⌘Z undoes Tidy", overlapping(page: liver).count == 1, overlapping(page: liver))
                    if let event = NSEvent.mouseEvent(with: .rightMouseDown, location: spot, modifierFlags: [], timestamp: 0,
                                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                        let items = model.pdfView.menu(for: event)?.items ?? []
                        let deletes = items.filter { $0.title.hasPrefix("Delete “") }
                        if let lower = deletes.first(where: { $0.title.contains("Yellow") }), let action = lower.action {
                            NSApp.sendAction(action, to: lower.target, from: lower)
                        }
                        check("right-click on stacked highlights can delete the one underneath",
                              deletes.count == 2 && ((try? store.highlight(id: made.id)) ?? nil) == nil, items.map(\.title))
                    }
                    model.pdfView.clearSelection()
                }
                if let partial = select("schemi", page: liver) {
                    let snapped = model.pdfView.snapped(partial)
                    check("a selection that stops partway through a word widens to the whole word", snapped.string == "ischemia", snapped.string ?? "nil")
                }
            }
            model.select(nil)
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

        let browser = model.browser
        browser.reset()
        model.sidebarMode = .highlights
        let everything = model.allHighlights.count
        browser.colors = [.pink]
        let pinkOnly = model.browserGroups.flatMap(\.highlights)
        check("highlights list filters by color", !pinkOnly.isEmpty && pinkOnly.allSatisfy { $0.highlightColor == .pink } && pinkOnly.count < everything,
              "\(pinkOnly.count) of \(everything)")
        browser.colors = []
        browser.grouping = .color
        let byColor = model.browserGroups
        check("highlights list groups by color", byColor.count >= 2 && byColor.allSatisfy { g in g.highlights.allSatisfy { $0.highlightColor == g.color } },
              byColor.map { "\($0.title) \($0.highlights.count)" })
        browser.grouping = .section
        if let endocrine = model.sections.first(where: { $0.title == "Endocrine" }) {
            browser.sectionID = endocrine.id
            let inSection = model.browserGroups.flatMap(\.highlights)
            check("highlights list filters by section", !inSection.isEmpty && inSection.allSatisfy { endocrine.pages.contains($0.page) },
                  "\(inSection.count) in \(endocrine.pages)")
            browser.sectionID = nil
        }
        browser.from = "pdf 395"
        browser.to = "pdf 395"
        let onLiver = model.browserGroups.flatMap(\.highlights)
        check("highlights list filters by page range", !onLiver.isEmpty && onLiver.allSatisfy { $0.page == 394 }, onLiver.count)
        if let printed = model.printed(graves) {
            browser.from = printed
            browser.to = printed
            let onGraves = model.browserGroups.flatMap(\.highlights)
            check("page range accepts printed book pages", !onGraves.isEmpty && onGraves.allSatisfy { $0.page == graves }, "p. \(printed): \(onGraves.count)")
        }
        browser.reset()
        browser.text = "wolff"
        check("highlights list filters by text", model.browserGroups.flatMap(\.highlights).map(\.text).contains { $0.contains("Wolff-Chaikoff") })
        browser.reset()
        if let sample = model.allHighlights.first(where: { $0.page == graves && $0.source == "app" }) {
            let rects = sample.rects.map { CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h) }
            let crop = await model.thumbnailer?.crop(page: sample.page, rects: rects, color: sample.highlightColor.rgb, width: 280)
            check("page image around a highlight renders", (crop?.size.width ?? 0) > 100, crop.map { "\($0.size)" } ?? "nil")
        }
        model.goTo(page: graves)
        await capture("shot-list.png")
        browser.from = model.printed(graves) ?? ""
        browser.to = browser.from
        let panel = NSHostingView(rootView: HighlightsPanel(model: model, browser: browser).frame(width: 320, height: 760))
        panel.frame = CGRect(x: 0, y: 0, width: 320, height: 760)
        let holder = NSWindow(contentRect: panel.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        holder.contentView = panel
        await pause(1.5)
        snapshot(panel, "list.png")
        holder.contentView = nil
        browser.reset()
        model.sidebarMode = .chapters

        model.notesShown = true
        model.goTo(page: graves)
        await pause(0.4)
        check("notes pane follows the section being read", model.notesTitle == "Endocrine" && model.marky.text.contains(MarkdownExporter.blockStart),
              "\(model.notesTitle) \(model.marky.text.count) chars")
        if let url = model.notesURL {
            let mine = "\nThyroid storm: treat with the 4 Ps. #mine\n"
            try? (model.marky.text + mine).write(to: url, atomically: true, encoding: .utf8)
            model.refreshNotes(force: true)
            if let sel = select("Other causes", page: graves) {
                model.pdfView.setCurrentSelection(sel, animate: false)
                model.applyColor(.yellow)
            }
            model.exportQuietly()
            let onDisk = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            check("notes keep what you wrote when highlights change", onDisk.contains("treat with the 4 Ps. #mine") && onDisk.contains("Other causes"),
                  String(onDisk.suffix(300)))
            check("notes pane shows the updated file", model.marky.text == onDisk)
        }
        model.notesMode = MarkyView.Mode.preview.rawValue
        await pause(0.8)
        if let view = model.pdfView.window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: report.deletingLastPathComponent().appendingPathComponent("notes.png"))
        }
        let pageBeforeLink = model.currentPageIndex
        _ = model.marky.openURL?(URL(string: "fa-reader://open?page=100")!)
        await pause(0.3)
        check("page link clicked in notes moves the PDF", model.currentPageIndex == 99, "\(pageBeforeLink) -> \(model.currentPageIndex)")
        model.goTo(page: graves)
        await pause(0.3)

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
