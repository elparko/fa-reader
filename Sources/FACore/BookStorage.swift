import Foundation

/// Where a book's change logs, notes, and search index live.
///
/// The direct-download build is not sandboxed, so it keeps the folder next to the PDF and iCloud Drive
/// can still sync it. The App Store build only receives access to the PDF the user picked, not that
/// folder, so it stores the same layout under the app's iCloud Documents container (or Application Support
/// when iCloud is unavailable), keyed by the book's content hash.
public enum BookDataPlace: Equatable {
    case besidePDF(URL)
    case ubiquityDocuments(URL)
    case applicationSupport(URL)

    public var root: URL {
        switch self {
        case .besidePDF(let url), .ubiquityDocuments(let url), .applicationSupport(let url):
            return url
        }
    }
}

public enum BookDataLocator {
    public static let ubiquityContainerIdentifier = "iCloud.com.parkersmith.fa-reader"
    public static let applicationSupportFolderName = "com.parkersmith.fa-reader"

    public static func applicationSupportDirectory(fileManager: FileManager = .default) throws -> URL {
        try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(applicationSupportFolderName, isDirectory: true)
    }

    public static func place(pdfURL: URL, bookID: String, sandboxed: Bool, ubiquityContainer: URL?, applicationSupport: URL) -> BookDataPlace {
        if !sandboxed {
            return .besidePDF(SyncFolder(pdfURL: pdfURL).root)
        }
        return containerPlace(bookID: bookID, ubiquityContainer: ubiquityContainer, applicationSupport: applicationSupport)
    }

    public static func containerPlace(bookID: String, ubiquityContainer: URL?, applicationSupport: URL) -> BookDataPlace {
        if let ubiquityContainer {
            let root = ubiquityContainer
                .appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent("Books", isDirectory: true)
                .appendingPathComponent(bookID, isDirectory: true)
            return .ubiquityDocuments(root)
        }
        let root = applicationSupport
            .appendingPathComponent("Books", isDirectory: true)
            .appendingPathComponent(bookID, isDirectory: true)
        return .applicationSupport(root)
    }

    /// Writes `book.json` so a hash-named folder can be matched back to a file name. Leaves an identical file alone.
    public static func writeIdentity(bookID: String, fileName: String, folder: SyncFolder) throws {
        try folder.prepare()
        let data = try JSONSerialization.data(withJSONObject: ["file": fileName, "id": bookID], options: [.sortedKeys])
        let url = folder.root.appendingPathComponent("book.json")
        if let existing = try? Data(contentsOf: url), existing == data { return }
        try CoordinatedFile.replace(at: url) { try data.write(to: $0, options: .atomic) }
    }
}

enum CoordinatedFile {
    static func replace(at url: URL, _ body: (URL) throws -> Void) throws {
        var coordError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { u in
            do { try body(u) } catch { writeError = error }
        }
        if let e = coordError ?? writeError { throw e }
    }

    static func copy(from source: URL, to destination: URL) throws {
        try replace(at: destination) { try FileManager.default.copyItem(at: source, to: $0) }
    }
}

public struct SidecarMigrationReport: Equatable {
    public var sidecarReadable: Bool
    public var copiedLogs: [String]
    public var copiedMarkdown: [String]
    public var destinationHadLogs: Bool
    public var idCollisions: Int = 0

    public static let none = SidecarMigrationReport(sidecarReadable: false, copiedLogs: [], copiedMarkdown: [], destinationHadLogs: false)
}

public enum SidecarMigration {
    /// The folder the user picked, or the `<name>.fa-reader` directory inside it when that is what they picked the parent of.
    public static func root(selected: URL, pdfURL: URL, fileManager: FileManager = .default) -> URL {
        if selected.lastPathComponent.hasSuffix(".fa-reader") { return selected }
        let named = pdfURL.deletingPathExtension().lastPathComponent + ".fa-reader"
        let child = selected.appendingPathComponent(named, isDirectory: true)
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue { return child }
        return selected
    }

    /// Copies change logs and markdown the destination does not already have. For a log the destination already has, appends the source lines it lacks and counts lines whose op id matches a different line. The search index is not copied;
    /// it is rebuilt from the logs. The sidecar is left in place. A sidecar that cannot be read (the usual
    /// sandbox case, until the user picks the folder) is reported as unreadable and copies nothing.
    public static func migrate(from sidecar: SyncFolder, to destination: SyncFolder, fileManager: FileManager = .default) -> SidecarMigrationReport {
        var report = SidecarMigrationReport.none
        if sidecar.root.standardizedFileURL.path == destination.root.standardizedFileURL.path {
            report.sidecarReadable = fileManager.fileExists(atPath: sidecar.root.path)
            return report
        }
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: sidecar.root.path, isDirectory: &isDir), isDir.boolValue,
              (try? fileManager.contentsOfDirectory(atPath: sidecar.root.path)) != nil else { return report }
        report.sidecarReadable = true

        let logNames = ((try? fileManager.contentsOfDirectory(atPath: sidecar.changesURL.path)) ?? [])
            .filter { $0.hasSuffix(".jsonl") && !$0.hasPrefix(".") }
            .sorted()
        let markdownNames = ((try? fileManager.contentsOfDirectory(atPath: sidecar.markdownURL.path)) ?? [])
            .filter { $0.hasSuffix(".md") && !$0.hasPrefix(".") }
            .sorted()
        let existingLogs = ((try? fileManager.contentsOfDirectory(atPath: destination.changesURL.path)) ?? [])
            .filter { $0.hasSuffix(".jsonl") }
        report.destinationHadLogs = !existingLogs.isEmpty
        guard !logNames.isEmpty || !markdownNames.isEmpty else { return report }

        try? destination.prepare()
        try? fileManager.createDirectory(at: destination.markdownURL, withIntermediateDirectories: true)
        for name in logNames {
            let dest = destination.changesURL.appendingPathComponent(name)
            let source = sidecar.changesURL.appendingPathComponent(name)
            if fileManager.fileExists(atPath: dest.path) {
                let merged = mergeLog(from: source, into: dest, name: name, destination: destination)
                if merged.appended > 0 { report.copiedLogs.append(name) }
                report.idCollisions += merged.collisions
                continue
            }
            if (try? CoordinatedFile.copy(from: source, to: dest)) != nil {
                report.copiedLogs.append(name)
            }
        }
        for name in markdownNames {
            let dest = destination.markdownURL.appendingPathComponent(name)
            if fileManager.fileExists(atPath: dest.path) { continue }
            if (try? CoordinatedFile.copy(from: sidecar.markdownURL.appendingPathComponent(name), to: dest)) != nil {
                report.copiedMarkdown.append(name)
            }
        }
        return report
    }

    private static func lineID(_ line: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        for kind in ["op", "session"] {
            if let body = object[kind] as? [String: Any], let id = body["id"] as? String { return "\(kind):\(id)" }
        }
        return nil
    }

    private static func mergeLog(from source: URL, into dest: URL, name: String, destination: SyncFolder) -> (appended: Int, collisions: Int) {
        guard let sourceLines = destination.readLines(source, from: 0)?.lines, !sourceLines.isEmpty,
              let destLines = destination.readLines(dest, from: 0)?.lines else { return (0, 0) }
        var known = Set(destLines)
        var ids = Set(destLines.compactMap(lineID))
        var missing: [Data] = []
        var collisions = 0
        for line in sourceLines {
            if known.contains(line) { continue }
            if let id = lineID(line), ids.contains(id) {
                collisions += 1
                continue
            }
            missing.append(line)
            known.insert(line)
            if let id = lineID(line) { ids.insert(id) }
        }
        guard !missing.isEmpty else { return (0, collisions) }
        let device = String(name.dropLast(".jsonl".count))
        guard (try? destination.append(missing, device: device)) != nil else { return (0, collisions) }
        return (missing.count, collisions)
    }
}

public struct OpenedBookData: Equatable {
    public var folder: SyncFolder
    public var bookID: String?
    public var migration: SidecarMigrationReport
    public var place: BookDataPlace
}

public enum BookStoreError: Error, CustomStringConvertible {
    case missingApplicationSupport

    public var description: String {
        switch self {
        case .missingApplicationSupport: return "The book data folder is not available."
        }
    }
}

public enum BookOpener {
    /// Chooses the sync folder and, for a sandboxed open, copies a readable legacy sidecar into it.
    public static func prepare(pdfURL: URL, sandboxed: Bool, ubiquityContainer: URL?, applicationSupport: URL?) throws -> OpenedBookData {
        if !sandboxed {
            let folder = SyncFolder(pdfURL: pdfURL)
            return OpenedBookData(folder: folder, bookID: nil, migration: .none, place: .besidePDF(folder.root))
        }
        let bookID = try BookIdentity.contentHash(of: pdfURL)
        if ubiquityContainer == nil, applicationSupport == nil { throw BookStoreError.missingApplicationSupport }
        let support = applicationSupport ?? URL(fileURLWithPath: "/unused")
        let place = BookDataLocator.place(pdfURL: pdfURL, bookID: bookID, sandboxed: true, ubiquityContainer: ubiquityContainer, applicationSupport: support)
        let folder = SyncFolder(root: place.root)
        // A launch before the iCloud container existed stored the book in Application Support.
        // Once the container is available, bring those logs and notes across. Files already in the
        // container are left alone.
        let fromSupport: SidecarMigrationReport
        if ubiquityContainer != nil, let applicationSupport {
            let local = SyncFolder(root: BookDataLocator.containerPlace(bookID: bookID, ubiquityContainer: nil, applicationSupport: applicationSupport).root)
            fromSupport = SidecarMigration.migrate(from: local, to: folder)
        } else {
            fromSupport = .none
        }
        let fromSidecar = SidecarMigration.migrate(from: SyncFolder(pdfURL: pdfURL), to: folder)
        let migration = SidecarMigrationReport(
            sidecarReadable: fromSidecar.sidecarReadable,
            copiedLogs: fromSupport.copiedLogs + fromSidecar.copiedLogs,
            copiedMarkdown: fromSupport.copiedMarkdown + fromSidecar.copiedMarkdown,
            destinationHadLogs: fromSupport.destinationHadLogs || fromSidecar.destinationHadLogs,
            idCollisions: fromSupport.idCollisions + fromSidecar.idCollisions
        )
        try BookDataLocator.writeIdentity(bookID: bookID, fileName: pdfURL.lastPathComponent, folder: folder)
        return OpenedBookData(folder: folder, bookID: bookID, migration: migration, place: place)
    }
}

public enum AppSandbox {
    /// Set by macOS for a sandboxed process. The direct-download build does not set it.
    public static var isActive: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }
}
