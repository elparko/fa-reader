import Foundation

public struct ExportResult: Equatable {
    public var written: [String]
    public var unchanged: [String]
    public var removed: [String]
}

public enum MarkdownExporter {
    public static let marker = "fa-reader-export: 1"
    public static func link(page: Int, highlight: String? = nil) -> String { "" }
    public static func fileName(for section: Section) -> String { "" }
    public static func render(section: Section, highlights: [Highlight], printedPage: (Int) -> String?) -> String { "" }
    public static func export(store: Store, sections: [Section], to directory: URL,
                              printedPage: (Int) -> String? = { _ in nil }) throws -> ExportResult {
        ExportResult(written: [], unchanged: [], removed: [])
    }
}
