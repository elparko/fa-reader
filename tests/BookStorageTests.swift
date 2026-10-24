import Foundation
import PDFKit
import Testing
@testable import FACore

private func scratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("fa-store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func contentHashIsSHA256AndStreamsChunks() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("hash-\(UUID().uuidString)")
    try Data("abc".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(try BookIdentity.contentHash(of: url) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    #expect(try BookIdentity.contentHash(of: url, chunkSize: 1) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    #expect(BookIdentity.isContentHash(try BookIdentity.contentHash(of: url)))
    #expect(!BookIdentity.isContentHash("one.fa-reader"))
    #expect(!BookIdentity.isContentHash(String(repeating: "a", count: 63)))
    #expect(!BookIdentity.isContentHash(String(repeating: "g", count: 64)))
}

@Test func unsandboxedBookStaysBesideThePDF() {
    let pdf = URL(fileURLWithPath: "/Users/x/Docs/first aid.pdf")
    let place = BookDataLocator.place(pdfURL: pdf, bookID: "abc", sandboxed: false,
                                      ubiquityContainer: URL(fileURLWithPath: "/Ubiquity", isDirectory: true),
                                      applicationSupport: URL(fileURLWithPath: "/Support", isDirectory: true))
    #expect(place.root.path == "/Users/x/Docs/first aid.fa-reader")
    if case .besidePDF = place {} else { Issue.record("expected the folder beside the PDF") }
}

@Test func sandboxedBookUsesICloudDocumentsKeyedByID() {
    let pdf = URL(fileURLWithPath: "/Users/x/Docs/first aid.pdf")
    let ubi = URL(fileURLWithPath: "/Ubiquity", isDirectory: true)
    let place = BookDataLocator.place(pdfURL: pdf, bookID: "abc123", sandboxed: true, ubiquityContainer: ubi,
                                      applicationSupport: URL(fileURLWithPath: "/Support", isDirectory: true))
    #expect(place.root.path == "/Ubiquity/Documents/Books/abc123")
    if case .ubiquityDocuments = place {} else { Issue.record("expected the ubiquity container") }
}

@Test func sandboxedBookFallsBackToApplicationSupport() {
    let pdf = URL(fileURLWithPath: "/Users/x/Docs/first aid.pdf")
    let support = URL(fileURLWithPath: "/Support", isDirectory: true)
    let place = BookDataLocator.place(pdfURL: pdf, bookID: "abc123", sandboxed: true, ubiquityContainer: nil, applicationSupport: support)
    #expect(place.root.path == "/Support/Books/abc123")
    if case .applicationSupport = place {} else { Issue.record("expected Application Support") }
}

@Test func sandboxedOpenMigratesAReadableSidecarAndLeavesIt() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let books = root.appendingPathComponent("Books", isDirectory: true)
    let pdf = books.appendingPathComponent("Guide.pdf")
    try FileManager.default.createDirectory(at: books, withIntermediateDirectories: true)
    try Data("pdf-bytes".utf8).write(to: pdf)
    let sidecar = SyncFolder(pdfURL: pdf)
    try sidecar.prepare()
    try sidecar.append([Data("not-json".utf8)], device: "other")
    try FileManager.default.createDirectory(at: sidecar.markdownURL, withIntermediateDirectories: true)
    try Data("# notes\n".utf8).write(to: sidecar.markdownURL.appendingPathComponent("01 Guide.md"))
    try Data("OLD".utf8).write(to: sidecar.databaseURL)

    let support = root.appendingPathComponent("Support", isDirectory: true)
    let opened = try BookOpener.prepare(pdfURL: pdf, sandboxed: true, ubiquityContainer: nil, applicationSupport: support, device: "mac")
    let hash = try BookIdentity.contentHash(of: pdf)
    let expected = BookDataLocator.place(pdfURL: pdf, bookID: hash, sandboxed: true, ubiquityContainer: nil, applicationSupport: support)
    #expect(opened.bookID == hash)
    #expect(opened.folder.root.path == expected.root.path)
    #expect(opened.migration.sidecarReadable)
    #expect(opened.migration.copiedLogs == ["other.jsonl"])
    #expect(opened.migration.copiedMarkdown == ["01 Guide.md"])
    #expect(!opened.migration.destinationHadLogs)
    #expect(try String(contentsOf: opened.folder.logURL(device: "other"), encoding: .utf8) == "not-json\n")
    #expect(try String(contentsOf: opened.folder.markdownURL.appendingPathComponent("01 Guide.md"), encoding: .utf8) == "# notes\n")
    #expect(!FileManager.default.fileExists(atPath: opened.folder.databaseURL.path))
    #expect(try String(contentsOf: sidecar.databaseURL, encoding: .utf8) == "OLD")
    let identity = try JSONSerialization.jsonObject(with: Data(contentsOf: opened.folder.root.appendingPathComponent("book.json"))) as? [String: String]
    #expect(identity?["id"] == hash)
    #expect(identity?["file"] == "Guide.pdf")

    try Data("changed\n".utf8).write(to: opened.folder.logURL(device: "other"))
    let again = try BookOpener.prepare(pdfURL: pdf, sandboxed: true, ubiquityContainer: nil, applicationSupport: support, device: "mac")
    #expect(again.migration.destinationHadLogs)
    #expect(again.migration.copiedLogs == ["other.jsonl"])
    #expect(try String(contentsOf: again.folder.logURL(device: "other"), encoding: .utf8) == "changed\nnot-json\n")
    let third = try BookOpener.prepare(pdfURL: pdf, sandboxed: true, ubiquityContainer: nil, applicationSupport: support, device: "mac")
    #expect(third.migration.copiedLogs.isEmpty)
    #expect(try String(contentsOf: third.folder.logURL(device: "other"), encoding: .utf8) == "changed\nnot-json\n")

    let store = try Store(folder: opened.folder, device: "mac", deviceName: "Mac")
    #expect(store.folder.databaseURL.path.hasSuffix("local.nosync/fa.sqlite"))
    #expect(try Data(contentsOf: store.folder.databaseURL).prefix(6) == Data("SQLite".utf8))
}

@Test func sandboxedOpenPrefersTheUbiquityContainer() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let pdf = root.appendingPathComponent("Guide.pdf")
    try Data("pdf-bytes".utf8).write(to: pdf)
    let ubi = root.appendingPathComponent("Ubiquity", isDirectory: true)
    let opened = try BookOpener.prepare(pdfURL: pdf, sandboxed: true, ubiquityContainer: ubi, applicationSupport: root.appendingPathComponent("Support"), device: "mac")
    let hash = try #require(opened.bookID)
    let expected = BookDataLocator.containerPlace(bookID: hash, ubiquityContainer: ubi, applicationSupport: root.appendingPathComponent("Support"))
    #expect(opened.place.root.path == expected.root.path)
    #expect(!opened.migration.sidecarReadable)
}

@Test func applicationSupportBookMovesIntoICloudWhenTheContainerAppears() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let pdf = root.appendingPathComponent("Guide.pdf")
    try Data("pdf-bytes".utf8).write(to: pdf)
    let support = root.appendingPathComponent("Support", isDirectory: true)
    let first = try BookOpener.prepare(pdfURL: pdf, sandboxed: true, ubiquityContainer: nil, applicationSupport: support, device: "mac")
    try Data("local-log\n".utf8).write(to: first.folder.logURL(device: "mac"))
    try FileManager.default.createDirectory(at: first.folder.markdownURL, withIntermediateDirectories: true)
    try Data("note".utf8).write(to: first.folder.markdownURL.appendingPathComponent("01.md"))

    let ubi = root.appendingPathComponent("Ubiquity", isDirectory: true)
    let second = try BookOpener.prepare(pdfURL: pdf, sandboxed: true, ubiquityContainer: ubi, applicationSupport: support, device: "mac")
    #expect(second.migration.copiedLogs == ["mac.jsonl"])
    #expect(second.migration.copiedMarkdown == ["01.md"])
    #expect(try String(contentsOf: second.folder.logURL(device: "mac"), encoding: .utf8) == "local-log\n")
    #expect(second.folder.root.path != first.folder.root.path)
    let third = try BookOpener.prepare(pdfURL: pdf, sandboxed: true, ubiquityContainer: ubi, applicationSupport: support, device: "mac")
    #expect(third.migration.copiedLogs.isEmpty)
    #expect(try String(contentsOf: third.folder.logURL(device: "mac"), encoding: .utf8) == "local-log\n")
}

@Test func unsandboxedOpenDoesNotMoveTheSidecar() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let pdf = root.appendingPathComponent("Guide.pdf")
    try Data("pdf-bytes".utf8).write(to: pdf)
    let opened = try BookOpener.prepare(pdfURL: pdf, sandboxed: false, ubiquityContainer: root.appendingPathComponent("Ubiquity"), applicationSupport: root.appendingPathComponent("Support"), device: "mac")
    #expect(opened.bookID == nil)
    #expect(opened.folder.root.path == SyncFolder(pdfURL: pdf).root.path)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Ubiquity").path))
    #expect(!FileManager.default.fileExists(atPath: opened.folder.root.appendingPathComponent("book.json").path))
}

@Test func missingSidecarIsNotReadableAndCopiesNothing() throws {
    let dest = tempFolder()
    let missing = SyncFolder(root: URL(fileURLWithPath: "/no/such/sidecar-\(UUID().uuidString)", isDirectory: true))
    let report = SidecarMigration.migrate(from: missing, to: dest)
    #expect(!report.sidecarReadable)
    #expect(report.copiedLogs.isEmpty && report.copiedMarkdown.isEmpty)
}

@Test func migrationSkipsNotesThatAreNotMarkdownAndDoesNotCopyTheIndex() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let sidecar = SyncFolder(root: root.appendingPathComponent("Book.fa-reader", isDirectory: true))
    try sidecar.prepare()
    try Data("log".utf8).write(to: sidecar.logURL(device: "a"))
    try Data().write(to: sidecar.changesURL.appendingPathComponent("notes.txt"))
    try Data().write(to: sidecar.changesURL.appendingPathComponent(".hidden.jsonl"))
    try FileManager.default.createDirectory(at: sidecar.markdownURL, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: sidecar.markdownURL.appendingPathComponent("keep.md"))
    try Data("x".utf8).write(to: sidecar.markdownURL.appendingPathComponent("skip.txt"))
    try Data("OLD".utf8).write(to: sidecar.databaseURL)
    let dest = tempFolder()
    let report = SidecarMigration.migrate(from: sidecar, to: dest)
    #expect(report.copiedLogs == ["a.jsonl"])
    #expect(report.copiedMarkdown == ["keep.md"])
    #expect(!FileManager.default.fileExists(atPath: dest.databaseURL.path))
    #expect(!FileManager.default.fileExists(atPath: dest.changesURL.appendingPathComponent("notes.txt").path))
}

@Test func sidecarRootAcceptsTheFolderOrItsParent() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let books = root.appendingPathComponent("Books", isDirectory: true)
    let sidecar = books.appendingPathComponent("Guide.fa-reader", isDirectory: true)
    try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: true)
    let pdf = books.appendingPathComponent("Guide.pdf")
    #expect(SidecarMigration.root(selected: sidecar, pdfURL: pdf).path == sidecar.path)
    #expect(SidecarMigration.root(selected: books, pdfURL: pdf).path == sidecar.path)
    let loose = root.appendingPathComponent("loose", isDirectory: true)
    try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true)
    #expect(SidecarMigration.root(selected: loose, pdfURL: pdf).path == loose.path)
}

@Test func sandboxedOpenWithoutAContainerOrSupportThrows() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let pdf = root.appendingPathComponent("Guide.pdf")
    try Data("x".utf8).write(to: pdf)
    do {
        _ = try BookOpener.prepare(pdfURL: pdf, sandboxed: true, ubiquityContainer: nil, applicationSupport: nil, device: "mac")
        Issue.record("expected a missing Application Support error")
    } catch is BookStoreError {
    } catch {
        Issue.record("unexpected error \(error)")
    }
}

@Test func linkCarriesTheBookIDAndStillCarriesThePath() {
    let pdf = URL(fileURLWithPath: "/Books/Path oma & co.pdf")
    #expect(MarkdownExporter.link(page: 4, highlight: "abc", pdf: pdf, bookID: "abc123")
            == "rowlight://open?page=5&highlight=abc&book=abc123&pdf=/Books/Path%20oma%20%26%20co.pdf")
    let section = Section(id: 1, title: "Renal", start: 0, end: 9)
    let highlight = Highlight(id: "h1", page: 2, rects: [Rect(x: 0, y: 700, w: 10, h: 10)], text: "RTA", color: .green)
    let text = MarkdownExporter.render(section: section, highlights: [highlight], printedPage: { _ in nil }, pdf: pdf, bookID: "abc123")
    #expect(text.contains("rowlight://open?page=3&highlight=h1&book=abc123&pdf=/Books/Path%20oma%20%26%20co.pdf"))
}

@Test func readerLinkParsesBookIDAndPercentEncodedPath() throws {
    let url = try #require(URL(string: "fa-reader://open?page=5&highlight=abc&book=bbb&pdf=/Books/Path%20oma%20%26%20co.pdf"))
    let link = try #require(ReaderLinkResolver.parse(url))
    #expect(link == ReaderLink(page: 5, highlight: "abc", bookID: "bbb", pdfPath: "/Books/Path oma & co.pdf"))
    #expect(ReaderLinkResolver.parse(URL(string: "https://example.com")!) == nil)
    #expect(ReaderLinkResolver.parse(URL(string: "fa-reader://open")!) == ReaderLink())
}

@Test func readerLinkParsesBothSchemes() throws {
    let expected = ReaderLink(page: 5, highlight: "abc", bookID: "bbb", pdfPath: nil)
    for scheme in ["rowlight", "Rowlight", "fa-reader"] {
        let url = try #require(URL(string: "\(scheme)://open?page=5&highlight=abc&book=bbb"))
        #expect(ReaderLinkResolver.parse(url) == expected)
    }
    #expect(ReaderLinkResolver.parse(URL(string: "other://open?page=5")!) == nil)
}

@Test func readerLinkPrefersBookIDThenPathAndSkipsTheOpenBook() {
    let bookmarks = [
        SavedBookmark(path: "/a.pdf", name: "a.pdf", bookID: "aaa", data: Data([1])),
        SavedBookmark(path: "/b.pdf", name: "b.pdf", bookID: "bbb", data: Data([2])),
    ]
    let link = ReaderLink(page: 3, highlight: "h", bookID: "bbb", pdfPath: "/a.pdf")
    #expect(ReaderLinkResolver.bookmark(for: link, in: bookmarks, currentBookID: nil, currentPath: nil)?.path == "/b.pdf")
    #expect(ReaderLinkResolver.bookmark(for: link, in: bookmarks, currentBookID: "bbb", currentPath: "/b.pdf") == nil)
    #expect(ReaderLinkResolver.directPath(for: link, currentBookID: "bbb", currentPath: "/moved.pdf") == nil)

    let byPath = ReaderLink(pdfPath: "/a.pdf")
    #expect(ReaderLinkResolver.bookmark(for: byPath, in: bookmarks, currentBookID: "bbb", currentPath: "/b.pdf")?.bookID == "aaa")
    #expect(ReaderLinkResolver.bookmark(for: byPath, in: bookmarks, currentBookID: nil, currentPath: "/a.pdf") == nil)
    #expect(ReaderLinkResolver.directPath(for: ReaderLink(bookID: "missing", pdfPath: "/c.pdf"), currentBookID: nil, currentPath: nil) == "/c.pdf")
    #expect(ReaderLinkResolver.directPath(for: ReaderLink(pdfPath: "/c.pdf"), currentBookID: nil, currentPath: "/c.pdf") == nil)
}

@Test func bookmarkLibraryRoundTripsAndIgnoresLegacyOnceSaved() {
    let suite = "fa-bookmarks-\(UUID().uuidString)"
    let isolated = UserDefaults(suiteName: suite)!
    isolated.removePersistentDomain(forName: suite)
    let saved = [SavedBookmark(path: "/Books/a.pdf", name: "a.pdf", bookID: "abc", data: Data([9, 8, 7]))]
    BookmarkLibrary.saveRecents(saved, to: isolated)
    BookmarkLibrary.saveLastBook(saved[0], to: isolated)
    #expect(BookmarkLibrary.recents(from: isolated) == saved)
    #expect(BookmarkLibrary.lastBook(from: isolated) == saved[0])
    isolated.set(["/somewhere/else.pdf"], forKey: BookmarkLibrary.legacyRecentsKey)
    #expect(BookmarkLibrary.recents(from: isolated) == saved)
    BookmarkLibrary.saveLastBook(nil, to: isolated)
    #expect(BookmarkLibrary.lastBook(from: isolated) == nil)
    isolated.removePersistentDomain(forName: suite)
}

@Test func securityScopedBookmarkRoundTrips() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("bookmark-\(UUID().uuidString).pdf")
    try Data("%PDF".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let saved = try SavedBookmark.capturing(url, bookID: "abc")
    let resolved = try BookmarkStore.resolve(saved.data)
    #expect(resolved.url.standardizedFileURL.path == url.standardizedFileURL.path)
    #expect(resolved.url.lastPathComponent == saved.name)
}

private func opLine(id: String, seq: Int, highlight: String = "h") -> Data {
    Data(#"{"op":{"id":"\#(id)","device":"d","seq":\#(seq),"ts":1,"session":"s","kind":"add","highlight":"\#(highlight)","page":0}}"#.utf8)
}

private func sessionLine(id: String) -> Data {
    Data(#"{"session":{"id":"\#(id)","device":"d","deviceName":"D","started":1,"kind":"edit","label":"x"}}"#.utf8)
}

private func migrationFolders() throws -> (root: URL, source: SyncFolder, destination: SyncFolder) {
    let root = try scratch()
    let source = SyncFolder(root: root.appendingPathComponent("source", isDirectory: true))
    let destination = SyncFolder(root: root.appendingPathComponent("destination", isDirectory: true))
    try source.prepare()
    try destination.prepare()
    return (root, source, destination)
}

private func logText(_ folder: SyncFolder, _ device: String) throws -> [String] {
    try String(contentsOf: folder.logURL(device: device), encoding: .utf8).split(separator: "\n").map(String.init)
}

@Test func migrationIntoAnExistingLogAppendsMissingLinesOnce() throws {
    let (root, source, destination) = try migrationFolders()
    defer { try? FileManager.default.removeItem(at: root) }
    try destination.append([sessionLine(id: "s1"), opLine(id: "a", seq: 1)], device: "mac")
    try source.append([sessionLine(id: "s1"), opLine(id: "a", seq: 1), sessionLine(id: "s2"), opLine(id: "b", seq: 2)], device: "mac")

    let first = SidecarMigration.migrate(from: source, to: destination)
    #expect(first.copiedLogs == ["mac.jsonl"])
    #expect(first.idCollisions == 0)
    #expect(try logText(destination, "mac").count == 4)

    let second = SidecarMigration.migrate(from: source, to: destination)
    #expect(second.copiedLogs.isEmpty)
    #expect(try logText(destination, "mac").count == 4)
}

@Test func migrationCountsAnIdCollisionAndDoesNotAppendIt() throws {
    let (root, source, destination) = try migrationFolders()
    defer { try? FileManager.default.removeItem(at: root) }
    try destination.append([opLine(id: "a", seq: 1, highlight: "one")], device: "mac")
    try source.append([opLine(id: "a", seq: 1, highlight: "two"), opLine(id: "b", seq: 2)], device: "mac")

    let report = SidecarMigration.migrate(from: source, to: destination)
    #expect(report.idCollisions == 1)
    #expect(report.copiedLogs == ["mac.jsonl"])
    let lines = try logText(destination, "mac")
    #expect(lines.count == 2)
    #expect(!lines.contains { $0.contains(#""highlight":"two""#) })

    let again = SidecarMigration.migrate(from: source, to: destination)
    #expect(again.idCollisions == 1)
    #expect(again.copiedLogs.isEmpty)
    #expect(try logText(destination, "mac").count == 2)
}

@Test func differentPDFBytesGiveDifferentBookIDs() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let one = root.appendingPathComponent("one.pdf")
    let two = root.appendingPathComponent("two.pdf")
    try Data("one".utf8).write(to: one)
    try Data("two".utf8).write(to: two)
    #expect(try BookIdentity.contentHash(of: one) != BookIdentity.contentHash(of: two))
}

private let pdfKitLock = NSLock()

private func makePDF(at url: URL, pages: Int) throws {
    pdfKitLock.lock()
    defer { pdfKitLock.unlock() }
    let document = PDFDocument()
    for index in 0..<pages {
        let image = NSImage(size: NSSize(width: 200, height: 200), flipped: false) { rect in
            NSColor(calibratedWhite: CGFloat(index) / 10, alpha: 1).setFill()
            rect.fill()
            return true
        }
        document.insert(try #require(PDFPage(image: image)), at: index)
    }
    #expect(document.write(to: url))
}

private func annotate(_ url: URL) throws {
    pdfKitLock.lock()
    defer { pdfKitLock.unlock() }
    let document = try #require(PDFDocument(url: url))
    let page = try #require(document.page(at: 0))
    let note = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 50, height: 20), forType: .highlight, withProperties: nil)
    page.addAnnotation(note)
    #expect(document.write(to: url))
}

private func putLog(_ bookID: String, support: URL) throws {
    let folder = SyncFolder(root: BookDataLocator.containerPlace(bookID: bookID, ubiquityContainer: nil, applicationSupport: support).root)
    try folder.prepare()
    try Data("{}\n".utf8).write(to: folder.logURL(device: "mac"))
}

@Test func savedEditKeepsTheBookIDThroughKnownIDAndAlias() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let support = root.appendingPathComponent("Support")
    let pdf = root.appendingPathComponent("a.pdf")
    try makePDF(at: pdf, pages: 3)
    let first = try BookOpener.prepare(pdfURL: pdf, sandboxed: true, ubiquityContainer: nil, applicationSupport: support, device: "mac")
    let a = try #require(first.bookID)
    try putLog(a, support: support)
    try annotate(pdf)
    let edited = try BookIdentity.contentHash(of: pdf)
    #expect(edited != a)
    let second = try BookOpener.prepare(pdfURL: pdf, sandboxed: true, ubiquityContainer: nil, applicationSupport: support, knownBookID: a, device: "mac")
    #expect(second.bookID == a)
    #expect(FileManager.default.fileExists(atPath: support.appendingPathComponent("Aliases/\(edited).json").path))
    let hashFolder = SyncFolder(root: BookDataLocator.containerPlace(bookID: edited, ubiquityContainer: nil, applicationSupport: support).root)
    try hashFolder.prepare()
    try Data("other-mac-log\n".utf8).write(to: hashFolder.logURL(device: "other-mac"))
    try Data("third-log\n".utf8).write(to: hashFolder.logURL(device: "third"))
    let otherMac = try BookOpener.prepare(pdfURL: pdf, sandboxed: true, ubiquityContainer: nil, applicationSupport: support, device: "other-mac")
    #expect(otherMac.bookID == a)
    #expect(try String(contentsOf: otherMac.folder.logURL(device: "other-mac"), encoding: .utf8) == "other-mac-log\n")
    #expect(!FileManager.default.fileExists(atPath: otherMac.folder.logURL(device: "third").path))
    #expect(try String(contentsOf: otherMac.folder.logURL(device: "mac"), encoding: .utf8) == "{}\n")
}

@Test func differentPageCountDoesNotInheritTheKnownBook() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let support = root.appendingPathComponent("Support")
    let pdf = root.appendingPathComponent("a.pdf")
    try makePDF(at: pdf, pages: 3)
    let a = try #require(try BookOpener.prepare(pdfURL: pdf, sandboxed: true, ubiquityContainer: nil, applicationSupport: support, device: "mac").bookID)
    try putLog(a, support: support)
    try makePDF(at: pdf, pages: 5)
    let hash = try BookIdentity.contentHash(of: pdf)
    let opened = try BookOpener.prepare(pdfURL: pdf, sandboxed: true, ubiquityContainer: nil, applicationSupport: support, knownBookID: a, device: "mac")
    #expect(opened.bookID == hash)
}

@Test func hashFolderWithDataWinsOverKnownID() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let support = root.appendingPathComponent("Support")
    let pdf = root.appendingPathComponent("a.pdf")
    try makePDF(at: pdf, pages: 3)
    let a = try #require(try BookOpener.prepare(pdfURL: pdf, sandboxed: true, ubiquityContainer: nil, applicationSupport: support, device: "mac").bookID)
    try putLog(a, support: support)
    try annotate(pdf)
    let hash = try BookIdentity.contentHash(of: pdf)
    try putLog(hash, support: support)
    let opened = try BookOpener.prepare(pdfURL: pdf, sandboxed: true, ubiquityContainer: nil, applicationSupport: support, knownBookID: a, device: "mac")
    #expect(opened.bookID == hash)
}

@Test func aliasToAnEmptyFolderIsIgnored() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let support = root.appendingPathComponent("Support")
    let pdf = root.appendingPathComponent("a.pdf")
    try makePDF(at: pdf, pages: 3)
    let hash = try BookIdentity.contentHash(of: pdf)
    let aliases = support.appendingPathComponent("Aliases", isDirectory: true)
    try FileManager.default.createDirectory(at: aliases, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: ["id": "missing"]).write(to: aliases.appendingPathComponent("\(hash).json"))
    let opened = try BookOpener.prepare(pdfURL: pdf, sandboxed: true, ubiquityContainer: nil, applicationSupport: support, device: "mac")
    #expect(opened.bookID == hash)
}

private func writeAlias(_ hash: String, to target: String, support: URL) throws {
    let aliases = support.appendingPathComponent("Aliases", isDirectory: true)
    try FileManager.default.createDirectory(at: aliases, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: ["id": target]).write(to: aliases.appendingPathComponent("\(hash).json"))
}

@Test func aliasWinsOverAHashFolderThatHoldsOnlyBookJSON() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let support = root.appendingPathComponent("Support")
    let pdf = root.appendingPathComponent("a.pdf")
    try makePDF(at: pdf, pages: 3)
    let hash = try BookIdentity.contentHash(of: pdf)
    try putLog("b-book", support: support)
    try writeAlias(hash, to: "b-book", support: support)
    let hashFolder = BookDataLocator.containerPlace(bookID: hash, ubiquityContainer: nil, applicationSupport: support).root
    try FileManager.default.createDirectory(at: hashFolder, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: hashFolder.appendingPathComponent("book.json"))
    let opened = try BookOpener.prepare(pdfURL: pdf, sandboxed: true, ubiquityContainer: nil, applicationSupport: support, device: "mac")
    #expect(opened.bookID == "b-book")
}

@Test func aliasMergesOnlyThisDevicesLogIntoTheTargetOnce() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let support = root.appendingPathComponent("Support")
    let pdf = root.appendingPathComponent("a.pdf")
    try makePDF(at: pdf, pages: 3)
    let hash = try BookIdentity.contentHash(of: pdf)
    try putLog("b-book", support: support)
    try writeAlias(hash, to: "b-book", support: support)
    let hashFolder = SyncFolder(root: BookDataLocator.containerPlace(bookID: hash, ubiquityContainer: nil, applicationSupport: support).root)
    try hashFolder.prepare()
    try hashFolder.append([Data("{\"extra\":1}".utf8)], device: "mac")
    for _ in 0..<2 {
        let opened = try BookOpener.prepare(pdfURL: pdf, sandboxed: true, ubiquityContainer: nil, applicationSupport: support, device: "mac")
        #expect(opened.bookID == "b-book")
    }
    let target = SyncFolder(root: BookDataLocator.containerPlace(bookID: "b-book", ubiquityContainer: nil, applicationSupport: support).root)
    let text = try String(contentsOf: target.logURL(device: "mac"), encoding: .utf8)
    #expect(text.components(separatedBy: "{\"extra\":1}").count == 2)
}

@Test func aliasDoesNotAppendAnotherDevicesLogIntoTheTarget() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let support = root.appendingPathComponent("Support")
    let pdf = root.appendingPathComponent("a.pdf")
    try makePDF(at: pdf, pages: 3)
    let hash = try BookIdentity.contentHash(of: pdf)
    try putLog("b-book", support: support)
    try writeAlias(hash, to: "b-book", support: support)
    let hashFolder = SyncFolder(root: BookDataLocator.containerPlace(bookID: hash, ubiquityContainer: nil, applicationSupport: support).root)
    try hashFolder.prepare()
    try hashFolder.append([Data("{\"extra\":1}".utf8)], device: "mac")
    let target = SyncFolder(root: BookDataLocator.containerPlace(bookID: "b-book", ubiquityContainer: nil, applicationSupport: support).root)
    let before = try Data(contentsOf: target.logURL(device: "mac"))
    let opened = try BookOpener.prepare(pdfURL: pdf, sandboxed: true, ubiquityContainer: nil, applicationSupport: support, device: "other")
    #expect(opened.bookID == "b-book")
    #expect(try Data(contentsOf: target.logURL(device: "mac")) == before)
    #expect(!FileManager.default.fileExists(atPath: target.logURL(device: "other").path))
}
