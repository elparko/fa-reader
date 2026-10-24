import Foundation
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
    let opened = try BookOpener.prepare(pdfURL: pdf, sandboxed: true, ubiquityContainer: nil, applicationSupport: support)
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

    try Data("changed".utf8).write(to: opened.folder.logURL(device: "other"))
    let again = try BookOpener.prepare(pdfURL: pdf, sandboxed: true, ubiquityContainer: nil, applicationSupport: support)
    #expect(again.migration.destinationHadLogs)
    #expect(again.migration.copiedLogs.isEmpty)
    #expect(try String(contentsOf: again.folder.logURL(device: "other"), encoding: .utf8) == "changed")

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
    let opened = try BookOpener.prepare(pdfURL: pdf, sandboxed: true, ubiquityContainer: ubi, applicationSupport: root.appendingPathComponent("Support"))
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
    let first = try BookOpener.prepare(pdfURL: pdf, sandboxed: true, ubiquityContainer: nil, applicationSupport: support)
    try Data("local-log\n".utf8).write(to: first.folder.logURL(device: "mac"))
    try FileManager.default.createDirectory(at: first.folder.markdownURL, withIntermediateDirectories: true)
    try Data("note".utf8).write(to: first.folder.markdownURL.appendingPathComponent("01.md"))

    let ubi = root.appendingPathComponent("Ubiquity", isDirectory: true)
    let second = try BookOpener.prepare(pdfURL: pdf, sandboxed: true, ubiquityContainer: ubi, applicationSupport: support)
    #expect(second.migration.copiedLogs == ["mac.jsonl"])
    #expect(second.migration.copiedMarkdown == ["01.md"])
    #expect(try String(contentsOf: second.folder.logURL(device: "mac"), encoding: .utf8) == "local-log\n")
    #expect(second.folder.root.path != first.folder.root.path)
    let third = try BookOpener.prepare(pdfURL: pdf, sandboxed: true, ubiquityContainer: ubi, applicationSupport: support)
    #expect(third.migration.copiedLogs.isEmpty)
    #expect(try String(contentsOf: third.folder.logURL(device: "mac"), encoding: .utf8) == "local-log\n")
}

@Test func unsandboxedOpenDoesNotMoveTheSidecar() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let pdf = root.appendingPathComponent("Guide.pdf")
    try Data("pdf-bytes".utf8).write(to: pdf)
    let opened = try BookOpener.prepare(pdfURL: pdf, sandboxed: false, ubiquityContainer: root.appendingPathComponent("Ubiquity"), applicationSupport: root.appendingPathComponent("Support"))
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
        _ = try BookOpener.prepare(pdfURL: pdf, sandboxed: true, ubiquityContainer: nil, applicationSupport: nil)
        Issue.record("expected a missing Application Support error")
    } catch is BookStoreError {
    } catch {
        Issue.record("unexpected error \(error)")
    }
}

@Test func linkCarriesTheBookIDAndStillCarriesThePath() {
    let pdf = URL(fileURLWithPath: "/Books/Path oma & co.pdf")
    #expect(MarkdownExporter.link(page: 4, highlight: "abc", pdf: pdf, bookID: "abc123")
            == "fa-reader://open?page=5&highlight=abc&book=abc123&pdf=/Books/Path%20oma%20%26%20co.pdf")
    let section = Section(id: 1, title: "Renal", start: 0, end: 9)
    let highlight = Highlight(id: "h1", page: 2, rects: [Rect(x: 0, y: 700, w: 10, h: 10)], text: "RTA", color: .green)
    let text = MarkdownExporter.render(section: section, highlights: [highlight], printedPage: { _ in nil }, pdf: pdf, bookID: "abc123")
    #expect(text.contains("fa-reader://open?page=3&highlight=h1&book=abc123&pdf=/Books/Path%20oma%20%26%20co.pdf"))
}

@Test func readerLinkParsesBookIDAndPercentEncodedPath() throws {
    let url = try #require(URL(string: "fa-reader://open?page=5&highlight=abc&book=bbb&pdf=/Books/Path%20oma%20%26%20co.pdf"))
    let link = try #require(ReaderLinkResolver.parse(url))
    #expect(link == ReaderLink(page: 5, highlight: "abc", bookID: "bbb", pdfPath: "/Books/Path oma & co.pdf"))
    #expect(ReaderLinkResolver.parse(URL(string: "https://example.com")!) == nil)
    #expect(ReaderLinkResolver.parse(URL(string: "fa-reader://open")!) == ReaderLink())
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
