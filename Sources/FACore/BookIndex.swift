import Foundation
import PDFKit

public enum BookIndex {
    static let version = "2"

    public static func isIndexed(db: Database, pageCount: Int) throws -> Bool {
        let rows = (try db.scalar("SELECT COUNT(*) FROM book_pages") as? Int64).map(Int.init) ?? 0
        let stored = try db.scalar("SELECT value FROM meta WHERE key='book_index_version'") as? String
        return rows == pageCount && stored == version
    }

    public static func index(document: PDFDocument, into db: Database, progress: ((Int, Int) -> Void)? = nil) throws {
        let count = document.pageCount
        var raw: [String] = []
        raw.reserveCapacity(count)
        for i in 0..<count {
            raw.append(document.page(at: i)?.string ?? "")
            progress?(i + 1, count)
        }
        let texts = clean(raw)
        let printed = printedLabels(texts)
        try db.transaction {
            try db.exec("DELETE FROM book_pages; DELETE FROM book_fts;")
            for (i, text) in texts.enumerated() {
                try db.run("INSERT INTO book_pages(page, printed, text) VALUES(?,?,?)", i, printed[i], text)
                try db.run("INSERT INTO book_fts(rowid, text) VALUES(?,?)", i, text)
            }
            try db.run("INSERT OR REPLACE INTO meta(key, value) VALUES('book_index_version', ?)", version)
        }
    }

    public static func printedPage(db: Database, page: Int) throws -> String? {
        try db.scalar("SELECT printed FROM book_pages WHERE page=?", page) as? String
    }

    public static func pdfPage(forPrinted printed: String, db: Database) throws -> Int? {
        (try db.scalar("SELECT page FROM book_pages WHERE printed=? ORDER BY page LIMIT 1", printed) as? Int64).map(Int.init)
    }

    static func clean(_ pageTexts: [String]) -> [String] {
        var counts: [String: Int] = [:]
        for text in pageTexts {
            if let first = firstLine(text) { counts[first, default: 0] += 1 }
        }
        let repeated = Set(counts.filter { $0.value * 2 > pageTexts.count }.keys)
        guard !repeated.isEmpty else { return pageTexts }
        return pageTexts.map { text in
            text.split(whereSeparator: \.isNewline)
                .filter { !repeated.contains($0.trimmingCharacters(in: .whitespaces)) }
                .joined(separator: "\n")
        }
    }

    static func printedLabel(_ text: String) -> String? {
        var lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let first = lines.first, first.lowercased().contains("medicalstudyzone") { lines.removeFirst() }
        guard let header = lines.first else { return nil }
        func isNumber(_ s: Substring) -> Bool { (1...4).contains(s.count) && s.allSatisfy { $0.isASCII && $0.isNumber } }
        let words = header.split(separator: " ")
        if let first = words.first, isNumber(first) { return String(first) }
        if header.range(of: "S ?E ?C ?T ?I ?O ?N", options: .regularExpression) != nil, let last = words.last, isNumber(last) {
            return String(last)
        }
        return nil
    }

    static func printedLabels(_ texts: [String]) -> [String?] {
        var labels = texts.map(printedLabel)
        var offsets: [Int: Int] = [:]
        for (i, label) in labels.enumerated() {
            if let n = label.flatMap({ Int($0) }) { offsets[i - n, default: 0] += 1 }
        }
        guard let (offset, votes) = offsets.max(by: { $0.value < $1.value }), votes >= 10 else { return labels }
        let agreeing = labels.indices.filter { i in labels[i].flatMap { Int($0) }.map { i - $0 == offset } ?? false }
        guard let first = agreeing.first, let last = agreeing.last else { return labels }
        for i in labels.indices {
            if (first...last).contains(i), i - offset > 0 {
                labels[i] = String(i - offset)
            } else if let n = labels[i].flatMap({ Int($0) }), i - n != offset {
                labels[i] = nil
            }
        }
        return labels
    }

    private static func firstLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }
}
