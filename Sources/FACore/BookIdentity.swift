import CryptoKit
import Foundation

/// Stable identity for a PDF, independent of its path. The same bytes on two Macs share one id,
/// so highlights can live in the app's iCloud container instead of beside the file.
public enum BookIdentity {
    public static func contentHash(of url: URL, chunkSize: Int = 1 << 20) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        let size = max(chunkSize, 1)
        while true {
            let chunk = try handle.read(upToCount: size)
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// A folder name produced by `contentHash`.
    public static func isContentHash(_ name: String) -> Bool {
        name.count == 64 && name.allSatisfy(\.isHexDigit)
    }
}
