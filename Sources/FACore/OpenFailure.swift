import Foundation

public enum OpenFailure {
    public static func reason(exists: Bool, status: URLUbiquitousItemDownloadingStatus?, statusError: Error? = nil, downloadError: Error? = nil) -> String {
        if !exists { return "The file is not at this path." }
        if status == .notDownloaded {
            if let downloadError { return "The file is in iCloud Drive and is not downloaded, and the app could not start the download. Download it in Finder, then open it again." }
            return "The file is in iCloud Drive and is not downloaded. The download has started. Open the book again after it finishes."
        }
        if let statusError { return "The file exists but is not a readable PDF. The iCloud status could not be read." }
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
