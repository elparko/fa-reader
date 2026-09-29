import Foundation

public enum ResultKind: String { case book, highlight, note }

public struct SearchFilter: Equatable {
    public var color: HighlightColor?
    public var pages: ClosedRange<Int>?
    public var tag: String?
    public init(color: HighlightColor? = nil, pages: ClosedRange<Int>? = nil, tag: String? = nil) {
        self.color = color
        self.pages = pages
        self.tag = tag
    }
    public var isEmpty: Bool { color == nil && pages == nil && tag == nil }
}

public struct SearchResult: Identifiable, Equatable {
    public var id: String
    public var kind: ResultKind
    public var page: Int
    public var highlightID: String?
    public var color: HighlightColor?
    public var snippet: String
}

public final class Searcher {
    public static let matchStart = "\u{E000}"
    public static let matchEnd = "\u{E001}"
    public init(databasePath: String) throws {}
    public init(database: Database) {}
    public func search(_ text: String, filter: SearchFilter = SearchFilter(), limit: Int = 60) throws -> [SearchResult] { [] }
    public static func ftsQuery(_ text: String) -> String? { nil }
}
