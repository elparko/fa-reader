import Foundation
import Testing
@testable import FACore

private func lineData(_ s: String) -> Data { Data(s.utf8) }

private func text(_ lines: [Data]) -> [String] { lines.map { String(decoding: $0, as: UTF8.self) } }

@Test func syncFolderPathsFromPDF() {
    let pdf = URL(fileURLWithPath: "/Users/x/Docs/first aid.pdf")
    let f = SyncFolder(pdfURL: pdf)
    #expect(f.root.path == "/Users/x/Docs/first aid.fa-reader")
    #expect(f.changesURL.path == "/Users/x/Docs/first aid.fa-reader/changes")
    #expect(f.localURL.path == "/Users/x/Docs/first aid.fa-reader/local.nosync")
    #expect(f.databaseURL.path == "/Users/x/Docs/first aid.fa-reader/local.nosync/fa.sqlite")
    #expect(f.markdownURL.path == "/Users/x/Docs/first aid.fa-reader/markdown")
    #expect(f.logURL(device: "mac-a").path == "/Users/x/Docs/first aid.fa-reader/changes/mac-a.jsonl")
    #expect(f.localURL.lastPathComponent.hasSuffix(".nosync"))
}

@Test func syncFolderPrepareCreatesDirectories() throws {
    let f = tempFolder()
    try f.prepare()
    var isDir: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: f.changesURL.path, isDirectory: &isDir) && isDir.boolValue)
    #expect(FileManager.default.fileExists(atPath: f.localURL.path, isDirectory: &isDir) && isDir.boolValue)
    try f.prepare()
}

@Test func syncFolderAppendAndReadFromZero() throws {
    let f = tempFolder()
    try f.prepare()
    try f.append([lineData("one"), lineData("two")], device: "a")
    let url = f.logURL(device: "a")
    #expect(try String(contentsOf: url, encoding: .utf8) == "one\ntwo\n")
    let r = try #require(f.readLines(url, from: 0))
    #expect(text(r.lines) == ["one", "two"])
    #expect(r.end == 8)
}

@Test func syncFolderReadsOnlyNewLinesFromOffset() throws {
    let f = tempFolder()
    try f.prepare()
    try f.append([lineData("one")], device: "a")
    let url = f.logURL(device: "a")
    let first = try #require(f.readLines(url, from: 0))
    try f.append([lineData("two"), lineData("three")], device: "a")
    let second = try #require(f.readLines(url, from: first.end))
    #expect(text(second.lines) == ["two", "three"])
    let third = try #require(f.readLines(url, from: second.end))
    #expect(third.lines.isEmpty)
    #expect(third.end == second.end)
}

@Test func syncFolderPartialLastLineIsNotConsumed() throws {
    let f = tempFolder()
    try f.prepare()
    let url = f.logURL(device: "a")
    try Data("one\ntw".utf8).write(to: url)
    let first = try #require(f.readLines(url, from: 0))
    #expect(text(first.lines) == ["one"])
    #expect(first.end == 4)
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("o\n".utf8))
    try handle.close()
    let second = try #require(f.readLines(url, from: first.end))
    #expect(text(second.lines) == ["two"])
}

@Test func syncFolderOnlyPartialLineReturnsNothing() throws {
    let f = tempFolder()
    try f.prepare()
    let url = f.logURL(device: "a")
    try Data("partial".utf8).write(to: url)
    let r = try #require(f.readLines(url, from: 0))
    #expect(r.lines.isEmpty)
    #expect(r.end == 0)
}

@Test func syncFolderSkipsBlankLines() throws {
    let f = tempFolder()
    try f.prepare()
    let url = f.logURL(device: "a")
    try Data("one\n\n\ntwo\n".utf8).write(to: url)
    let r = try #require(f.readLines(url, from: 0))
    #expect(r.lines.count == 2)
    #expect(r.end == 10)
}

@Test func syncFolderShrunkFileIsReadFromStart() throws {
    let f = tempFolder()
    try f.prepare()
    let url = f.logURL(device: "a")
    try Data("aaaa\nbbbb\ncccc\n".utf8).write(to: url)
    let first = try #require(f.readLines(url, from: 0))
    try Data("xx\n".utf8).write(to: url)
    let r = try #require(f.readLines(url, from: first.end))
    #expect(text(r.lines) == ["xx"])
    #expect(r.end == 3)
}

@Test func syncFolderReadMissingFileIsNil() throws {
    let f = tempFolder()
    try f.prepare()
    #expect(f.readLines(f.logURL(device: "nobody"), from: 0) == nil)
}

@Test func syncFolderLogFilesListsOnlyLogs() throws {
    let f = tempFolder()
    try f.prepare()
    try f.append([lineData("x")], device: "b")
    try f.append([lineData("x")], device: "a")
    try Data().write(to: f.changesURL.appendingPathComponent(".c.jsonl.icloud"))
    try Data().write(to: f.changesURL.appendingPathComponent("notes.txt"))
    #expect(f.logFiles().map(\.lastPathComponent) == ["a.jsonl", "b.jsonl"])
}

@Test func logLineRoundTrips() throws {
    let s = Session(id: "s1", device: "a", deviceName: "A", started: 5, kind: .edit, label: "Edit", undoes: nil)
    let h = Highlight(id: "h1", page: 2, rects: [Rect(x: 1, y: 2, w: 3, h: 4)], text: "t", color: .green, note: "n", created: 9)
    let op = Op(id: "a:1", device: "a", seq: 1, ts: 6, session: "s1", kind: .add, highlight: "h1", page: 2, snapshot: h)
    for line in [LogLine.session(s), LogLine.op(op)] {
        let data = try JSONEncoder().encode(line)
        switch (line, try JSONDecoder().decode(LogLine.self, from: data)) {
        case (.session(let a), .session(let b)): #expect(a == b)
        case (.op(let a), .op(let b)): #expect(a == b)
        default: Issue.record("kind changed")
        }
    }
}
