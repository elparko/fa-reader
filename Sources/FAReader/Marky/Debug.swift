import AppKit

/// Developer hooks, active only when environment variables are set:
///   MARKY_TRACE=1          log render timings
///   MARKY_SNAPSHOT=/dir    write PNG snapshots of each window after it renders
///   MARKY_MODE=split|editor|preview   initial mode
enum Debug {
    static let env = ProcessInfo.processInfo.environment
    static let trace = env["MARKY_TRACE"] != nil
    static let snapshotDir = env["MARKY_SNAPSHOT"]
    static let initialMode = env["MARKY_MODE"]

    static func snapshot(_ window: NSWindow?, name: String) {
        guard let dir = snapshotDir, let view = window?.contentView else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            NSLog("snapshot: %@", url.path)
        }
    }
}
