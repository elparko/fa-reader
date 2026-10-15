import Foundation

public enum OpenFailure {
    public static func reason(exists: Bool, inCloudNotDownloaded: Bool) -> String {
        if !exists { return "The file is not at this path." }
        if inCloudNotDownloaded { return "The file is in iCloud Drive and is not downloaded. FA Reader started the download. Open the book again after it finishes." }
        return "The file exists but is not a readable PDF."
    }

    public static func reason(for url: URL) -> String {
        let exists = FileManager.default.fileExists(atPath: url.path)
        let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus
        let inCloud = exists && status != nil && status != .current
        if inCloud { try? FileManager.default.startDownloadingUbiquitousItem(at: url) }
        return reason(exists: exists, inCloudNotDownloaded: inCloud)
    }
}
