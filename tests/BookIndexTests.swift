import Foundation
import PDFKit
import Testing
@testable import FACore

private let watermark = "Www.Medicalstudyzone.com"

private func freshDatabase() throws -> Database {
    let db = try Database(path: FileManager.default.temporaryDirectory.appendingPathComponent("fa-\(UUID().uuidString).sqlite").path)
    try Store.migrate(db)
    return db
}

@Test func cleanRemovesRepeatedFirstLine() {
    let pages = ["\(watermark)\n346\nGraves disease", "\(watermark)\n347\nText", "\(watermark)\nText", "Cover"]
    let cleaned = BookIndex.clean(pages)
    #expect(cleaned == ["346\nGraves disease", "347\nText", "Text", "Cover"])
}

@Test func cleanKeepsLinesThatAreNotRepeated() {
    let pages = ["Alpha\nbody", "Beta\nbody", "Gamma\nbody"]
    #expect(BookIndex.clean(pages) == pages)
}

@Test func cleanKeepsRepeatedLineAtOrBelowHalf() {
    let pages = ["Same\na", "Same\nb", "Other\nc", "Another\nd"]
    #expect(BookIndex.clean(pages) == pages)
}

@Test func printedLabelReadsPageNumber() {
    #expect(BookIndex.printedLabel("346\nGraves disease") == "346")
    #expect(BookIndex.printedLabel("\(watermark)\n346\nGraves disease") == "346")
    #expect(BookIndex.printedLabel("7\nx") == "7")
    #expect(BookIndex.printedLabel("12345\nx") == nil)
    #expect(BookIndex.printedLabel("Graves disease\n346") == nil)
    #expect(BookIndex.printedLabel("") == nil)
    #expect(BookIndex.printedLabel("\(watermark)") == nil)
}

@Test func isIndexedChecksRowCountAndVersion() throws {
    let db = try freshDatabase()
    #expect(try !BookIndex.isIndexed(db: db, pageCount: 2))
    try db.run("INSERT INTO book_pages(page, printed, text) VALUES(0, '1', 'a'), (1, '2', 'b')")
    #expect(try !BookIndex.isIndexed(db: db, pageCount: 2))
    try db.run("INSERT INTO meta(key, value) VALUES('book_index_version', ?)", BookIndex.version)
    #expect(try BookIndex.isIndexed(db: db, pageCount: 2))
    #expect(try !BookIndex.isIndexed(db: db, pageCount: 3))
    try db.run("UPDATE meta SET value='0' WHERE key='book_index_version'")
    #expect(try !BookIndex.isIndexed(db: db, pageCount: 2))
}

@Test func printedPageLookupBothWays() throws {
    let db = try freshDatabase()
    try db.run("INSERT INTO book_pages(page, printed, text) VALUES(0, NULL, 'cover'), (5, '3', 'a'), (9, '3', 'b'), (10, '4', 'c')")
    #expect(try BookIndex.printedPage(db: db, page: 5) == "3")
    #expect(try BookIndex.printedPage(db: db, page: 0) == nil)
    #expect(try BookIndex.printedPage(db: db, page: 99) == nil)
    #expect(try BookIndex.pdfPage(forPrinted: "3", db: db) == 5)
    #expect(try BookIndex.pdfPage(forPrinted: "4", db: db) == 10)
    #expect(try BookIndex.pdfPage(forPrinted: "8", db: db) == nil)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["FA_PDF"] != nil))
func indexRealBook() throws {
    let path = try #require(ProcessInfo.processInfo.environment["FA_PDF"])
    let document = try #require(PDFDocument(url: URL(fileURLWithPath: path)))
    let db = try freshDatabase()
    var lastProgress = (0, 0)
    let start = Date()
    try BookIndex.index(document: document, into: db) { lastProgress = ($0, $1) }
    print("index time: \(Date().timeIntervalSince(start)) s")
    #expect(lastProgress.0 == document.pageCount && lastProgress.1 == document.pageCount)
    #expect(try BookIndex.isIndexed(db: db, pageCount: document.pageCount))
    #expect(try BookIndex.printedPage(db: db, page: 366) == "346")
    #expect(try BookIndex.pdfPage(forPrinted: "346", db: db) == 366)
    #expect(try db.scalar("SELECT COUNT(*) FROM book_pages WHERE text LIKE 'Www.Medicalstudyzone%'") as? Int64 == 0)

    try BookIndex.index(document: document, into: db)
    #expect(try db.scalar("SELECT COUNT(*) FROM book_fts") as? Int64 == Int64(document.pageCount))
}

@Test func cleanAndLabelHandleCarriageReturns() {
    let pages = ["Www.Medicalstudyzone.com\r\n12\r\nbody", "Www.Medicalstudyzone.com\r\n13\r\nmore", "other"]
    let cleaned = BookIndex.clean(pages)
    #expect(!cleaned[0].contains("Medicalstudyzone"))
    #expect(BookIndex.printedLabel(pages[0]) == "12")
    #expect(BookIndex.printedLabel(cleaned[1]) == "13")
}
