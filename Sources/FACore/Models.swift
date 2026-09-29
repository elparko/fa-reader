import Foundation

public struct Rect: Codable, Equatable, Hashable {
    public var x, y, w, h: Double
    public init(x: Double, y: Double, w: Double, h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }
}

public enum HighlightColor: Int, CaseIterable, Codable {
    case noteOnly = 0, yellow, green, pink, blue

    public static let highlightColors: [HighlightColor] = [.yellow, .green, .pink, .blue]

    public var name: String {
        switch self {
        case .noteOnly: "note"
        case .yellow: "yellow"
        case .green: "green"
        case .pink: "pink"
        case .blue: "blue"
        }
    }

    public var rgb: (Double, Double, Double) {
        switch self {
        case .noteOnly: (0.6, 0.6, 0.6)
        case .yellow: (0.980, 0.804, 0.353)
        case .green: (0.486, 0.784, 0.408)
        case .pink: (0.984, 0.361, 0.537)
        case .blue: (0.388, 0.639, 0.980)
        }
    }

    public static func nearest(r: Double, g: Double, b: Double) -> HighlightColor {
        highlightColors.min { a, c in
            func d(_ x: HighlightColor) -> Double {
                let (xr, xg, xb) = x.rgb
                return (xr - r) * (xr - r) + (xg - g) * (xg - g) + (xb - b) * (xb - b)
            }
            return d(a) < d(c)
        }!
    }
}

public struct Highlight: Codable, Equatable, Identifiable {
    public var id: String
    public var page: Int
    public var rects: [Rect]
    public var text: String
    public var color: Int
    public var note: String
    public var created: Double
    public var source: String

    public init(id: String = Highlight.newID(), page: Int, rects: [Rect], text: String, color: HighlightColor,
                note: String = "", created: Double = Date().timeIntervalSince1970, source: String = "app") {
        self.id = id
        self.page = page
        self.rects = rects
        self.text = text
        self.color = color.rawValue
        self.note = note
        self.created = created
        self.source = source
    }

    public var highlightColor: HighlightColor { HighlightColor(rawValue: color) ?? .yellow }

    public static func newID() -> String { UUID().uuidString.lowercased() }

    public var tags: [String] { Tags.parse(note) }
}

public enum Tags {
    public static func parse(_ text: String) -> [String] {
        var out: [String] = []
        let scalars = Array(text)
        var i = 0
        while i < scalars.count {
            if scalars[i] == "#", i == 0 || scalars[i - 1].isWhitespace {
                var j = i + 1
                while j < scalars.count, scalars[j].isLetter || scalars[j].isNumber || scalars[j] == "-" || scalars[j] == "_" { j += 1 }
                if j > i + 1 {
                    let tag = String(scalars[(i + 1)..<j]).lowercased()
                    if !out.contains(tag) { out.append(tag) }
                }
                i = j
            } else {
                i += 1
            }
        }
        return out
    }
}

public enum OpKind: String, Codable {
    case add, color, note, delete
}

public struct Op: Codable, Equatable {
    public var id: String
    public var device: String
    public var seq: Int
    public var ts: Double
    public var session: String
    public var kind: OpKind
    public var highlight: String
    public var page: Int
    public var snapshot: Highlight?
    public var oldColor: Int?
    public var newColor: Int?
    public var oldNote: String?
    public var newNote: String?
}

public enum SessionKind: String, Codable {
    case edit, `import`, undo
}

public struct Session: Codable, Equatable {
    public var id: String
    public var device: String
    public var deviceName: String
    public var started: Double
    public var kind: SessionKind
    public var label: String
    public var undoes: String?
}

public struct PendingOp: Equatable {
    public var kind: OpKind
    public var highlight: String
    public var page: Int
    public var snapshot: Highlight?
    public var oldColor: Int?
    public var newColor: Int?
    public var oldNote: String?
    public var newNote: String?

    public static func add(_ h: Highlight) -> PendingOp {
        PendingOp(kind: .add, highlight: h.id, page: h.page, snapshot: h)
    }
    public static func delete(_ h: Highlight) -> PendingOp {
        PendingOp(kind: .delete, highlight: h.id, page: h.page, snapshot: h)
    }
    public static func color(_ h: Highlight, to c: Int) -> PendingOp {
        PendingOp(kind: .color, highlight: h.id, page: h.page, oldColor: h.color, newColor: c)
    }
    public static func note(_ h: Highlight, to n: String) -> PendingOp {
        PendingOp(kind: .note, highlight: h.id, page: h.page, oldNote: h.note, newNote: n)
    }
}

public struct Plan {
    public var kind: SessionKind
    public var label: String
    public var undoes: String?
    public var ops: [PendingOp]
    public var skipped: Int = 0

    public init(kind: SessionKind, label: String, undoes: String? = nil, ops: [PendingOp], skipped: Int = 0) {
        self.kind = kind
        self.label = label
        self.undoes = undoes
        self.ops = ops
        self.skipped = skipped
    }

    public var pages: Set<Int> { Set(ops.map(\.page)) }
}

public enum GuardError: Error, Equatable {
    case needsConfirmation(pages: Int)
}

public struct SessionSummary: Identifiable, Equatable {
    public var id: String
    public var deviceName: String
    public var kind: SessionKind
    public var label: String
    public var started: Double
    public var ended: Double
    public var opCount: Int
    public var pages: [Int]
    public var undoes: String?
    public var undoneBy: [String]
}
