import Foundation

public struct SavedBookmark: Codable, Equatable, Identifiable, Sendable {
    public var path: String
    public var name: String
    public var bookID: String?
    /// Security-scoped bookmark data. App-scoped; resolved with `BookmarkStore`.
    public var data: Data

    public var id: String { path }

    public init(path: String, name: String, bookID: String?, data: Data) {
        self.path = path
        self.name = name
        self.bookID = bookID
        self.data = data
    }

    public static func capturing(_ url: URL, bookID: String?) throws -> SavedBookmark {
        SavedBookmark(path: url.path, name: url.lastPathComponent, bookID: bookID, data: try BookmarkStore.data(for: url))
    }
}

public enum BookmarkStore {
    public static func data(for url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    public static func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
        return (url, stale)
    }
}

public enum BookmarkLibrary {
    public static let recentsKey = "recentBookmarks"
    public static let lastKey = "lastBookBookmark"
    public static let exportKey = "exportFolderBookmark"
    public static let legacyRecentsKey = "recentPDFs"
    public static let legacyLastKey = "lastPDF"
    public static let legacyExportKey = "exportFolder"

    public static func recents(from defaults: UserDefaults) -> [SavedBookmark] {
        guard let data = defaults.data(forKey: recentsKey),
              let saved = try? JSONDecoder().decode([SavedBookmark].self, from: data) else { return [] }
        return saved
    }

    public static func saveRecents(_ bookmarks: [SavedBookmark], to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(bookmarks) { defaults.set(data, forKey: recentsKey) }
    }

    public static func lastBook(from defaults: UserDefaults) -> SavedBookmark? {
        guard let data = defaults.data(forKey: lastKey) else { return nil }
        return try? JSONDecoder().decode(SavedBookmark.self, from: data)
    }

    public static func saveLastBook(_ bookmark: SavedBookmark?, to defaults: UserDefaults) {
        if let bookmark, let data = try? JSONEncoder().encode(bookmark) {
            defaults.set(data, forKey: lastKey)
        } else {
            defaults.removeObject(forKey: lastKey)
        }
    }
}

public struct ReaderLink: Equatable {
    public var page: Int?
    public var highlight: String?
    public var bookID: String?
    public var pdfPath: String?

    public init(page: Int? = nil, highlight: String? = nil, bookID: String? = nil, pdfPath: String? = nil) {
        self.page = page
        self.highlight = highlight
        self.bookID = bookID
        self.pdfPath = pdfPath
    }
}

public enum ReaderLinkResolver {
    public static func parse(_ url: URL) -> ReaderLink? {
        guard let scheme = url.scheme, scheme == "rowlight" || scheme == "fa-reader" else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        return ReaderLink(page: value("page").flatMap(Int.init), highlight: value("highlight"), bookID: value("book"), pdfPath: value("pdf"))
    }

    /// The saved bookmark to open. A book id wins over a path. Nil when the link already names the open book,
    /// or when nothing saved matches (the caller can then try `directPath`).
    public static func bookmark(for link: ReaderLink, in bookmarks: [SavedBookmark], currentBookID: String?, currentPath: String?) -> SavedBookmark? {
        if let id = link.bookID {
            if id == currentBookID { return nil }
            if let match = bookmarks.first(where: { $0.bookID == id }) { return match }
        }
        if let path = link.pdfPath {
            if path == currentPath, link.bookID == nil || link.bookID == currentBookID { return nil }
            if let match = bookmarks.first(where: { $0.path == path }) { return match }
        }
        return nil
    }

    /// A filesystem path to try when no bookmark matched. Nil when the link names the book that is already open.
    public static func directPath(for link: ReaderLink, currentBookID: String?, currentPath: String?) -> String? {
        if let id = link.bookID, id == currentBookID { return nil }
        guard let path = link.pdfPath, path != currentPath else { return nil }
        return path
    }
}
