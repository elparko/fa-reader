import Foundation
import Testing
@testable import FACore

@Test func openFailureNamesMissingFile() {
    #expect(OpenFailure.reason(exists: false, status: nil).contains("not at this path"))
}

@Test func openFailureNamesIcloudPlaceholder() {
    #expect(OpenFailure.reason(exists: true, status: .notDownloaded).contains("iCloud"))
}

@Test func openFailureTreatsDownloadedCopyAsUnreadable() {
    let text = OpenFailure.reason(exists: true, status: .downloaded)
    #expect(text.contains("not a readable PDF"))
    #expect(!text.contains("iCloud"))
    #expect(OpenFailure.reason(exists: true, status: .current).contains("not a readable PDF"))
}

@Test func openFailureNamesDownloadStartFailure() {
    struct Boom: Error, CustomStringConvertible { var description: String { "boom" } }
    let text = OpenFailure.reason(exists: true, status: .notDownloaded, downloadError: Boom())
    #expect(text.contains("could not start the download"))
    #expect(text.contains("boom"))
    #expect(!text.contains("started the download."))
}

@Test func openFailureKeepsStatusLookupError() {
    struct Boom: Error, CustomStringConvertible { var description: String { "boom" } }
    let text = OpenFailure.reason(exists: true, status: nil, statusError: Boom())
    #expect(text.contains("not a readable PDF"))
    #expect(text.contains("boom"))
}

@Test func openFailureNamesUnreadableFile() {
    #expect(OpenFailure.reason(exists: true, status: nil).contains("not a readable PDF"))
}

@Test func openFailureForLocalNonPDF() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("bad-\(UUID().uuidString).pdf")
    try Data("x".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(OpenFailure.reason(for: url).contains("not a readable PDF"))
    #expect(OpenFailure.reason(for: url.appendingPathExtension("gone")).contains("not at this path"))
}
