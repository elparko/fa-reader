import Foundation
import Testing
@testable import FACore

func tempFolder() -> SyncFolder {
    SyncFolder(root: FileManager.default.temporaryDirectory.appendingPathComponent("fa-\(UUID().uuidString)", isDirectory: true))
}

private final class TestClock {
    var now: Double
    init(_ start: Double = 1_700_000_000) { now = start }
    func minutes(_ m: Double) { now += m * 60 }
}

private func makeStore(_ folder: SyncFolder, _ device: String = "mac-a", clock: TestClock = TestClock()) throws -> Store {
    let store = try Store(folder: folder, device: device, deviceName: device.uppercased())
    store.clock = { clock.now }
    return store
}

private func makeHighlight(_ id: String, page: Int = 1, text: String = "text", color: HighlightColor = .yellow,
                           note: String = "") -> Highlight {
    Highlight(id: id, page: page, rects: [Rect(x: 1, y: 2, w: 3, h: 4)], text: text, color: color, note: note, created: 100)
}

private func logObjects(_ folder: SyncFolder, device: String) throws -> [[String: Any]] {
    let raw = try String(contentsOf: folder.logURL(device: device), encoding: .utf8)
    return try raw.split(separator: "\n").map { line in
        try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }
}

private func opCount(_ store: Store) throws -> Int {
    Int(try store.db.scalar("SELECT COUNT(*) FROM ops") as? Int64 ?? 0)
}

// MARK: Round trips

@Test func addAndReadBack() throws {
    let store = try Store(folder: tempFolder(), device: "mac-a", deviceName: "Mac A")
    let h = Highlight(page: 3, rects: [Rect(x: 1, y: 2, w: 3, h: 4)], text: "Graves disease", color: .pink)
    try store.add([h])
    #expect(try store.highlights(page: 3) == [h])
}

@Test func addColorNoteDeleteRoundTrip() throws {
    let clock = TestClock()
    let store = try makeStore(tempFolder(), clock: clock)
    let h = makeHighlight("h1", page: 5, text: "TSH low", color: .yellow)
    try store.add([h])
    #expect(try store.highlight(id: "h1") == h)
    #expect(try store.highlights().count == 1)
    #expect(try store.highlights(page: 4).isEmpty)

    try store.setColor(["h1"], .blue)
    #expect(try store.highlight(id: "h1")?.color == HighlightColor.blue.rawValue)

    try store.setNote("h1", "check T4")
    #expect(try store.highlight(id: "h1")?.note == "check T4")
    #expect(try store.highlight(id: "h1")?.text == "TSH low")

    try store.delete(["h1"])
    #expect(try store.highlight(id: "h1") == nil)
    #expect(try store.highlights().isEmpty)
}

@Test func unchangedColorAndNoteAreNoOps() throws {
    let store = try makeStore(tempFolder())
    try store.add([makeHighlight("h1", color: .green, note: "n")])
    let before = try opCount(store)
    try store.setColor(["h1"], .green)
    try store.setNote("h1", "n")
    try store.setColor(["missing"], .pink)
    try store.delete(["missing"])
    #expect(try opCount(store) == before)
}

@Test func highlightsOrderedByPageThenCreated() throws {
    let store = try makeStore(tempFolder())
    var a = makeHighlight("a", page: 2); a.created = 5
    var b = makeHighlight("b", page: 1); b.created = 9
    var c = makeHighlight("c", page: 1); c.created = 3
    try store.add([a, b, c])
    #expect(try store.highlights().map(\.id) == ["c", "b", "a"])
}

@Test func highlightsWithSamePageAndCreatedOrderByID() throws {
    let store = try makeStore(tempFolder())
    try store.add([makeHighlight("b"), makeHighlight("a"), makeHighlight("c")])
    #expect(try store.highlights().map(\.id) == ["a", "b", "c"])
    #expect(try store.highlights(page: 1).map(\.id) == ["a", "b", "c"])
}

@Test func importedHighlightIDsListsPreviewPrefixedOnly() throws {
    let store = try makeStore(tempFolder())
    try store.add([makeHighlight("pv-1"), makeHighlight("plain")])
    #expect(try store.importedHighlightIDs() == ["pv-1"])
}

// MARK: Tags

@Test func tagsParsedFromNotes() throws {
    let store = try makeStore(tempFolder())
    try store.add([makeHighlight("h1", note: "see #renal and #High-Yield, not a#b")])
    #expect(try store.allTags() == ["high-yield", "renal"])
    let rows = try store.db.query("SELECT tag FROM tags WHERE hid='h1' ORDER BY tag")
    #expect(rows.map { $0.string("tag") } == ["high-yield", "renal"])
}

@Test func tagsUpdateWhenNoteChanges() throws {
    let store = try makeStore(tempFolder())
    try store.add([makeHighlight("h1", note: "#renal")])
    try store.add([makeHighlight("h2", note: "#renal #cards")])
    #expect(try store.allTags() == ["cards", "renal"])
    try store.setNote("h1", "#endo")
    #expect(try store.allTags() == ["cards", "endo", "renal"])
    try store.setNote("h2", "")
    #expect(try store.allTags() == ["endo"])
    let found = try store.db.query("SELECT rowid FROM hl_fts WHERE hl_fts MATCH 'tags:endo'")
    #expect(found.count == 1)
}

@Test func tagsRemovedWhenHighlightDeleted() throws {
    let store = try makeStore(tempFolder())
    try store.add([makeHighlight("h1", note: "#renal")])
    try store.delete(["h1"])
    #expect(try store.allTags().isEmpty)
    #expect(try store.db.scalar("SELECT COUNT(*) FROM hl_fts") as? Int64 == 0)
}

@Test func highlightFullTextSearchIndexFollowsEdits() throws {
    let store = try makeStore(tempFolder())
    try store.add([makeHighlight("h1", text: "Graves disease")])
    #expect(try store.db.query("SELECT rowid FROM hl_fts WHERE hl_fts MATCH 'graves'").count == 1)
    try store.setNote("h1", "thyroid storm")
    #expect(try store.db.query("SELECT rowid FROM hl_fts WHERE hl_fts MATCH 'storm'").count == 1)
    #expect(try store.db.scalar("SELECT COUNT(*) FROM hl_fts") as? Int64 == 1)
}

// MARK: Session grouping

@Test func editsUnderGapShareSessionAndOverGapSplit() throws {
    let clock = TestClock()
    let store = try makeStore(tempFolder(), clock: clock)
    try store.add([makeHighlight("h1")])
    clock.minutes(29)
    try store.add([makeHighlight("h2")])
    clock.minutes(29)
    try store.add([makeHighlight("h3")])
    #expect(try store.sessions().count == 1)
    clock.minutes(31)
    try store.add([makeHighlight("h4")])
    let sessions = try store.sessions()
    #expect(sessions.count == 2)
    #expect(sessions[0].opCount == 1)
    #expect(sessions[1].opCount == 3)
}

@Test func gapIsMeasuredFromLastEditNotSessionStart() throws {
    let clock = TestClock()
    let store = try makeStore(tempFolder(), clock: clock)
    try store.add([makeHighlight("h1")])
    clock.minutes(20)
    try store.setColor(["h1"], .pink)
    clock.minutes(20)
    try store.setNote("h1", "x")
    #expect(try store.sessions().count == 1)
}

@Test func customSessionGapIsUsed() throws {
    let clock = TestClock()
    let store = try makeStore(tempFolder(), clock: clock)
    store.sessionGap = 60
    try store.add([makeHighlight("h1")])
    clock.now += 61
    try store.add([makeHighlight("h2")])
    #expect(try store.sessions().count == 2)
}

@Test func undoIsItsOwnSessionAndEndsEditSession() throws {
    let clock = TestClock()
    let store = try makeStore(tempFolder(), clock: clock)
    try store.add([makeHighlight("h1")])
    let first = try #require(try store.sessions().first)
    clock.minutes(1)
    try store.commit(try store.undoPlan(session: first.id))
    clock.minutes(1)
    try store.add([makeHighlight("h2")])
    let sessions = try store.sessions()
    #expect(sessions.count == 3)
    #expect(sessions.map(\.kind) == [.edit, .undo, .edit])
}

@Test func importIsItsOwnSession() throws {
    let clock = TestClock()
    let store = try makeStore(tempFolder(), clock: clock)
    try store.add([makeHighlight("h0")])
    clock.minutes(1)
    try store.commit(Plan(kind: .import, label: "Import", ops: [.add(makeHighlight("pv-1")), .add(makeHighlight("pv-2"))]))
    clock.minutes(1)
    try store.add([makeHighlight("h1")])
    let sessions = try store.sessions()
    #expect(sessions.map(\.kind) == [.edit, .import, .edit])
    #expect(sessions[1].opCount == 2)
    #expect(sessions[1].label == "Import")
}

@Test func sessionSummaryCountsPagesAndUndoneBy() throws {
    let clock = TestClock()
    let store = try makeStore(tempFolder(), clock: clock)
    try store.add([makeHighlight("h1", page: 3), makeHighlight("h2", page: 3), makeHighlight("h3", page: 7)])
    let original = try #require(try store.sessions().first)
    #expect(original.opCount == 3)
    #expect(original.pages == [3, 7])
    #expect(original.undoneBy.isEmpty)
    #expect(original.undoes == nil)
    #expect(original.deviceName == "MAC-A")
    #expect(original.ended >= original.started)

    clock.minutes(5)
    let undo = try #require(try store.commit(try store.undoPlan(session: original.id)))
    let sessions = try store.sessions()
    #expect(sessions.count == 2)
    #expect(sessions[0].id == undo.id)
    #expect(sessions[0].undoes == original.id)
    #expect(sessions[0].kind == .undo)
    #expect(sessions[1].undoneBy == [undo.id])
}

// MARK: Undo

@Test func undoMiddleSessionKeepsLaterWork() throws {
    let clock = TestClock()
    let store = try makeStore(tempFolder(), clock: clock)
    try store.add([makeHighlight("a", page: 1)])
    clock.minutes(60)
    try store.add([makeHighlight("b", page: 2)])
    clock.minutes(60)
    try store.add([makeHighlight("c", page: 3)])
    try store.setColor(["a"], .green)
    let sessions = try store.sessions()
    #expect(sessions.count == 3)
    let middle = try #require(sessions.first { $0.pages == [2] })
    let plan = try store.undoPlan(session: middle.id)
    #expect(plan.kind == .undo)
    #expect(plan.undoes == middle.id)
    #expect(plan.ops.count == 1)
    clock.minutes(1)
    try store.commit(plan)
    #expect(try store.highlights().map(\.id) == ["a", "c"])
    #expect(try store.highlight(id: "a")?.color == HighlightColor.green.rawValue)
}

@Test func undoColorSkippedWhenLaterSessionRecolored() throws {
    let clock = TestClock()
    let store = try makeStore(tempFolder(), clock: clock)
    try store.add([makeHighlight("a", color: .yellow)])
    clock.minutes(60)
    try store.setColor(["a"], .pink)
    clock.minutes(60)
    try store.setColor(["a"], .blue)
    let sessions = try store.sessions()
    let pinkSession = sessions[1]
    let plan = try store.undoPlan(session: pinkSession.id)
    #expect(plan.ops.isEmpty)
    #expect(plan.skipped == 1)
    #expect(try store.commit(plan) == nil)
    #expect(try store.highlight(id: "a")?.color == HighlightColor.blue.rawValue)
}

@Test func undoColorRevertsWhenValueStillMatches() throws {
    let clock = TestClock()
    let store = try makeStore(tempFolder(), clock: clock)
    try store.add([makeHighlight("a", color: .yellow)])
    clock.minutes(60)
    try store.setColor(["a"], .pink)
    let pinkSession = try #require(try store.sessions().first)
    clock.minutes(1)
    try store.commit(try store.undoPlan(session: pinkSession.id))
    #expect(try store.highlight(id: "a")?.color == HighlightColor.yellow.rawValue)
}

@Test func undoNoteRevertsOnlyWhenValueStillMatches() throws {
    let clock = TestClock()
    let store = try makeStore(tempFolder(), clock: clock)
    try store.add([makeHighlight("a", note: "first")])
    clock.minutes(60)
    try store.setNote("a", "second")
    let secondSession = try #require(try store.sessions().first)
    clock.minutes(60)
    try store.setNote("a", "third")
    let plan = try store.undoPlan(session: secondSession.id)
    #expect(plan.ops.isEmpty)
    #expect(plan.skipped == 1)
    #expect(try store.highlight(id: "a")?.note == "third")

    let thirdSession = try #require(try store.sessions().first)
    clock.minutes(1)
    try store.commit(try store.undoPlan(session: thirdSession.id))
    #expect(try store.highlight(id: "a")?.note == "second")
    #expect(try store.allTags().isEmpty)
}

@Test func undoAddSkippedWhenLaterSessionAddedNote() throws {
    let clock = TestClock()
    let store = try makeStore(tempFolder(), clock: clock)
    try store.add([makeHighlight("a")])
    let addSession = try #require(try store.sessions().first)
    clock.minutes(60)
    try store.setNote("a", "important")
    let plan = try store.undoPlan(session: addSession.id)
    #expect(plan.ops.isEmpty)
    #expect(plan.skipped == 1)
    #expect(try store.highlight(id: "a")?.note == "important")
}

@Test func undoAddWithinSameSessionEditsStillDeletes() throws {
    let clock = TestClock()
    let store = try makeStore(tempFolder(), clock: clock)
    try store.add([makeHighlight("a", color: .yellow)])
    clock.minutes(5)
    try store.setColor(["a"], .pink)
    clock.minutes(5)
    try store.setNote("a", "x")
    let session = try #require(try store.sessions().first)
    #expect(try store.sessions().count == 1)
    clock.minutes(1)
    try store.commit(try store.undoPlan(session: session.id))
    #expect(try store.highlights().isEmpty)
}

@Test func undoDeleteRestoresExactSnapshotIncludingNote() throws {
    let clock = TestClock()
    let store = try makeStore(tempFolder(), clock: clock)
    let original = makeHighlight("a", page: 9, text: "Cushing", color: .green, note: "#endo cortisol")
    try store.add([original])
    clock.minutes(60)
    try store.delete(["a"])
    #expect(try store.highlights().isEmpty)
    let deleteSession = try #require(try store.sessions().first)
    clock.minutes(1)
    try store.commit(try store.undoPlan(session: deleteSession.id))
    #expect(try store.highlight(id: "a") == original)
    #expect(try store.allTags() == ["endo"])
}

@Test func undoDeleteSkippedWhenHighlightAlreadyBack() throws {
    let clock = TestClock()
    let store = try makeStore(tempFolder(), clock: clock)
    try store.add([makeHighlight("a")])
    clock.minutes(60)
    try store.delete(["a"])
    let deleteSession = try #require(try store.sessions().first)
    clock.minutes(60)
    try store.add([makeHighlight("a", note: "re-added")])
    let plan = try store.undoPlan(session: deleteSession.id)
    #expect(plan.ops.isEmpty)
    #expect(plan.skipped == 1)
}

@Test func undoOfUndoRestoresWork() throws {
    let clock = TestClock()
    let store = try makeStore(tempFolder(), clock: clock)
    let a = makeHighlight("a", note: "n")
    try store.add([a, makeHighlight("b", page: 2)])
    let addSession = try #require(try store.sessions().first)
    clock.minutes(1)
    let undo = try #require(try store.commit(try store.undoPlan(session: addSession.id)))
    #expect(try store.highlights().isEmpty)
    clock.minutes(1)
    try store.commit(try store.undoPlan(session: undo.id))
    #expect(try store.highlights().count == 2)
    #expect(try store.highlight(id: "a") == a)
    let sessions = try store.sessions()
    #expect(sessions.count == 3)
    #expect(sessions.last?.undoneBy.count == 1)
}

@Test func undoOfColorChangeCanBeRedone() throws {
    let clock = TestClock()
    let store = try makeStore(tempFolder(), clock: clock)
    try store.add([makeHighlight("a", color: .yellow)])
    clock.minutes(60)
    try store.setColor(["a"], .pink)
    let change = try #require(try store.sessions().first)
    clock.minutes(1)
    let undo = try #require(try store.commit(try store.undoPlan(session: change.id)))
    #expect(try store.highlight(id: "a")?.color == HighlightColor.yellow.rawValue)
    clock.minutes(1)
    try store.commit(try store.undoPlan(session: undo.id))
    #expect(try store.highlight(id: "a")?.color == HighlightColor.pink.rawValue)
}

// MARK: Guard

private func pageHighlights(_ n: Int, prefix: String = "p") -> [Highlight] {
    (0..<n).map { makeHighlight("\(prefix)\($0)", page: $0) }
}

@Test func guardThrowsAt21PagesAndAllows20() throws {
    let store = try makeStore(tempFolder())
    #expect(throws: GuardError.needsConfirmation(pages: 21)) { try store.add(pageHighlights(21)) }
    #expect(try store.highlights().isEmpty)
    #expect(try opCount(store) == 0)
    try store.add(pageHighlights(20))
    #expect(try store.highlights().count == 20)
}

@Test func guardCountsPagesNotOps() throws {
    let store = try makeStore(tempFolder())
    let many = (0..<100).map { makeHighlight("h\($0)", page: $0 % 5) }
    try store.add(many)
    #expect(try store.highlights().count == 100)
}

@Test func guardPassesWhenConfirmed() throws {
    let store = try makeStore(tempFolder())
    try store.add(pageHighlights(21), confirmed: true)
    #expect(try store.highlights().count == 21)
}

@Test func guardAppliesToColorAndDelete() throws {
    let store = try makeStore(tempFolder())
    try store.add(pageHighlights(25), confirmed: true)
    let ids = (0..<25).map { "p\($0)" }
    #expect(throws: GuardError.needsConfirmation(pages: 25)) { try store.setColor(ids, .blue) }
    #expect(try store.highlights().allSatisfy { $0.color == HighlightColor.yellow.rawValue })
    #expect(throws: GuardError.needsConfirmation(pages: 25)) { try store.delete(ids) }
    #expect(try store.highlights().count == 25)
    try store.setColor(ids, .blue, confirmed: true)
    try store.delete(ids, confirmed: true)
    #expect(try store.highlights().isEmpty)
}

@Test func undoPlanOver20PagesNeedsConfirmation() throws {
    let clock = TestClock()
    let store = try makeStore(tempFolder(), clock: clock)
    try store.add(pageHighlights(25), confirmed: true)
    let session = try #require(try store.sessions().first)
    let plan = try store.undoPlan(session: session.id)
    #expect(plan.pages.count == 25)
    clock.minutes(1)
    #expect(throws: GuardError.needsConfirmation(pages: 25)) { try store.commit(plan) }
    #expect(try store.highlights().count == 25)
    try store.commit(plan, confirmed: true)
    #expect(try store.highlights().isEmpty)
}

@Test func emptyPlanCommitsNothing() throws {
    let store = try makeStore(tempFolder())
    #expect(try store.commit(Plan(kind: .edit, label: "Edit", ops: [])) == nil)
    #expect(try store.sessions().isEmpty)
}

// MARK: Persistence

@Test func stateSurvivesReopeningStore() throws {
    let folder = tempFolder()
    let clock = TestClock()
    let first = try makeStore(folder, clock: clock)
    try first.add([makeHighlight("a", note: "#x"), makeHighlight("b", page: 2)])
    clock.minutes(60)
    try first.setColor(["a"], .blue)
    let expected = try first.highlights()
    let expectedSessions = try first.sessions()

    let second = try makeStore(folder, clock: clock)
    #expect(try second.highlights() == expected)
    #expect(try second.sessions() == expectedSessions)
    #expect(try second.allTags() == ["x"])
    #expect(try opCount(second) == 3)
}

@Test func reopenedStoreContinuesEditSessionWithinGap() throws {
    let folder = tempFolder()
    let clock = TestClock()
    let first = try makeStore(folder, clock: clock)
    try first.add([makeHighlight("a")])
    clock.minutes(10)
    let second = try makeStore(folder, clock: clock)
    try second.add([makeHighlight("b", page: 2)])
    #expect(try second.sessions().count == 1)
    clock.minutes(40)
    let third = try makeStore(folder, clock: clock)
    try third.add([makeHighlight("c", page: 3)])
    #expect(try third.sessions().count == 2)
}

@Test func reopenedStoreDoesNotContinueAnUndoSession() throws {
    let folder = tempFolder()
    let clock = TestClock()
    let first = try makeStore(folder, clock: clock)
    try first.add([makeHighlight("a")])
    clock.minutes(1)
    try first.commit(try first.undoPlan(session: try #require(try first.sessions().first).id))
    clock.minutes(1)
    let second = try makeStore(folder, clock: clock)
    try second.add([makeHighlight("b")])
    #expect(try second.sessions().count == 3)
}

@Test func reopenedStoreContinuesSequenceAndOrdering() throws {
    let folder = tempFolder()
    let clock = TestClock()
    let first = try makeStore(folder, clock: clock)
    try first.add([makeHighlight("a")])
    let second = try makeStore(folder, clock: clock)
    clock.minutes(1)
    try second.setColor(["a"], .pink)
    let seqs = try second.db.query("SELECT seq FROM ops WHERE device='mac-a' ORDER BY seq").map { $0.int("seq") }
    #expect(seqs == [1, 2])
    #expect(try second.highlight(id: "a")?.color == HighlightColor.pink.rawValue)
}

@Test func databaseRebuiltFromLogsAfterDeletingSqlite() throws {
    let folder = tempFolder()
    let clock = TestClock()
    let first = try makeStore(folder, clock: clock)
    try first.add([makeHighlight("a", note: "#renal"), makeHighlight("b", page: 2)])
    clock.minutes(60)
    try first.setColor(["a"], .blue)
    clock.minutes(60)
    try first.delete(["b"])
    clock.minutes(1)
    let undoTarget = try #require(try first.sessions().first)
    try first.commit(try first.undoPlan(session: undoTarget.id))
    let expected = try first.highlights()
    let expectedSessions = try first.sessions()
    #expect(expected.count == 2)

    let fm = FileManager.default
    let dir = folder.localURL.path
    for name in try fm.contentsOfDirectory(atPath: dir) where name.hasPrefix("fa.sqlite") {
        try fm.removeItem(atPath: dir + "/" + name)
    }
    #expect(!fm.fileExists(atPath: folder.databaseURL.path))

    let reopened = try makeStore(folder, clock: clock)
    #expect(try reopened.highlights() == expected)
    #expect(try reopened.sessions() == expectedSessions)
    #expect(try reopened.allTags() == ["renal"])
    #expect(try opCount(reopened) == 5)
}

@Test func logHasOneLinePerOpPlusSessionLinesWithTimestamps() throws {
    let folder = tempFolder()
    let clock = TestClock()
    let store = try makeStore(folder, clock: clock)
    try store.add([makeHighlight("a"), makeHighlight("b", page: 2)])
    clock.minutes(1)
    try store.setColor(["a"], .pink)
    clock.minutes(60)
    try store.setNote("b", "x")
    let target = try #require(try store.sessions().last)
    clock.minutes(1)
    try store.commit(try store.undoPlan(session: target.id))

    let lines = try logObjects(folder, device: "mac-a")
    let sessionLines = lines.compactMap { $0["session"] as? [String: Any] }
    let opLines = lines.compactMap { $0["op"] as? [String: Any] }
    #expect(lines.count == sessionLines.count + opLines.count)
    #expect(opLines.count == 6)
    #expect(sessionLines.count == 3)
    let sessionIDs = Set(sessionLines.compactMap { $0["id"] as? String })
    for op in opLines {
        #expect(op["ts"] as? Double != nil)
        let session = try #require(op["session"] as? String)
        #expect(sessionIDs.contains(session))
    }
    let stamps = opLines.compactMap { $0["ts"] as? Double }
    #expect(stamps == stamps.sorted())
    #expect(Set(stamps).count == stamps.count)
    for s in sessionLines { #expect(s["started"] as? Double != nil) }
}

@Test func storeNeverCreatesFilesOutsideItsFolder() throws {
    let folder = tempFolder()
    let store = try makeStore(folder)
    try store.add([makeHighlight("a")])
    let names = try FileManager.default.contentsOfDirectory(atPath: folder.root.path).sorted()
    #expect(names == ["changes", "local.nosync"])
}

@Test func localOpTimestampsNeverGoBackwards() throws {
    let clock = TestClock()
    let store = try makeStore(tempFolder(), clock: clock)
    try store.add([makeHighlight("a")])
    clock.now -= 3600
    try store.setColor(["a"], .pink)
    let ts = try store.db.query("SELECT ts FROM ops ORDER BY seq").map { $0.double("ts") }
    #expect(ts[1] > ts[0])
    #expect(try store.highlight(id: "a")?.color == HighlightColor.pink.rawValue)
}

@Test func revisionIncreasesOnChanges() throws {
    let store = try makeStore(tempFolder())
    let start = store.revision
    try store.add([makeHighlight("a")])
    #expect(store.revision > start)
}

// MARK: Two devices

private func sharingChanges(of shared: SyncFolder) throws -> SyncFolder {
    let own = tempFolder()
    try FileManager.default.createDirectory(at: own.root, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: own.changesURL, withDestinationURL: shared.changesURL)
    return own
}

private struct Pair {
    let folder: SyncFolder
    let a: Store
    let b: Store
    let clockA: TestClock
    let clockB: TestClock

    init(offsetB: Double = 0) throws {
        folder = tempFolder()
        clockA = TestClock()
        clockB = TestClock(1_700_000_000 + offsetB)
        try folder.prepare()
        a = try makeStore(folder, "mac-a", clock: clockA)
        b = try makeStore(sharingChanges(of: folder), "mac-b", clock: clockB)
    }
}

@Test func deviceBSeesDeviceAAddAfterSync() throws {
    let p = try Pair()
    try p.a.add([makeHighlight("a1", note: "#renal")])
    #expect(try p.b.highlights().isEmpty)
    #expect(try p.b.sync() == 1)
    #expect(try p.b.highlights() == p.a.highlights())
    #expect(try p.b.allTags() == ["renal"])
    #expect(try p.b.sessions().count == 1)
    #expect(try p.b.sessions().first?.deviceName == "MAC-A")
    #expect(try p.b.sync() == 0)
}

@Test func bothDevicesEditDifferentHighlightsAndConverge() throws {
    let p = try Pair()
    try p.a.add([makeHighlight("a1", page: 1), makeHighlight("b1", page: 2)])
    try p.b.sync()
    p.clockA.minutes(60)
    p.clockB.minutes(60)
    try p.a.setColor(["a1"], .pink)
    try p.b.setNote("b1", "from b #cards")
    try p.b.add([makeHighlight("b2", page: 3)])
    try p.a.sync()
    try p.b.sync()
    let expected = try p.a.highlights()
    #expect(try p.b.highlights() == expected)
    #expect(expected.count == 3)
    #expect(try p.a.highlight(id: "a1")?.color == HighlightColor.pink.rawValue)
    #expect(try p.a.highlight(id: "b1")?.note == "from b #cards")
    #expect(try p.b.allTags() == p.a.allTags())
    #expect(try p.a.sessions() == p.b.sessions())
}

@Test func concurrentColorChangesConvergeToLatestByOrderKey() throws {
    let p = try Pair()
    try p.a.add([makeHighlight("h", color: .yellow)])
    try p.b.sync()
    p.clockA.minutes(60)
    p.clockB.minutes(60)
    p.clockA.now += 10
    p.clockB.now += 20
    try p.a.setColor(["h"], .pink)
    try p.b.setColor(["h"], .green)
    try p.a.sync()
    try p.b.sync()
    #expect(try p.a.highlight(id: "h")?.color == HighlightColor.green.rawValue)
    #expect(try p.b.highlight(id: "h")?.color == HighlightColor.green.rawValue)
    #expect(try p.a.highlights() == p.b.highlights())
}

@Test func identicalTimestampConflictBreaksTieByDeviceThenSeq() throws {
    let p = try Pair()
    try p.a.add([makeHighlight("h", color: .yellow)])
    try p.b.sync()
    p.clockA.minutes(60)
    p.clockB.now = p.clockA.now
    try p.a.setColor(["h"], .pink)
    try p.b.setColor(["h"], .green)
    try p.a.sync()
    try p.b.sync()
    let tsA = try #require(try p.a.db.scalar("SELECT ts FROM ops WHERE id='mac-a:2'") as? Double)
    let tsB = try #require(try p.a.db.scalar("SELECT ts FROM ops WHERE id='mac-b:1'") as? Double)
    #expect(tsA == tsB)
    #expect(try p.a.highlight(id: "h")?.color == HighlightColor.green.rawValue)
    #expect(try p.b.highlight(id: "h")?.color == HighlightColor.green.rawValue)
}

@Test func outOfOrderArrivalTriggersRebuildAndConverges() throws {
    let p = try Pair(offsetB: -7200)
    try p.a.add([makeHighlight("h", color: .yellow), makeHighlight("other", page: 2)])
    try p.b.sync()
    p.clockA.minutes(60)
    try p.a.setColor(["h"], .pink)
    try p.a.sync()
    p.clockB.now = p.clockA.now - 3600
    try p.b.setColor(["h"], .green)
    let beforeRevision = p.a.revision
    #expect(try p.a.sync() == 1)
    #expect(p.a.revision > beforeRevision)
    try p.b.sync()
    #expect(try p.a.highlights() == p.b.highlights())
    #expect(try p.a.highlight(id: "h")?.color == HighlightColor.pink.rawValue)
    #expect(try p.b.highlight(id: "h")?.color == HighlightColor.pink.rawValue)
}

@Test func outOfOrderNoteChangeKeepsLaterNote() throws {
    let p = try Pair()
    try p.a.add([makeHighlight("h")])
    try p.b.sync()
    p.clockA.minutes(120)
    p.clockB.minutes(60)
    try p.a.setNote("h", "later #a")
    try p.b.setNote("h", "earlier #b")
    try p.a.sync()
    try p.b.sync()
    #expect(try p.a.highlight(id: "h")?.note == "later #a")
    #expect(try p.b.highlight(id: "h")?.note == "later #a")
    #expect(try p.a.allTags() == ["a"])
    #expect(try p.b.allTags() == ["a"])
}

@Test func partiallyWrittenLastLineIsNotConsumedUntilComplete() throws {
    let source = tempFolder()
    let remote = try makeStore(source, "mac-x")
    try remote.add([makeHighlight("x1")])
    let full = try Data(contentsOf: source.logURL(device: "mac-x"))
    #expect(full.last == 0x0A)

    let p = try Pair()
    let url = p.folder.logURL(device: "mac-x")
    try full.dropLast().write(to: url)
    #expect(try p.a.sync() == 0)
    #expect(try p.a.highlights().isEmpty)

    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data([0x0A]))
    try handle.close()
    #expect(try p.a.sync() == 1)
    #expect(try p.a.highlights().map(\.id) == ["x1"])
    #expect(try p.a.sync() == 0)
}

@Test func partialLineAfterCompleteLinesConsumesOnlyCompleteOnes() throws {
    let source = tempFolder()
    let remote = try makeStore(source, "mac-x")
    let clock = TestClock()
    remote.clock = { clock.now }
    try remote.add([makeHighlight("x1")])
    clock.minutes(60)
    try remote.add([makeHighlight("x2", page: 2)])
    let full = try Data(contentsOf: source.logURL(device: "mac-x"))
    let lines = full.split(separator: 0x0A, omittingEmptySubsequences: true)
    #expect(lines.count == 4)
    var partial = Data()
    for line in lines.dropLast() { partial.append(line); partial.append(0x0A) }
    partial.append(lines.last!.prefix(10))

    let p = try Pair()
    let url = p.folder.logURL(device: "mac-x")
    try partial.write(to: url)
    #expect(try p.a.sync() == 1)
    #expect(try p.a.highlights().map(\.id) == ["x1"])
    try full.write(to: url)
    #expect(try p.a.sync() == 1)
    #expect(try p.a.highlights().map(\.id) == ["x1", "x2"])
}

@Test func truncatedLogIsReadAgainWithoutDuplicatingOps() throws {
    let p = try Pair()
    try p.a.add([makeHighlight("h1"), makeHighlight("h2", page: 2)])
    p.clockA.minutes(60)
    try p.a.setColor(["h1"], .pink)
    #expect(try p.b.sync() == 3)
    let url = p.folder.logURL(device: "mac-a")
    let full = try Data(contentsOf: url)
    let firstLine = try #require(full.split(separator: 0x0A).first.map { Data($0) + Data([0x0A]) })
    try firstLine.write(to: url)
    let before = try opCount(p.b)
    #expect(try p.b.sync() == 0)
    #expect(try opCount(p.b) == before)
    #expect(try p.b.highlights() == p.a.highlights())
    try full.write(to: url)
    #expect(try p.b.sync() == 0)
    #expect(try opCount(p.b) == before)
    #expect(try p.b.highlights().count == 2)
}

@Test func replacedShorterLogWithReusedOpIDsAddsNothing() throws {
    let p = try Pair()
    try p.a.add([makeHighlight("h1", note: "a long note that makes the first log large enough")])
    #expect(try p.b.sync() == 1)

    let source = tempFolder()
    let other = try makeStore(source, "mac-a", clock: TestClock(1_700_100_000))
    try other.add([makeHighlight("z")])
    let replacement = try Data(contentsOf: source.logURL(device: "mac-a"))
    let original = try Data(contentsOf: p.folder.logURL(device: "mac-a"))
    #expect(replacement.count < original.count)
    try replacement.write(to: p.folder.logURL(device: "mac-a"))
    #expect(try p.b.sync() == 0)
    #expect(try p.b.highlights().map(\.id) == ["h1"])
}

@Test func icloudPlaceholderFilesAreNotParsed() throws {
    let source = tempFolder()
    let remote = try makeStore(source, "mac-x")
    try remote.add([makeHighlight("x1")])
    let valid = try Data(contentsOf: source.logURL(device: "mac-x"))

    let p = try Pair()
    try valid.write(to: p.folder.changesURL.appendingPathComponent(".mac-x.jsonl.icloud"))
    #expect(try p.a.sync() == 0)
    #expect(try p.a.highlights().isEmpty)
    #expect(p.folder.logFiles().map(\.lastPathComponent).allSatisfy { !$0.hasSuffix(".icloud") })
    let offsets = try p.a.db.query("SELECT file FROM sync_offsets").map { $0.string("file") }
    #expect(!offsets.contains { $0.hasSuffix(".icloud") })
}

@Test func corruptLogLinesAreSkipped() throws {
    let p = try Pair()
    try p.a.add([makeHighlight("h1")])
    try p.folder.append([Data("not json".utf8), Data("{\"op\":{}}".utf8)], device: "mac-a")
    #expect(try p.b.sync() == 1)
    #expect(try p.b.highlights().map(\.id) == ["h1"])
}

@Test func undoOnDeviceAOfSessionFromDeviceBSyncsBack() throws {
    let p = try Pair()
    try p.b.add([makeHighlight("b1", page: 1, note: "#cards"), makeHighlight("b2", page: 2)])
    p.clockB.minutes(60)
    try p.b.setColor(["b1"], .blue)
    try p.a.sync()
    let bSessions = try p.a.sessions()
    #expect(bSessions.count == 2)
    let first = try #require(bSessions.last)
    #expect(first.deviceName == "MAC-B")
    p.clockA.now = p.clockB.now + 60
    let plan = try p.a.undoPlan(session: first.id)
    #expect(plan.ops.count == 1)
    #expect(plan.skipped == 1)
    try p.a.commit(plan)
    #expect(try p.a.highlights().map(\.id) == ["b1"])

    try p.b.sync()
    #expect(try p.b.highlights() == p.a.highlights())
    let sessions = try p.b.sessions()
    #expect(sessions.count == 3)
    #expect(sessions[0].kind == .undo)
    #expect(sessions[0].deviceName == "MAC-A")
    #expect(sessions.last?.undoneBy == [sessions[0].id])
}

@Test func editSessionsAreNotSharedAcrossDevices() throws {
    let p = try Pair()
    try p.a.add([makeHighlight("a1")])
    try p.b.add([makeHighlight("b1", page: 2)])
    try p.a.sync()
    try p.b.sync()
    let sessions = try p.a.sessions()
    #expect(sessions.count == 2)
    #expect(Set(sessions.map(\.deviceName)) == ["MAC-A", "MAC-B"])
}

@Test func freshDeviceJoiningExistingFolderRebuildsEverything() throws {
    let p = try Pair()
    try p.a.add([makeHighlight("a1", note: "#x")])
    p.clockA.minutes(60)
    try p.a.setColor(["a1"], .green)
    try p.b.add([makeHighlight("b1", page: 4)])
    let c = try makeStore(sharingChanges(of: p.folder), "mac-c")
    try p.a.sync()
    #expect(try c.highlights() == p.a.highlights())
    #expect(try c.highlights().count == 2)
    #expect(try c.sessions().count == 3)
}

// MARK: Speed

@Test func applyAndRebuildFiveThousandOps() throws {
    let folder = tempFolder()
    let store = try makeStore(folder)
    let items = (0..<5000).map { makeHighlight("h\($0)", page: $0 % 20, text: "text number \($0)", note: $0 % 3 == 0 ? "#tag\($0 % 7)" : "") }

    let applyStart = Date()
    try store.add(items)
    let applyTime = Date().timeIntervalSince(applyStart)
    #expect(try store.highlights().count == 5000)

    let rebuildStart = Date()
    try store.rebuild()
    let rebuildTime = Date().timeIntervalSince(rebuildStart)
    #expect(try store.highlights().count == 5000)

    let other = try Store(folder: folder, device: "mac-b", deviceName: "B")
    #expect(try other.highlights().count == 5000)

    let syncFolder = tempFolder()
    let writer = try makeStore(syncFolder, "mac-a")
    try writer.add(items)
    let syncStart = Date()
    let reader = try Store(folder: SyncFolder(root: syncFolder.root), device: "mac-r", deviceName: "R")
    let syncTime = Date().timeIntervalSince(syncStart)
    #expect(try reader.highlights().count == 5000)
    print("TIMING apply 5000 ops: \(applyTime)s, rebuild 5000 ops: \(rebuildTime)s, first sync of 5000 ops: \(syncTime)s")
    #expect(rebuildTime < 1.0)
}
