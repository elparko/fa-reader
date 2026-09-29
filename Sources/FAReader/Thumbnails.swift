import AppKit
import PDFKit

enum PageMatches {
    static func terms(_ query: String) -> [String] {
        query.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    static func selections(page: PDFPage, terms: [String], limit: Int = 60) -> [PDFSelection] {
        guard !terms.isEmpty, let text = page.string else { return [] }
        let ns = text as NSString
        var found: [(Int, PDFSelection)] = []
        for term in terms {
            var start = 0
            while start < ns.length, found.count < limit {
                let r = ns.range(of: term, options: [.caseInsensitive, .diacriticInsensitive],
                                 range: NSRange(location: start, length: ns.length - start))
                guard r.location != NSNotFound else { break }
                start = r.location + max(r.length, 1)
                if r.location > 0, let prev = Unicode.Scalar(ns.character(at: r.location - 1)),
                   CharacterSet.alphanumerics.contains(prev) { continue }
                if let s = page.selection(for: r) { found.append((r.location, s)) }
            }
        }
        return found.sorted { $0.0 < $1.0 }.map(\.1)
    }
}

final class Thumbnailer: @unchecked Sendable {
    static let width: CGFloat = 64

    private let queue = DispatchQueue(label: "fa-reader.thumbnails", qos: .userInitiated)
    private let document: PDFDocument?
    private let cache = NSCache<NSNumber, NSImage>()

    init(url: URL) {
        document = PDFDocument(url: url)
        cache.countLimit = 400
    }

    func thumbnail(page index: Int, marks: [CGRect]?, terms: [String]) async -> NSImage? {
        let flag = CancelFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                queue.async { [self] in
                    cont.resume(returning: flag.isSet ? nil : render(index, marks: marks, terms: terms))
                }
            }
        } onCancel: {
            flag.set()
        }
    }

    private func render(_ index: Int, marks: [CGRect]?, terms: [String]) -> NSImage? {
        guard let page = document?.page(at: index) else { return nil }
        let box = page.bounds(for: .cropBox)
        let scale = 2 * Thumbnailer.width / box.width
        let size = NSSize(width: box.width * scale, height: box.height * scale)
        let base: NSImage
        if let cached = cache.object(forKey: index as NSNumber) {
            base = cached
        } else {
            base = page.thumbnail(of: size, for: .cropBox)
            cache.setObject(base, forKey: index as NSNumber)
        }
        let rects = marks ?? PageMatches.selections(page: page, terms: terms).map { $0.bounds(for: page) }
        guard !rects.isEmpty else { return base }
        return NSImage(size: size, flipped: false) { _ in
            base.draw(in: NSRect(origin: .zero, size: size))
            for r in rects {
                let t = NSRect(x: (r.minX - box.minX) * scale, y: (r.minY - box.minY) * scale,
                               width: r.width * scale, height: r.height * scale).insetBy(dx: -3, dy: -3)
                NSColor.systemRed.withAlphaComponent(0.25).setFill()
                t.fill()
                NSColor.systemRed.setStroke()
                let path = NSBezierPath(rect: t)
                path.lineWidth = 2
                path.stroke()
            }
            return true
        }
    }
}

private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
