import Foundation
import PDFKit
import Testing
@testable import FACore

@Test func normalizeSectionNumerals() {
    #expect(Sections.normalize("SECTION I I  High-Yield  General Principles") == "Section II: High-Yield General Principles")
    #expect(Sections.normalize("SECTION I V Top-Rated Review  Resources") == "Section IV: Top-Rated Review Resources")
    #expect(Sections.normalize("Hematology\nand Oncology") == "Hematology and Oncology")
}

@Test func buildRangesAreContiguous() {
    let entries: [(title: String, parent: String?, start: Int)] = [
        ("Part", nil, 0), ("Chapter A", "Part", 10), ("Chapter B", "Part", 30), ("Other", nil, 60),
    ]
    let sections = Sections.build(entries, pageCount: 100)
    #expect(sections.map(\.title) == ["Part", "Chapter A", "Chapter B", "Other"])
    #expect(sections.map(\.id) == [0, 1, 2, 3])
    #expect(sections.first?.start == 0 && sections.last?.end == 99)
    for (a, b) in zip(sections, sections.dropFirst()) { #expect(a.end + 1 == b.start) }
    #expect(sections[0].end == 9)
}

@Test func buildChildReplacesParentAtSamePage() {
    let entries: [(title: String, parent: String?, start: Int)] = [
        ("Part", nil, 0), ("Chapter A", "Part", 0), ("Chapter B", "Part", 20),
    ]
    let sections = Sections.build(entries, pageCount: 40)
    #expect(sections.map(\.title) == ["Chapter A", "Chapter B"])
    #expect(sections[0].parent == "Part")
    #expect(sections[0].start == 0 && sections[0].end == 19)
    #expect(sections[1].end == 39)
}

@Test func buildSortsUnorderedEntries() {
    let entries: [(title: String, parent: String?, start: Int)] = [("B", nil, 50), ("A", nil, 0)]
    let sections = Sections.build(entries, pageCount: 80)
    #expect(sections.map(\.title) == ["A", "B"])
    #expect(sections[0].end == 49)
}

@Test func sectionForPage() {
    let entries: [(title: String, parent: String?, start: Int)] = [("A", nil, 0), ("B", nil, 10), ("C", nil, 20)]
    let sections = Sections.build(entries, pageCount: 30)
    #expect(Sections.section(for: 0, in: sections)?.title == "A")
    #expect(Sections.section(for: 9, in: sections)?.title == "A")
    #expect(Sections.section(for: 10, in: sections)?.title == "B")
    #expect(Sections.section(for: 29, in: sections)?.title == "C")
    #expect(Sections.section(for: 5, in: []) == nil)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["FA_PDF"] != nil))
func realPDFSections() throws {
    let path = try #require(ProcessInfo.processInfo.environment["FA_PDF"])
    let doc = try #require(PDFDocument(url: URL(fileURLWithPath: path)))
    let sections = Sections.from(document: doc)
    let bio = try #require(sections.first { $0.title == "Biochemistry" })
    #expect(bio.start == 51)
    let endo = try #require(sections.first { $0.title == "Endocrine" })
    #expect(endo.start == 349)
    #expect(endo.parent == "Section III: High-Yield Organ Systems")
    #expect(Sections.section(for: 366, in: sections)?.title == "Endocrine")
    #expect(sections.first?.start == 0)
    #expect(sections.last?.end == 864)
    for (a, b) in zip(sections, sections.dropFirst()) { #expect(a.end + 1 == b.start) }
}
