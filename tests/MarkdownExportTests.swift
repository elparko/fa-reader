import Foundation
import Testing
@testable import FACore

private let testSections = [
    Section(id: 0, title: "Biochemistry", parent: "Section III: High-Yield Organ Systems", start: 0, end: 9),
    Section(id: 1, title: "Endocrine / Diabetes: notes", parent: "Section III: High-Yield Organ Systems", start: 10, end: 19),
    Section(id: 2, title: "Hematology", start: 20, end: 29),
]

private func outputDir() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("fa-out-\(UUID().uuidString)", isDirectory: true)
}

private func hl(_ id: String, page: Int, y: Double = 100, x: Double = 10, text: String = "text", color: HighlightColor = .yellow, note: String = "") -> Highlight {
    Highlight(id: id, page: page, rects: [Rect(x: x, y: y, w: 50, h: 10)], text: text, color: color, note: note)
}

private func makeStore() throws -> Store {
    let store = try Store(folder: tempFolder(), device: "mac-a", deviceName: "Mac A")
    try store.add([
        hl("a1", page: 2, text: "Papillary carcinoma:\nmost prevalent", color: .pink, note: "line 1\nline 2"),
        hl("b1", page: 12, text: "Graves disease", color: .green),
        hl("b2", page: 12, y: 300, text: "Hashimoto", color: .yellow),
        hl("b3", page: 15, text: "", color: .noteOnly, note: "remember this"),
        hl("c1", page: 25, text: "Sickle cell", color: .blue),
    ])
    return store
}

private func read(_ dir: URL, _ name: String) throws -> String {
    try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
}

@Test func linkFormat() {
    #expect(MarkdownExporter.link(page: 366) == "fa-reader://open?page=367")
    #expect(MarkdownExporter.link(page: 0, highlight: "abc") == "fa-reader://open?page=1&highlight=abc")
}

@Test func fileNameSanitizing() {
    #expect(MarkdownExporter.fileName(for: testSections[0]) == "00 Biochemistry.md")
    let name = MarkdownExporter.fileName(for: testSections[1])
    #expect(name == "01 Endocrine Diabetes notes.md")
    #expect(MarkdownExporter.fileName(for: Section(id: 12, title: "A?B*C", start: 0, end: 1)) == "12 A B C.md")
}

@Test func exportWritesFilesPerSection() throws {
    let store = try makeStore()
    let dir = outputDir()
    let result = try MarkdownExporter.export(store: store, sections: testSections, to: dir) { $0 == 12 ? "346" : nil }
    #expect(result.written == ["00 Biochemistry.md", "01 Endocrine Diabetes notes.md", "02 Hematology.md"])
    #expect(result.unchanged.isEmpty && result.removed.isEmpty)

    let bio = try read(dir, "00 Biochemistry.md")
    #expect(bio == """
        ---
        fa-reader-export: 1
        section: "Biochemistry"
        parent: "Section III: High-Yield Organ Systems"
        pdf-pages: 1-10
        highlights: 1
        ---
        # Biochemistry

        ## PDF p. 3
        - ==Papillary carcinoma: most prevalent== (pink) [open](fa-reader://open?page=3&highlight=a1) <!-- fa:a1 -->
          > line 1
          > line 2

        """)

    let endo = try read(dir, "01 Endocrine Diabetes notes.md")
    #expect(endo.contains("section: \"Endocrine / Diabetes: notes\"\n"))
    #expect(endo.contains("pdf-pages: 11-20\nhighlights: 3\n"))
    #expect(endo.contains("## p. 346 (PDF 13)\n"))
    #expect(endo.contains("## PDF p. 16\n- Note: remember this [open](fa-reader://open?page=16&highlight=b3) <!-- fa:b3 -->\n"))

    let heme = try read(dir, "02 Hematology.md")
    #expect(!heme.contains("parent:"))
}

@Test func reExportIsStable() throws {
    let store = try makeStore()
    let dir = outputDir()
    _ = try MarkdownExporter.export(store: store, sections: testSections, to: dir)
    let before = try testSections.map { try Data(contentsOf: dir.appendingPathComponent(MarkdownExporter.fileName(for: $0))) }
    let again = try MarkdownExporter.export(store: store, sections: testSections, to: dir)
    #expect(again.written.isEmpty && again.removed.isEmpty)
    #expect(again.unchanged.count == 3)
    let after = try testSections.map { try Data(contentsOf: dir.appendingPathComponent(MarkdownExporter.fileName(for: $0))) }
    #expect(before == after)
    let text = try read(dir, "00 Biochemistry.md")
    #expect(text.components(separatedBy: "fa:a1").count == 2)
}

@Test func changedNoteRewritesOnlyThatFile() throws {
    let store = try makeStore()
    let dir = outputDir()
    _ = try MarkdownExporter.export(store: store, sections: testSections, to: dir)
    try store.setNote("c1", "new note")
    let result = try MarkdownExporter.export(store: store, sections: testSections, to: dir)
    #expect(result.written == ["02 Hematology.md"])
    #expect(result.unchanged.count == 2)
    #expect(try read(dir, "02 Hematology.md").contains("  > new note\n"))
}

@Test func removesStaleExportFilesOnly() throws {
    let store = try makeStore()
    let dir = outputDir()
    _ = try MarkdownExporter.export(store: store, sections: testSections, to: dir)
    let foreign = dir.appendingPathComponent("my notes.md")
    try "# mine\n".write(to: foreign, atomically: true, encoding: .utf8)
    let fakeMarker = dir.appendingPathComponent("mentions marker.md")
    try "# text\nfa-reader-export: 1\n".write(to: fakeMarker, atomically: true, encoding: .utf8)

    try store.delete(["c1"])
    let result = try MarkdownExporter.export(store: store, sections: testSections, to: dir)
    #expect(result.removed == ["02 Hematology.md"])
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("02 Hematology.md").path))
    #expect(FileManager.default.fileExists(atPath: foreign.path))
    #expect(FileManager.default.fileExists(atPath: fakeMarker.path))
}

@Test func renamedSectionRemovesOldFile() throws {
    let store = try makeStore()
    let dir = outputDir()
    _ = try MarkdownExporter.export(store: store, sections: testSections, to: dir)
    var renamed = testSections
    renamed[2].title = "Blood"
    let result = try MarkdownExporter.export(store: store, sections: renamed, to: dir)
    #expect(result.written == ["02 Blood.md"])
    #expect(result.removed == ["02 Hematology.md"])
}

@Test func ordersWithinPageTopToBottomThenLeftToRight() {
    let hs = [
        hl("low", page: 1, y: 100, x: 10),
        hl("high-right", page: 1, y: 500, x: 300),
        hl("high-left", page: 1, y: 500, x: 20),
        hl("tie-b", page: 1, y: 50, x: 5),
        hl("tie-a", page: 1, y: 50, x: 5),
    ]
    let md = MarkdownExporter.render(section: testSections[0], highlights: hs) { _ in nil }
    let ids = md.components(separatedBy: "<!-- fa:").dropFirst().map { String($0.prefix { $0 != " " }) }
    #expect(ids == ["high-left", "high-right", "low", "tie-a", "tie-b"])
}

@Test func escapesEqualsAndPagesAscend() {
    let hs = [hl("x", page: 5, text: "a == b"), hl("y", page: 3, text: "first")]
    let md = MarkdownExporter.render(section: testSections[0], highlights: hs) { _ in nil }
    #expect(md.contains("==a \\=\\= b=="))
    #expect(md.range(of: "## PDF p. 4")!.lowerBound < md.range(of: "## PDF p. 6")!.lowerBound)
}
