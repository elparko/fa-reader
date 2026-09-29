import Foundation

public final class Store {
    public static let guardPages = 20

    public let db: Database
    public let folder: SyncFolder
    public let device: String
    public let deviceName: String
    public var clock: () -> Double = { Date().timeIntervalSince1970 }
    public var sessionGap: Double = 30 * 60
    public private(set) var revision = 0

    private var editSession: Session?
    private var lastEditTs: Double = 0
    private var maxApplied = OrderKey(ts: 0, device: "", seq: 0)
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return e
    }()
    private let decoder = JSONDecoder()

    public convenience init(pdfURL: URL, device: String, deviceName: String) throws {
        try self.init(folder: SyncFolder(pdfURL: pdfURL), device: device, deviceName: deviceName)
    }

    public init(folder: SyncFolder, device: String, deviceName: String) throws {
        try folder.prepare()
        self.folder = folder
        self.device = device
        self.deviceName = deviceName
        db = try Database(path: folder.databaseURL.path)
        try Store.migrate(db)
        if let raw = try db.scalar("SELECT value FROM meta WHERE key='max_applied'") as? String,
           let key = try? decoder.decode(OrderKey.self, from: Data(raw.utf8)) {
            maxApplied = key
        }
        try sync()
    }

    static func migrate(_ db: Database) throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE IF NOT EXISTS sessions(
            id TEXT PRIMARY KEY, device TEXT NOT NULL, device_name TEXT NOT NULL, started REAL NOT NULL,
            kind TEXT NOT NULL, label TEXT NOT NULL, undoes TEXT);
        CREATE TABLE IF NOT EXISTS ops(
            id TEXT PRIMARY KEY, device TEXT NOT NULL, seq INTEGER NOT NULL, ts REAL NOT NULL,
            session TEXT NOT NULL, kind TEXT NOT NULL, highlight TEXT NOT NULL, page INTEGER NOT NULL, body TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS ops_order ON ops(ts, device, seq);
        CREATE INDEX IF NOT EXISTS ops_session ON ops(session);
        CREATE INDEX IF NOT EXISTS ops_highlight ON ops(highlight);
        CREATE INDEX IF NOT EXISTS ops_device ON ops(device, seq);
        CREATE TABLE IF NOT EXISTS highlights(
            rid INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE, page INTEGER NOT NULL, rects TEXT NOT NULL,
            text TEXT NOT NULL, color INTEGER NOT NULL, note TEXT NOT NULL, created REAL NOT NULL, source TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS highlights_page ON highlights(page);
        CREATE TABLE IF NOT EXISTS tags(hid TEXT NOT NULL, tag TEXT NOT NULL, PRIMARY KEY(hid, tag));
        CREATE INDEX IF NOT EXISTS tags_tag ON tags(tag);
        CREATE VIRTUAL TABLE IF NOT EXISTS hl_fts USING fts5(
            text, note, tags, tokenize='unicode61 remove_diacritics 2', prefix='2 3');
        CREATE TABLE IF NOT EXISTS book_pages(page INTEGER PRIMARY KEY, printed TEXT, text TEXT NOT NULL);
        CREATE VIRTUAL TABLE IF NOT EXISTS book_fts USING fts5(
            text, tokenize='unicode61 remove_diacritics 2', prefix='2 3');
        CREATE TABLE IF NOT EXISTS sync_offsets(file TEXT PRIMARY KEY, offset INTEGER NOT NULL);
        """)
    }

    // MARK: Reading state

    public func highlights(page: Int? = nil) throws -> [Highlight] {
        let rows = page == nil
            ? try db.query("SELECT * FROM highlights ORDER BY page, created")
            : try db.query("SELECT * FROM highlights WHERE page=? ORDER BY created", page)
        return rows.map(Store.highlight(from:))
    }

    public func highlight(id: String) throws -> Highlight? {
        try db.query("SELECT * FROM highlights WHERE id=?", id).first.map(Store.highlight(from:))
    }

    public func allTags() throws -> [String] {
        try db.query("SELECT DISTINCT tag FROM tags ORDER BY tag").map { $0.string("tag") }
    }

    public func importedHighlightIDs() throws -> Set<String> {
        Set(try db.query("SELECT DISTINCT highlight FROM ops WHERE highlight LIKE 'pv-%'").map { $0.string("highlight") })
    }

    public static func highlight(from row: Row) -> Highlight {
        let rects = (try? JSONDecoder().decode([Rect].self, from: Data(row.string("rects").utf8))) ?? []
        var h = Highlight(id: row.string("id"), page: row.int("page"), rects: rects, text: row.string("text"),
                          color: .yellow, note: row.string("note"), created: row.double("created"),
                          source: row.string("source"))
        h.color = row.int("color")
        return h
    }

    // MARK: Editing

    public func add(_ highlights: [Highlight], confirmed: Bool = false) throws {
        try commit(Plan(kind: .edit, label: "Edit", ops: highlights.map(PendingOp.add)), confirmed: confirmed)
    }

    public func setColor(_ ids: [String], _ color: HighlightColor, confirmed: Bool = false) throws {
        let ops = try ids.compactMap { try highlight(id: $0) }
            .filter { $0.color != color.rawValue }
            .map { PendingOp.color($0, to: color.rawValue) }
        try commit(Plan(kind: .edit, label: "Edit", ops: ops), confirmed: confirmed)
    }

    public func setNote(_ id: String, _ note: String) throws {
        guard let h = try highlight(id: id), h.note != note else { return }
        try commit(Plan(kind: .edit, label: "Edit", ops: [.note(h, to: note)]))
    }

    public func delete(_ ids: [String], confirmed: Bool = false) throws {
        let ops = try ids.compactMap { try highlight(id: $0) }.map(PendingOp.delete)
        try commit(Plan(kind: .edit, label: "Edit", ops: ops), confirmed: confirmed)
    }

    @discardableResult
    public func commit(_ plan: Plan, confirmed: Bool = false) throws -> Session? {
        guard !plan.ops.isEmpty else { return nil }
        let pageCount = plan.pages.count
        if pageCount > Store.guardPages, !confirmed { throw GuardError.needsConfirmation(pages: pageCount) }

        let now = max(clock(), maxApplied.ts + 0.001)
        var lines: [Data] = []
        let session: Session
        if plan.kind == .edit, let s = editSession, now - lastEditTs < sessionGap {
            session = s
        } else {
            session = Session(id: Highlight.newID(), device: device, deviceName: deviceName, started: now,
                              kind: plan.kind, label: plan.label, undoes: plan.undoes)
            lines.append(try encoder.encode(LogLine.session(session)))
        }

        var seq = (try db.scalar("SELECT MAX(seq) FROM ops WHERE device=?", device) as? Int64).map(Int.init) ?? 0
        var ops: [Op] = []
        for (i, p) in plan.ops.enumerated() {
            seq += 1
            ops.append(Op(id: "\(device):\(seq)", device: device, seq: seq, ts: now + Double(i) * 1e-6,
                          session: session.id, kind: p.kind, highlight: p.highlight, page: p.page,
                          snapshot: p.snapshot, oldColor: p.oldColor, newColor: p.newColor,
                          oldNote: p.oldNote, newNote: p.newNote))
        }
        lines += try ops.map { try encoder.encode(LogLine.op($0)) }

        try folder.append(lines, device: device)
        try db.transaction {
            try insert(session)
            for op in ops { _ = try insert(op) }
            try applyInOrder(ops)
        }

        if plan.kind == .edit {
            editSession = session
            lastEditTs = now
        } else {
            editSession = nil
        }
        return session
    }

    // MARK: History and undo

    public func sessions() throws -> [SessionSummary] {
        let rows = try db.query("""
            SELECT s.id, s.device_name, s.kind, s.label, s.undoes, MIN(o.ts) AS start, MAX(o.ts) AS end,
                   COUNT(o.id) AS n, GROUP_CONCAT(DISTINCT o.page) AS pages
            FROM sessions s JOIN ops o ON o.session = s.id
            GROUP BY s.id ORDER BY end DESC
            """)
        var undoneBy: [String: [String]] = [:]
        for r in rows { if let u = r.optionalString("undoes") { undoneBy[u, default: []].append(r.string("id")) } }
        return rows.map { r in
            let pages = r.string("pages").split(separator: ",").compactMap { Int($0) }.sorted()
            return SessionSummary(id: r.string("id"), deviceName: r.string("device_name"),
                                  kind: SessionKind(rawValue: r.string("kind")) ?? .edit, label: r.string("label"),
                                  started: r.double("start"), ended: r.double("end"), opCount: r.int("n"),
                                  pages: pages, undoes: r.optionalString("undoes"),
                                  undoneBy: undoneBy[r.string("id")] ?? [])
        }
    }

    public func ops(session: String) throws -> [Op] {
        try db.query("SELECT body FROM ops WHERE session=? ORDER BY ts, device, seq", session)
            .compactMap { try? decoder.decode(Op.self, from: Data($0.string("body").utf8)) }
    }

    public func undoPlan(session id: String) throws -> Plan {
        let sessionOps = try ops(session: id)
        let label = (try db.scalar("SELECT label FROM sessions WHERE id=?", id) as? String) ?? "session"
        var state: [String: Highlight?] = [:]
        func current(_ hid: String) throws -> Highlight? {
            if let cached = state[hid] { return cached }
            let h = try highlight(id: hid)
            state[hid] = .some(h)
            return h
        }
        var out: [PendingOp] = []
        var skipped = 0
        for op in sessionOps.reversed() {
            let cur = try current(op.highlight)
            switch op.kind {
            case .add:
                let touchedLater = (try db.scalar("""
                    SELECT COUNT(*) FROM ops WHERE highlight=? AND session<>? AND (ts>? OR (ts=? AND (device>? OR (device=? AND seq>?))))
                    """, op.highlight, id, op.ts, op.ts, op.device, op.device, op.seq) as? Int64) ?? 0
                if let cur, touchedLater == 0 {
                    out.append(.delete(cur))
                    state[op.highlight] = .some(nil)
                } else {
                    skipped += 1
                }
            case .delete:
                if cur == nil, let snap = op.snapshot {
                    out.append(.add(snap))
                    state[op.highlight] = .some(snap)
                } else {
                    skipped += 1
                }
            case .color:
                if var cur, cur.color == op.newColor, let old = op.oldColor {
                    out.append(.color(cur, to: old))
                    cur.color = old
                    state[op.highlight] = .some(cur)
                } else {
                    skipped += 1
                }
            case .note:
                if var cur, cur.note == op.newNote, let old = op.oldNote {
                    out.append(.note(cur, to: old))
                    cur.note = old
                    state[op.highlight] = .some(cur)
                } else {
                    skipped += 1
                }
            }
        }
        return Plan(kind: .undo, label: "Undo \(label)", undoes: id, ops: out, skipped: skipped)
    }

    // MARK: Sync

    @discardableResult
    public func sync() throws -> Int {
        var newOps: [Op] = []
        try db.transaction {
            for file in folder.logFiles() {
                let name = file.lastPathComponent
                let offset = (try db.scalar("SELECT offset FROM sync_offsets WHERE file=?", name) as? Int64).map(Int.init) ?? 0
                guard let (lines, end) = folder.readLines(file, from: offset), end != offset || !lines.isEmpty else { continue }
                for line in lines {
                    guard let entry = try? decoder.decode(LogLine.self, from: line) else { continue }
                    switch entry {
                    case .session(let s): try insert(s)
                    case .op(let o): if try insert(o) { newOps.append(o) }
                    }
                }
                try db.run("INSERT OR REPLACE INTO sync_offsets(file, offset) VALUES(?, ?)", name, end)
            }
            try applyInOrder(newOps)
        }
        return newOps.count
    }

    public func rebuild() throws {
        try db.transaction {
            try db.exec("DELETE FROM highlights; DELETE FROM tags; DELETE FROM hl_fts;")
            let ops = try db.query("SELECT body FROM ops ORDER BY ts, device, seq")
                .compactMap { try? decoder.decode(Op.self, from: Data($0.string("body").utf8)) }
            for op in ops { try apply(op) }
            maxApplied = ops.last.map(OrderKey.init) ?? OrderKey(ts: 0, device: "", seq: 0)
            try saveMaxApplied()
        }
        revision += 1
    }

    // MARK: Internals

    private func insert(_ s: Session) throws {
        try db.run("INSERT OR IGNORE INTO sessions(id, device, device_name, started, kind, label, undoes) VALUES(?,?,?,?,?,?,?)",
                   s.id, s.device, s.deviceName, s.started, s.kind.rawValue, s.label, s.undoes)
    }

    private func insert(_ op: Op) throws -> Bool {
        let body = String(decoding: try encoder.encode(op), as: UTF8.self)
        try db.run("INSERT OR IGNORE INTO ops(id, device, seq, ts, session, kind, highlight, page, body) VALUES(?,?,?,?,?,?,?,?,?)",
                   op.id, op.device, op.seq, op.ts, op.session, op.kind.rawValue, op.highlight, op.page, body)
        return db.changes > 0
    }

    private func applyInOrder(_ ops: [Op]) throws {
        guard !ops.isEmpty else { return }
        let sorted = ops.sorted { OrderKey($0) < OrderKey($1) }
        if OrderKey(sorted[0]) < maxApplied {
            try rebuild()
            return
        }
        for op in sorted { try apply(op) }
        maxApplied = OrderKey(sorted.last!)
        try saveMaxApplied()
        revision += 1
    }

    private func saveMaxApplied() throws {
        let raw = String(decoding: try encoder.encode(maxApplied), as: UTF8.self)
        try db.run("INSERT OR REPLACE INTO meta(key, value) VALUES('max_applied', ?)", raw)
    }

    private func apply(_ op: Op) throws {
        switch op.kind {
        case .add:
            if let h = op.snapshot { try upsert(h) }
        case .delete:
            if let rid = try rid(op.highlight) {
                try db.run("DELETE FROM highlights WHERE rid=?", rid)
                try db.run("DELETE FROM hl_fts WHERE rowid=?", rid)
                try db.run("DELETE FROM tags WHERE hid=?", op.highlight)
            }
        case .color:
            if let c = op.newColor { try db.run("UPDATE highlights SET color=? WHERE id=?", c, op.highlight) }
        case .note:
            if var h = try highlight(id: op.highlight), let n = op.newNote {
                h.note = n
                try upsert(h)
            }
        }
    }

    private func rid(_ id: String) throws -> Int? {
        (try db.scalar("SELECT rid FROM highlights WHERE id=?", id) as? Int64).map(Int.init)
    }

    private func upsert(_ h: Highlight) throws {
        let rects = String(decoding: try encoder.encode(h.rects), as: UTF8.self)
        let rowID: Int
        if let existing = try rid(h.id) {
            try db.run("UPDATE highlights SET page=?, rects=?, text=?, color=?, note=?, created=?, source=? WHERE rid=?",
                       h.page, rects, h.text, h.color, h.note, h.created, h.source, existing)
            try db.run("DELETE FROM hl_fts WHERE rowid=?", existing)
            rowID = existing
        } else {
            try db.run("INSERT INTO highlights(id, page, rects, text, color, note, created, source) VALUES(?,?,?,?,?,?,?,?)",
                       h.id, h.page, rects, h.text, h.color, h.note, h.created, h.source)
            rowID = db.lastInsertRowID
        }
        let tags = h.tags
        try db.run("INSERT INTO hl_fts(rowid, text, note, tags) VALUES(?,?,?,?)", rowID, h.text, h.note, tags.joined(separator: " "))
        try db.run("DELETE FROM tags WHERE hid=?", h.id)
        for t in tags { try db.run("INSERT OR IGNORE INTO tags(hid, tag) VALUES(?,?)", h.id, t) }
    }
}

struct OrderKey: Codable, Comparable {
    var ts: Double
    var device: String
    var seq: Int

    init(ts: Double, device: String, seq: Int) { self.ts = ts; self.device = device; self.seq = seq }
    init(_ op: Op) { self.init(ts: op.ts, device: op.device, seq: op.seq) }

    static func < (a: OrderKey, b: OrderKey) -> Bool {
        (a.ts, a.device, a.seq) < (b.ts, b.device, b.seq)
    }
}
