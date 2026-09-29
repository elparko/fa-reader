import Foundation
import PDFKit

public struct RawAnnotation: Equatable {
    public var fingerprint: String
    public var type: String
    public var page: Int
    public var bounds: Rect
    public var rects: [Rect]
    public var text: String
    public var contents: String
    public var color: HighlightColor
    public var date: Date?
    public init(fingerprint: String, type: String, page: Int, bounds: Rect, rects: [Rect], text: String,
                contents: String, color: HighlightColor, date: Date?) {
        self.fingerprint = fingerprint
        self.type = type
        self.page = page
        self.bounds = bounds
        self.rects = rects
        self.text = text
        self.contents = contents
        self.color = color
        self.date = date
    }
}

public struct Burst: Equatable, Identifiable {
    public var id: Int
    public var start: Date
    public var end: Date
    public var count: Int
    public var pages: Int
}

public struct ImportCandidate: Identifiable, Equatable {
    public var id: String
    public var raw: RawAnnotation
    public var burst: Int?
    public var alreadyImported: Bool
    public var highlight: Highlight
}

public struct ImportPreview {
    public var candidates: [ImportCandidate]
    public var bursts: [Burst]
    public func selected(includingBursts: Set<Int> = []) -> [ImportCandidate] { [] }
    public func plan(includingBursts: Set<Int> = []) -> Plan { Plan(kind: .import, label: "Import", ops: []) }
}

public enum PreviewImporter {
    public static func scan(_ document: PDFDocument) -> [RawAnnotation] { [] }
    public static func detectBursts(_ annotations: [RawAnnotation], maxGap: TimeInterval = 3, minCount: Int = 15) -> [Burst] { [] }
    public static func preview(annotations: [RawAnnotation], alreadyImported: Set<String>) -> ImportPreview {
        ImportPreview(candidates: [], bursts: [])
    }
    public static func preview(document: PDFDocument, store: Store) throws -> ImportPreview {
        ImportPreview(candidates: [], bursts: [])
    }
}
