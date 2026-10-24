import Foundation

public struct SyncFolder: Equatable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public init(pdfURL: URL) {
        let name = pdfURL.deletingPathExtension().lastPathComponent + ".fa-reader"
        root = pdfURL.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
    }

    public var changesURL: URL { root.appendingPathComponent("changes", isDirectory: true) }
    public var localURL: URL { root.appendingPathComponent("local.nosync", isDirectory: true) }
    public var databaseURL: URL { localURL.appendingPathComponent("fa.sqlite") }
    public var markdownURL: URL { root.appendingPathComponent("markdown", isDirectory: true) }

    public func logURL(device: String) -> URL { changesURL.appendingPathComponent("\(device).jsonl") }

    public func prepare() throws {
        try FileManager.default.createDirectory(at: changesURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)
    }

    public func append(_ lines: [Data], device: String) throws {
        var data = Data()
        for line in lines { data.append(line); data.append(0x0A) }
        let url = logURL(device: device)
        var coordError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forMerging, error: &coordError) { u in
            do {
                if !FileManager.default.fileExists(atPath: u.path) {
                    FileManager.default.createFile(atPath: u.path, contents: nil)
                }
                let handle = try FileHandle(forUpdating: u)
                defer { try? handle.close() }
                let size = try handle.seekToEnd()
                if size > 0 {
                    try handle.seek(toOffset: size - 1)
                    if try handle.read(upToCount: 1) != Data([0x0A]) { data.insert(0x0A, at: data.startIndex) }
                    try handle.seekToEnd()
                }
                try handle.write(contentsOf: data)
                try handle.synchronize()
            } catch {
                writeError = error
            }
        }
        if let e = coordError ?? writeError { throw e }
    }

    public func logFiles() -> [URL] {
        var names: [String] = []
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: changesURL, options: .withoutChanges, error: &coordError) { u in
            names = (try? FileManager.default.contentsOfDirectory(atPath: u.path)) ?? []
        }
        var files: [URL] = []
        for name in names {
            if name.hasPrefix("."), name.hasSuffix(".jsonl.icloud") {
                let real = changesURL.appendingPathComponent(String(name.dropFirst().dropLast(".icloud".count)))
                try? FileManager.default.startDownloadingUbiquitousItem(at: real)
            } else if name.hasSuffix(".jsonl") {
                files.append(changesURL.appendingPathComponent(name))
            }
        }
        return files.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public func readLines(_ url: URL, from offset: Int) -> (lines: [Data], starts: [Int], end: Int)? {
        var coordError: NSError?
        var result: (lines: [Data], starts: [Int], end: Int)?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { u in
            guard let handle = try? FileHandle(forReadingFrom: u) else { return }
            defer { try? handle.close() }
            let size = Int((try? handle.seekToEnd()) ?? 0)
            let start = size < offset ? 0 : offset
            if size == start { result = ([], [], start); return }
            try? handle.seek(toOffset: UInt64(start))
            guard let data = try? handle.readToEnd(), let lastNewline = data.lastIndex(of: 0x0A) else {
                result = ([], [], start)
                return
            }
            let complete = data[data.startIndex...lastNewline]
            let pieces = complete.split(separator: 0x0A, omittingEmptySubsequences: true)
            let starts = pieces.map { start + $0.startIndex - data.startIndex }
            result = (pieces.map { Data($0) }, starts, start + complete.count)
        }
        return result
    }
}

public enum LogLine: Codable {
    case session(Session)
    case op(Op)

    private enum CodingKeys: String, CodingKey { case session, op }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try c.decodeIfPresent(Session.self, forKey: .session) {
            self = .session(s)
        } else {
            self = .op(try c.decode(Op.self, forKey: .op))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .session(let s): try c.encode(s, forKey: .session)
        case .op(let o): try c.encode(o, forKey: .op)
        }
    }
}
