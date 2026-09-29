import AppKit
import Foundation
import PDFKit
import Testing
@testable import FACore

private let base = Date(timeIntervalSince1970: 1_700_000_000)

private func ann(_ i: Int, page: Int, at seconds: Double) -> RawAnnotation {
    RawAnnotation(fingerprint: String(format: "%016x", i), type: "Highlight", page: page,
                  bounds: Rect(x: 0, y: 0, w: 10, h: 10), rects: [Rect(x: 0, y: 0, w: 10, h: 10)],
                  text: "t\(i)", contents: "", color: .yellow, date: base.addingTimeInterval(seconds))
}

private func burst(_ n: Int, startID: Int, at start: Double, pageSpan: Int) -> [RawAnnotation] {
    (0..<n).map { ann(startID + $0, page: $0 % pageSpan, at: start + Double($0) * 5 / Double(n)) }
}

private func manual(_ n: Int, startID: Int, at start: Double) -> [RawAnnotation] {
    (0..<n).map { ann(startID + $0, page: 100 + $0, at: start + Double($0) * 30) }
}

@Test func twoBurstsAreFoundAndExcluded() {
    var all = manual(5, startID: 0, at: 0)
    all += burst(400, startID: 1000, at: 1000, pageSpan: 300)
    all += manual(5, startID: 2000, at: 2000)
    all += burst(865, startID: 3000, at: 3000, pageSpan: 865)
    all += manual(5, startID: 4000, at: 4000)

    let preview = PreviewImporter.preview(annotations: all.shuffled(), alreadyImported: [])
    #expect(preview.bursts.map(\.count) == [400, 865])
    #expect(preview.bursts.map(\.id) == [0, 1])
    #expect(preview.bursts[0].pages == 300)
    #expect(preview.bursts[1].pages == 865)

    let kept = preview.selected()
    #expect(kept.count == 15)
    #expect(kept.allSatisfy { $0.burst == nil })
    #expect(preview.selected(includingBursts: [0]).count == 415)
    #expect(preview.selected(includingBursts: [0, 1]).count == 1280)
    #expect(preview.plan().ops.count == 15)
    #expect(preview.plan().kind == .import)
}

@Test func gapExactlyMaxGapStaysInOneCluster() {
    let items = (0..<15).map { ann($0, page: 1, at: Double($0) * 3) }
    #expect(PreviewImporter.detectBursts(items).count == 1)
    var split = items
    split[7].date = split[7].date!.addingTimeInterval(0.5)
    for i in 8..<15 { split[i].date = split[i].date!.addingTimeInterval(0.5) }
    let gapped = PreviewImporter.detectBursts(split)
    #expect(gapped.count == 0)
}

@Test func countThreshold() {
    let fourteen = (0..<14).map { ann($0, page: 1, at: Double($0)) }
    let fifteen = (0..<15).map { ann($0, page: 1, at: Double($0)) }
    #expect(PreviewImporter.detectBursts(fourteen).isEmpty)
    #expect(PreviewImporter.detectBursts(fifteen).count == 1)
}

@Test func fivePagesInTenSeconds() {
    let five = (0..<5).map { ann($0, page: $0, at: Double($0) * 2.5) }
    #expect(PreviewImporter.detectBursts(five).count == 1)
    let four = (0..<4).map { ann($0, page: $0, at: Double($0) * 2.5) }
    #expect(PreviewImporter.detectBursts(four).isEmpty)
    let slow = (0..<5).map { ann($0, page: $0, at: Double($0) * 3) }
    #expect(PreviewImporter.detectBursts(slow).isEmpty)
    let samePage = (0..<10).map { ann($0, page: 2, at: Double($0)) }
    #expect(PreviewImporter.detectBursts(samePage).isEmpty)
}

@Test func undatedAnnotationsAreNeverBursts() {
    var items = (0..<30).map { ann($0, page: $0, at: 0) }
    for i in items.indices { items[i].date = nil }
    let preview = PreviewImporter.preview(annotations: items, alreadyImported: [])
    #expect(preview.bursts.isEmpty)
    #expect(preview.selected().count == 30)
}

@Test func alreadyImportedAreSkipped() {
    let items = manual(3, startID: 0, at: 0)
    let preview = PreviewImporter.preview(annotations: items, alreadyImported: ["pv-" + items[1].fingerprint])
    #expect(preview.selected().count == 2)
    #expect(preview.candidates[1].alreadyImported)
    #expect(preview.candidates[0].highlight.source == "preview")
}

@Test func linksAreIgnoredAndFingerprintsAreStable() {
    let doc = PDFDocument()
    let page = PDFPage()
    doc.insert(page, at: 0)
    let h = PDFAnnotation(bounds: CGRect(x: 50, y: 50, width: 100.3, height: 12), forType: .highlight, withProperties: nil)
    h.color = NSColor(red: 0.98, green: 0.8, blue: 0.35, alpha: 1)
    page.addAnnotation(h)
    page.addAnnotation(PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 20, height: 20), forType: .link, withProperties: nil))
    let note = PDFAnnotation(bounds: CGRect(x: 60, y: 200, width: 100, height: 20), forType: .freeText, withProperties: nil)
    note.contents = " remember this "
    page.addAnnotation(note)

    let first = PreviewImporter.scan(doc)
    let second = PreviewImporter.scan(doc)
    #expect(first.map(\.type) == ["Highlight", "FreeText"])
    #expect(first.map(\.fingerprint) == second.map(\.fingerprint))
    #expect(first[0].color == .yellow)
    #expect(first[1].color == .noteOnly)
    #expect(first[1].contents == "remember this")
    #expect(first[0].fingerprint.count == 16)

    h.modificationDate = Date()
    h.color = NSColor.systemPink
    #expect(PreviewImporter.scan(doc)[0].fingerprint == first[0].fingerprint)
}

@Test func duplicateFingerprintsAreImportedOnce() {
    let a = ann(1, page: 3, at: 0)
    var b = a
    b.date = base.addingTimeInterval(60)
    let preview = PreviewImporter.preview(annotations: [a, b], alreadyImported: [])
    #expect(preview.candidates.count == 1)
    #expect(preview.plan().ops.count == 1)
}

@Test func nonFiniteBoundsDoNotCrash() {
    let doc = PDFDocument()
    let page = PDFPage()
    doc.insert(page, at: 0)
    let h = PDFAnnotation(bounds: CGRect(x: 0, y: 0, width: 3.4e38, height: 3.4e38), forType: .highlight, withProperties: nil)
    page.addAnnotation(h)
    let raws = PreviewImporter.scan(doc)
    #expect(raws.count == 1)
    #expect(raws[0].rects.isEmpty)
    #expect(raws[0].bounds.w < 10_000)
}

private let realPDF = ProcessInfo.processInfo.environment["FA_PDF"]

@Test(.enabled(if: ProcessInfo.processInfo.environment["FA_PDF"] != nil))
func realPDFImport() throws {
    let doc = try #require(PDFDocument(url: URL(fileURLWithPath: realPDF!)))
    let clock = ContinuousClock()
    var raws: [RawAnnotation] = []
    let elapsed = clock.measure { raws = PreviewImporter.scan(doc) }
    print("preview scan seconds:", elapsed)
    #expect(elapsed < .seconds(2))

    #expect(raws.filter { $0.type == "Highlight" }.count == 49)
    #expect(raws.filter { $0.type == "FreeText" }.count == 7)
    #expect(raws.count == 56)
    #expect(Set(raws.map(\.fingerprint)).count == 56)
    #expect(PreviewImporter.detectBursts(raws).isEmpty)
    #expect(Set(raws.map(\.color)).isSubset(of: [.green, .yellow, .pink, .noteOnly]))
    #expect(raws.filter { $0.type == "Highlight" }.allSatisfy { [.green, .yellow, .pink].contains($0.color) })

    let hl = try #require(raws.first { $0.type == "Highlight" && $0.page == 133 })
    #expect(hl.text.contains("Anti-TSH receptor"))
    let ft = try #require(raws.first { $0.type == "FreeText" && $0.page == 588 })
    #expect(ft.contents.contains("pentazocine"))
    let located = raws.filter { $0.type == "Highlight" && !$0.rects.isEmpty }
    #expect(located.count == 48)
    #expect(located.allSatisfy { !$0.text.isEmpty })
    #expect(raws.filter { $0.rects.isEmpty }.allSatisfy { $0.text.isEmpty && $0.bounds.w < 10_000 })

    let store = try Store(folder: tempFolder(), device: "mac-a", deviceName: "Mac A")
    let preview = try PreviewImporter.preview(document: doc, store: store)
    #expect(preview.bursts.isEmpty)
    let plan = preview.plan()
    #expect(plan.ops.count == 56)
    #expect(plan.pages.count > 20)
    #expect(throws: GuardError.self) { try store.commit(plan) }
    _ = try store.commit(plan, confirmed: true)
    #expect(try store.highlights().count == 56)

    let again = try PreviewImporter.preview(document: doc, store: store)
    #expect(again.candidates.count == 56)
    #expect(again.candidates.allSatisfy { $0.alreadyImported })
    #expect(again.plan().ops.isEmpty)
}

@Test func scanSkipsTheAppsOwnInMemoryAnnotations() {
    let doc = PDFDocument()
    let page = PDFPage()
    doc.insert(page, at: 0)
    let own = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 50, height: 12), forType: .highlight, withProperties: nil)
    own.userName = "fa:abc"
    let outline = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 50, height: 12), forType: .highlight, withProperties: nil)
    outline.userName = "fa-selection"
    let preview = PDFAnnotation(bounds: CGRect(x: 10, y: 40, width: 50, height: 12), forType: .highlight, withProperties: nil)
    preview.userName = "Parker Smith"
    for a in [own, outline, preview] { page.addAnnotation(a) }
    #expect(PreviewImporter.scan(doc).count == 1)
}
