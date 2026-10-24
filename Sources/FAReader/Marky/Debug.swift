#if DEBUG
import AppKit

enum Debug {
    static let trace = ProcessInfo.processInfo.environment["MARKY_TRACE"] != nil
}
#endif
