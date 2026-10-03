import AppKit
import PDFKit

enum PageMatches {
    static func terms(_ query: String) -> [String] {
        query.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    static func selections(page: PDFPage, terms: [String], limit: Int = 60) -> [PDFSelection] {
        guard !terms.isEmpty, let text = page.string else { return [] }
        let ns = text as NSString
        if terms.count > 1 {
            let phrase = terms.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "[^\\p{L}\\p{N}]+")
            let regex = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])" + phrase, options: [.caseInsensitive])
            let exact = (regex?.matches(in: text, range: NSRange(location: 0, length: ns.length)) ?? [])
                .prefix(limit).compactMap { page.selection(for: $0.range) }
            if !exact.isEmpty { return exact }
        }
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
    static let width: CGFloat = 120

    private let queue = DispatchQueue(label: "fa-reader.thumbnails", qos: .userInitiated)
    private let document: PDFDocument?
    private let cache = NSCache<NSNumber, NSImage>()
    private let crops = NSCache<NSString, NSImage>()

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

    /// The part of a page around a highlight, with the highlight drawn in its color.
    func crop(page index: Int, rects: [CGRect], color: (Double, Double, Double), width: CGFloat) async -> NSImage? {
        let key = "\(index)|\(rects)|\(color)|\(width)" as NSString
        if let cached = crops.object(forKey: key) { return cached }
        let flag = CancelFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                queue.async { [self] in
                    guard !flag.isSet else { cont.resume(returning: nil); return }
                    let image = renderCrop(index, rects: rects, color: color, width: width)
                    if let image { crops.setObject(image, forKey: key) }
                    cont.resume(returning: image)
                }
            }
        } onCancel: {
            flag.set()
        }
    }

    private func renderCrop(_ index: Int, rects: [CGRect], color: (Double, Double, Double), width: CGFloat) -> NSImage? {
        guard let page = document?.page(at: index), !rects.isEmpty else { return nil }
        let box = page.bounds(for: .cropBox)
        let union = rects.reduce(CGRect.null) { $0.union($1) }
        var area = union.insetBy(dx: -24, dy: -22)
        if area.width < 300 { area = area.insetBy(dx: -(300 - area.width) / 2, dy: 0) }
        if area.height > 260 { area = CGRect(x: area.minX, y: area.maxY - 260, width: area.width, height: 260) }
        area = area.intersection(box)
        guard !area.isEmpty else { return nil }
        let scale = 2 * width / area.width
        let w = Int(area.width * scale), h = Int(area.height * scale)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: box.minX - area.minX, y: box.minY - area.minY)
        page.draw(with: .cropBox, to: ctx)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.setBlendMode(.multiply)
        ctx.setFillColor(CGColor(srgbRed: color.0, green: color.1, blue: color.2, alpha: 0.6))
        for r in rects { ctx.fill(r) }
        guard let image = ctx.makeImage() else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: CGFloat(w) / 2, height: CGFloat(h) / 2))
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
