import Foundation
import PDFKit
import Testing
@testable import FACore

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

private func makeStore() throws -> Store {
    try Store(folder: tempFolder(), device: "mac-a", deviceName: "Mac A")
}

private func addPage(_ db: Database, _ page: Int, _ text: String) throws {
    try db.run("INSERT INTO book_pages(page, printed, text) VALUES(?,?,?)", page, String(page - 20), text)
    try db.run("INSERT INTO book_fts(rowid, text) VALUES(?,?)", page, text)
}

private func strip(_ s: String) -> String {
    s.replacingOccurrences(of: Searcher.matchStart, with: "").replacingOccurrences(of: Searcher.matchEnd, with: "")
}

private func percentile95(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
}

@Test func ftsQueryBuildsPrefixTerms() {
    #expect(Searcher.ftsQuery("graves dis") == "\"graves\"* \"dis\"*")
    #expect(Searcher.ftsQuery("  HCO3– level ") == "\"HCO3\"* \"level\"*")
    #expect(Searcher.ftsQuery("") == nil)
    #expect(Searcher.ftsQuery("  -*() ") == nil)
}

@Test func ftsQueryNeverBreaksSearch() throws {
    let store = try makeStore()
    try addPage(store.db, 1, "sodium bicarbonate HCO3 level")
    try store.add([Highlight(page: 1, rects: [], text: "sodium", color: .yellow)])
    let searcher = Searcher(database: store.db)
    let nasty = ["\"", "\"\"", "(", ")", "((", "-", "--", "*", "**", ":", "::", "a:b", "col:x", "NOT", "AND", "OR", "NEAR(", "a OR",
                 "\"unterminated", "x\"y", "⊕", "HCO3–", "α-synuclein", "Na+/K+", "e'", "%", "_", "\\", "'; DROP TABLE meta;--",
                 "{text}:", "^", "+", "😀", "½", "日本語", "\u{0}", "a\nb", "\t", String(repeating: "a", count: 5000)]
    for input in nasty {
        _ = try searcher.search(input)
        _ = try searcher.search(input, filter: SearchFilter(color: .yellow))
        _ = try searcher.search(input, filter: SearchFilter(pages: 0...5, tag: "x"))
    }
}

@Test func prefixMatchingAsYouType() throws {
    let store = try makeStore()
    try addPage(store.db, 4, "Graves disease causes hyperthyroidism")
    try addPage(store.db, 5, "Hashimoto thyroiditis")
    let searcher = Searcher(database: store.db)
    for prefix in ["hy", "hyp", "hyper", "hyperthyroid", "hyperthyroidism"] {
        let results = try searcher.search(prefix)
        #expect(results.map(\.page) == [4], "prefix \(prefix)")
    }
    #expect(try searcher.search("graves dis").map(\.page) == [4])
    #expect(try searcher.search("graves hashi").isEmpty)
    #expect(try searcher.search("thyro").map(\.page).sorted() == [5])
}

@Test func snippetMarksMatchedTerms() throws {
    let store = try makeStore()
    try addPage(store.db, 4, "Graves disease causes hyperthyroidism through TSH receptor antibodies")
    let result = try #require(try Searcher(database: store.db).search("hyperthy").first)
    #expect(result.kind == .book)
    #expect(result.id == "book:4")
    #expect(result.snippet.contains("\(Searcher.matchStart)hyperthyroidism\(Searcher.matchEnd)"))
    #expect(result.highlightID == nil && result.color == nil)
}

@Test func highlightAndNoteKinds() throws {
    let store = try makeStore()
    let plain = Highlight(page: 10, rects: [], text: "Papillary carcinoma has psammoma bodies", color: .yellow)
    let noted = Highlight(page: 11, rects: [], text: "Follicular carcinoma spreads by blood", color: .pink)
    let both = Highlight(page: 12, rects: [], text: "Medullary carcinoma secretes calcitonin", color: .green)
    try store.add([plain, noted, both])
    try store.setNote(noted.id, "compare with papillary #thyroid")
    try store.setNote(both.id, "remember amyloid #thyroid")

    let searcher = Searcher(database: store.db)
    let papillary = try searcher.search("papillary")
    #expect(papillary.map(\.id) == ["note:\(noted.id)", "highlight:\(plain.id)"])
    #expect(papillary.map(\.kind) == [.note, .highlight])
    #expect(papillary[0].color == .pink && papillary[1].color == .yellow)
    #expect(papillary[1].highlightID == plain.id)

    let carcinoma = try searcher.search("carcinoma amyloid")
    #expect(carcinoma.map(\.id) == ["note:\(both.id)"])

    let byTag = try searcher.search("thyroid")
    #expect(Set(byTag.map(\.id)) == ["note:\(noted.id)", "note:\(both.id)"])

    let everything = try searcher.search("carcinoma")
    #expect(everything.count == 3)
    #expect(Set(everything.compactMap(\.highlightID)).count == 3)
}

@Test func resultsOrderNotesThenHighlightsThenBook() throws {
    let store = try makeStore()
    let h = Highlight(page: 1, rects: [], text: "thyroid storm", color: .yellow)
    let n = Highlight(page: 2, rects: [], text: "unrelated", color: .green, note: "thyroid note")
    try store.add([h, n])
    try addPage(store.db, 3, "thyroid gland")
    let kinds = try Searcher(database: store.db).search("thyroid").map(\.kind)
    #expect(kinds == [.note, .highlight, .book])
}

@Test func limitAppliesPerKind() throws {
    let store = try makeStore()
    try store.add((0..<10).map { Highlight(page: $0, rects: [], text: "thyroid \($0)", color: .yellow) }, confirmed: true)
    for p in 0..<10 { try addPage(store.db, p, "thyroid page \(p)") }
    let results = try Searcher(database: store.db).search("thyroid", limit: 4)
    #expect(results.filter { $0.kind == .highlight }.count == 4)
    #expect(results.filter { $0.kind == .book }.count == 4)
}

@Test func colorFilter() throws {
    let store = try makeStore()
    let pink = Highlight(page: 1, rects: [], text: "thyroid pink", color: .pink)
    let green = Highlight(page: 2, rects: [], text: "thyroid green", color: .green)
    try store.add([pink, green])
    try addPage(store.db, 3, "thyroid book text")
    let searcher = Searcher(database: store.db)
    let results = try searcher.search("thyroid", filter: SearchFilter(color: .pink))
    #expect(results.map(\.id) == ["highlight:\(pink.id)"])
    #expect(try searcher.search("thyroid").count == 3)
}

@Test func sectionPageFilterAppliesToAllKinds() throws {
    let store = try makeStore()
    let inside = Highlight(page: 50, rects: [], text: "thyroid inside", color: .pink)
    let outside = Highlight(page: 200, rects: [], text: "thyroid outside", color: .pink)
    try store.add([inside, outside])
    try addPage(store.db, 51, "thyroid inside book")
    try addPage(store.db, 201, "thyroid outside book")
    let results = try Searcher(database: store.db).search("thyroid", filter: SearchFilter(pages: 40...100))
    #expect(Set(results.map(\.id)) == ["highlight:\(inside.id)", "book:51"])
}

@Test func tagFilter() throws {
    let store = try makeStore()
    let a = Highlight(page: 1, rects: [], text: "thyroid a", color: .yellow, note: "#high-yield")
    let b = Highlight(page: 2, rects: [], text: "thyroid b", color: .yellow, note: "#review")
    let c = Highlight(page: 3, rects: [], text: "thyroid c", color: .yellow)
    try store.add([a, b, c])
    try addPage(store.db, 4, "thyroid book")
    let searcher = Searcher(database: store.db)
    let results = try searcher.search("thyroid", filter: SearchFilter(tag: "review"))
    #expect(results.map(\.id) == ["highlight:\(b.id)"])
    #expect(try searcher.search("thyroid", filter: SearchFilter(tag: "REVIEW")).count == 1)
    #expect(try searcher.search("thyroid", filter: SearchFilter(tag: "missing")).isEmpty)
}

@Test func combinedFilters() throws {
    let store = try makeStore()
    let a = Highlight(page: 10, rects: [], text: "thyroid a", color: .pink, note: "#review")
    let b = Highlight(page: 300, rects: [], text: "thyroid b", color: .pink, note: "#review")
    let c = Highlight(page: 10, rects: [], text: "thyroid c", color: .green, note: "#review")
    try store.add([a, b, c])
    let filter = SearchFilter(color: .pink, pages: 0...100, tag: "review")
    #expect(try Searcher(database: store.db).search("thyroid", filter: filter).map(\.highlightID) == [a.id])
}

@Test func emptyQueryListsFilteredHighlightsByPage() throws {
    let store = try makeStore()
    let late = Highlight(page: 90, rects: [], text: "late", color: .pink)
    let early = Highlight(page: 5, rects: [], text: "early", color: .pink, note: "has note")
    let other = Highlight(page: 6, rects: [], text: "other", color: .green)
    try store.add([late, early, other])
    let searcher = Searcher(database: store.db)
    let pink = try searcher.search("", filter: SearchFilter(color: .pink))
    #expect(pink.map(\.highlightID) == [early.id, late.id])
    #expect(pink.map(\.page) == [5, 90])
    #expect(try searcher.search("  ", filter: SearchFilter(pages: 0...10)).map(\.page) == [5, 6])
    #expect(try searcher.search("", filter: SearchFilter(tag: "nothing")).isEmpty)
    #expect(try searcher.search("").isEmpty)
    #expect(try searcher.search("-*", filter: SearchFilter()).isEmpty)
}

@Test func deletedHighlightsDisappear() throws {
    let store = try makeStore()
    let h = Highlight(page: 1, rects: [], text: "thyroid storm", color: .pink, note: "#review")
    try store.add([h])
    let searcher = Searcher(database: store.db)
    #expect(try searcher.search("thyroid").count == 1)
    try store.delete([h.id])
    #expect(try searcher.search("thyroid").isEmpty)
    #expect(try searcher.search("", filter: SearchFilter(color: .pink)).isEmpty)
    #expect(try searcher.search("", filter: SearchFilter(tag: "review")).isEmpty)
}

@Test func noteEditsChangeResultKind() throws {
    let store = try makeStore()
    let h = Highlight(page: 1, rects: [], text: "thyroid storm", color: .pink)
    try store.add([h])
    let searcher = Searcher(database: store.db)
    #expect(try searcher.search("mnemonic").isEmpty)
    try store.setNote(h.id, "mnemonic for storm")
    #expect(try searcher.search("mnemonic").map(\.kind) == [.note])
    try store.setNote(h.id, "")
    #expect(try searcher.search("mnemonic").isEmpty)
    #expect(try searcher.search("thyroid").map(\.kind) == [.highlight])
}

@Test func opensOwnConnectionByPath() throws {
    let store = try makeStore()
    try store.add([Highlight(page: 1, rects: [], text: "thyroid storm", color: .pink)])
    let searcher = try Searcher(databasePath: store.db.path)
    #expect(try searcher.search("thyroid").count == 1)
    try store.add([Highlight(page: 2, rects: [], text: "thyroid crisis", color: .pink)])
    #expect(try searcher.search("thyroid").count == 2)
}

@Test func syntheticBookLatency() throws {
    let store = try makeStore()
    let db = store.db
    var rng = SeededGenerator(state: 42)
    let seedWords = """
        thyroid hyperthyroidism hypothyroidism graves disease papillary carcinoma follicular medullary calcitonin secretin gastrin \
        urease pylori insulin glucagon cortisol aldosterone renin angiotensin sodium potassium bicarbonate chloride tubule \
        glomerulus nephron antibody receptor kinase phosphatase enzyme substrate deficiency syndrome mutation chromosome \
        autosomal dominant recessive x-linked infection bacteria virus fungus parasite treatment toxicity adverse effect \
        mechanism inhibitor agonist antagonist hepatocyte cirrhosis hepatitis pancreatitis ulcer carcinoma lymphoma leukemia \
        anemia thrombosis embolism ischemia infarction hypertension hypotension arrhythmia murmur ventricle atrium valve
        """.split(separator: " ").map(String.init)
    let vocabulary = seedWords + (0..<3000).map { i -> String in
        let stems = ["cardio", "neuro", "hepato", "nephro", "gastro", "endo", "hemo", "immuno", "pulmo", "osteo"]
        let ends = ["pathy", "itis", "oma", "osis", "genic", "plasia", "trophy", "lysis", "penia", "emia"]
        return stems[i % 10] + ends[(i / 10) % 10] + String(i / 100)
    }
    try db.transaction {
        for page in 0..<865 {
            var words: [String] = []
            var length = 0
            while length < 2500 {
                let w = vocabulary[Int(rng.next() % UInt64(vocabulary.count))]
                words.append(w)
                length += w.count + 1
            }
            try addPage(db, page, words.joined(separator: " "))
        }
    }
    let colors: [HighlightColor] = [.yellow, .green, .pink, .blue]
    var highlights: [Highlight] = []
    for i in 0..<2000 {
        let text = (0..<12).map { _ in vocabulary[Int(rng.next() % UInt64(vocabulary.count))] }.joined(separator: " ")
        let note = i % 3 == 0 ? "\((0..<6).map { _ in vocabulary[Int(rng.next() % UInt64(vocabulary.count))] }.joined(separator: " ")) #tag\(i % 7)" : ""
        highlights.append(Highlight(page: i % 865, rects: [], text: text, color: colors[i % 4], note: note))
    }
    try store.add(highlights, confirmed: true)

    let searcher = Searcher(database: db)
    let typed = (1...15).map { String("hyperthyroidism".prefix($0)) }
        + (1...13).map { String("graves disease".prefix($0)) }
        + (1...19).map { String("papillary carcinoma".prefix($0)) } + ["a", "c", "e", "th", "s"]
    let filters = [SearchFilter(), SearchFilter(color: .pink), SearchFilter(pages: 300...420), SearchFilter(tag: "tag3"),
                   SearchFilter(color: .green, pages: 0...500)]
    var timings: [Double] = []
    var round = 0
    while timings.count < 200 {
        for query in typed {
            let filter = filters[round % filters.count]
            round += 1
            let start = DispatchTime.now().uptimeNanoseconds
            _ = try searcher.search(query, filter: filter)
            timings.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
    }
    let p95 = percentile95(timings)
    print("synthetic latency over \(timings.count) queries: p95 \(p95) ms, max \(timings.max()!) ms")
    #expect(p95 < 50)
    #expect(try searcher.search("hyperthyroidism").contains { $0.kind == .book })
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["FA_PDF"] != nil))
func searchRealBook() throws {
    let path = try #require(ProcessInfo.processInfo.environment["FA_PDF"])
    let document = try #require(PDFDocument(url: URL(fileURLWithPath: path)))
    let store = try makeStore()
    try BookIndex.index(document: document, into: store.db)
    let searcher = Searcher(database: store.db)

    var pagesFor: [String: [Int]] = [:]
    for term in ["papillary", "Graves", "secretin", "urease"] {
        let start = DispatchTime.now().uptimeNanoseconds
        let results = try searcher.search(term)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        print("real search \(term): \(results.count) results, \(ms) ms")
        #expect(ms < 50)
        #expect(!results.isEmpty)
        #expect(results.allSatisfy { $0.kind == .book })
        pagesFor[term] = results.map(\.page)
    }
    #expect(try #require(pagesFor["Graves"]).contains(366))

    let sections = Sections.from(document: document)
    let endocrine = try #require(sections.first { $0.title.lowercased().contains("endocrine") })
    let inSection = try searcher.search("Graves", filter: SearchFilter(pages: endocrine.pages))
    #expect(inSection.contains { $0.page == 366 })
    #expect(inSection.allSatisfy { endocrine.pages.contains($0.page) })
}
