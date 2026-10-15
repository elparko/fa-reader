import Foundation
import Testing
@testable import FACore

@Test func openFailureNamesMissingFile() {
    #expect(OpenFailure.reason(exists: false, inCloudNotDownloaded: false).contains("not at this path"))
}

@Test func openFailureNamesIcloudPlaceholder() {
    #expect(OpenFailure.reason(exists: true, inCloudNotDownloaded: true).contains("iCloud"))
}

@Test func openFailureNamesUnreadableFile() {
    #expect(OpenFailure.reason(exists: true, inCloudNotDownloaded: false).contains("not a readable PDF"))
}

@Test func openFailureForLocalNonPDF() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("bad-\(UUID().uuidString).pdf")
    try Data("x".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(OpenFailure.reason(for: url).contains("not a readable PDF"))
    #expect(OpenFailure.reason(for: url.appendingPathExtension("gone")).contains("not at this path"))
}
