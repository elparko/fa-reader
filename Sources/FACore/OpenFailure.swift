import Foundation

public enum OpenFailure {
    public static func reason(exists: Bool, status: URLUbiquitousItemDownloadingStatus?, statusError: Error? = nil, downloadError: Error? = nil) -> String {
        if !exists { return "The file is not at this path." }
        if status == .notDownloaded {
            if let downloadError { return "The file is in iCloud Drive and is not downloaded. FA Reader could not start the download: \(downloadError)" }
            return "The file is in iCloud Drive and is not downloaded. FA Reader started the download. Open the book again after it finishes."
        }
        if let statusError { return "The file exists but is not a readable PDF. FA Reader could not read the iCloud status: \(statusError)" }
        return "The file exists but is not a readable PDF."
    }

    public static func reason(for url: URL) -> String {
        let exists = FileManager.default.fileExists(atPath: url.path)
        var status: URLUbiquitousItemDownloadingStatus?
        var statusError: Error?
        var downloadError: Error?
        if exists {
            do { status = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus } catch { statusError = error }
        }
        if status == .notDownloaded {
            do { try FileManager.default.startDownloadingUbiquitousItem(at: url) } catch { downloadError = error }
        }
        return reason(exists: exists, status: status, statusError: statusError, downloadError: downloadError)
    }
}
