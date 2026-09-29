import Foundation

public enum ResultKind: String {
    case book, highlight, note
}

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

    private let db: Database

    public init(databasePath: String) throws {
        db = try Database(path: databasePath)
    }

    public init(database: Database) {
        db = database
    }

    public static func ftsQuery(_ text: String) -> String? {
        var tokens: [String] = []
        var current = ""
        for ch in text {
            if ch.isLetter || ch.isNumber {
                current.append(ch)
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current) }
        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    public func search(_ text: String, filter: SearchFilter = SearchFilter(), limit: Int = 60) throws -> [SearchResult] {
        guard let query = Searcher.ftsQuery(text) else {
            return filter.isEmpty ? [] : try listHighlights(filter: filter, limit: limit)
        }
        let anyTerm = query.split(separator: " ").joined(separator: " OR ")
        let noteIDs = Set(try highlightRows(match: "{note tags} : (\(anyTerm))", filter: filter, limit: -1).map(\.id))
        let all = try highlightRows(match: query, filter: filter, limit: -1)
        let notes = all.filter { noteIDs.contains($0.id) }.prefix(limit)
        var results = notes.map { result($0, kind: .note) }
        results += all.filter { !noteIDs.contains($0.id) }.prefix(limit).map { result($0, kind: .highlight) }
        if filter.color == nil, filter.tag == nil {
            results += try bookRows(match: query, pages: filter.pages, limit: limit)
        }
        return results
    }

    private struct HighlightRow {
        var id: String
        var page: Int
        var color: Int
        var snippet: String
    }

    private func result(_ row: HighlightRow, kind: ResultKind) -> SearchResult {
        SearchResult(id: "\(kind.rawValue):\(row.id)", kind: kind, page: row.page, highlightID: row.id,
                     color: HighlightColor(rawValue: row.color), snippet: row.snippet)
    }

    private func filterClause(_ filter: SearchFilter) -> (sql: String, args: [Any?]) {
        var sql = ""
        var args: [Any?] = []
        if let color = filter.color {
            sql += " AND h.color = ?"
            args.append(color.rawValue)
        }
        if let pages = filter.pages {
            sql += " AND h.page BETWEEN ? AND ?"
            args += [pages.lowerBound, pages.upperBound]
        }
        if let tag = filter.tag {
            sql += " AND EXISTS (SELECT 1 FROM tags t WHERE t.hid = h.id AND t.tag = ?)"
            args.append(tag.lowercased())
        }
        return (sql, args)
    }

    private func highlightRows(match: String, filter: SearchFilter, limit: Int) throws -> [HighlightRow] {
        let clause = filterClause(filter)
        let args: [Any?] = [Searcher.matchStart, Searcher.matchEnd, match] + clause.args + [limit]
        let rows = try db.query("""
            SELECT h.id, h.page, h.color, snippet(hl_fts, -1, ?, ?, '…', 14) AS snip
            FROM hl_fts JOIN highlights h ON h.rid = hl_fts.rowid
            WHERE hl_fts MATCH ?\(clause.sql)
            ORDER BY hl_fts.rank LIMIT ?
            """, arguments: args)
        return rows.map { HighlightRow(id: $0.string("id"), page: $0.int("page"), color: $0.int("color"), snippet: $0.string("snip")) }
    }

    private func listHighlights(filter: SearchFilter, limit: Int) throws -> [SearchResult] {
        let clause = filterClause(filter)
        let rows = try db.query("""
            SELECT h.id, h.page, h.color, h.text, h.note FROM highlights h
            WHERE 1=1\(clause.sql) ORDER BY h.page, h.created LIMIT ?
            """, arguments: clause.args + [limit])
        return rows.map { row in
            let note = row.string("note")
            let kind: ResultKind = note.isEmpty ? .highlight : .note
            return SearchResult(id: "\(kind.rawValue):\(row.string("id"))", kind: kind, page: row.int("page"),
                                highlightID: row.string("id"), color: HighlightColor(rawValue: row.int("color")),
                                snippet: note.isEmpty ? row.string("text") : note)
        }
    }

    private func bookRows(match: String, pages: ClosedRange<Int>?, limit: Int) throws -> [SearchResult] {
        var sql = "SELECT rowid, snippet(book_fts, 0, ?, ?, '…', 12) AS snip FROM book_fts WHERE book_fts MATCH ?"
        var args: [Any?] = [Searcher.matchStart, Searcher.matchEnd, match]
        if let pages {
            sql += " AND rowid BETWEEN ? AND ?"
            args += [pages.lowerBound, pages.upperBound]
        }
        sql += " ORDER BY rank LIMIT ?"
        args.append(limit)
        return try db.query(sql, arguments: args).map {
            SearchResult(id: "book:\($0.int("rowid"))", kind: .book, page: $0.int("rowid"), highlightID: nil,
                         color: nil, snippet: $0.string("snip"))
        }
    }
}
