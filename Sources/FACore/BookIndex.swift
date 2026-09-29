import Foundation
import PDFKit

public enum BookIndex {
    public static func isIndexed(db: Database, pageCount: Int) throws -> Bool { false }
    public static func index(document: PDFDocument, into db: Database, progress: ((Int, Int) -> Void)? = nil) throws {}
    public static func printedPage(db: Database, page: Int) throws -> String? { nil }
    public static func pdfPage(forPrinted printed: String, db: Database) throws -> Int? { nil }
}
