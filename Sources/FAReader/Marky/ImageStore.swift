import AppKit
import ImageIO

/// Image cache shared by all windows. Local files load synchronously (downsampled,
/// keyed by modification date); remote images load in the background and trigger
/// a re-render when they arrive.
final class ImageStore {
    static let shared = ImageStore()

    private let cache = NSCache<NSString, NSImage>()
    private var inFlight = Set<URL>()
    private var failed = Set<URL>()
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        c.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: c)
    }()

    init() { cache.totalCostLimit = 256 * 1024 * 1024 }

    /// Returns an image if it is local or already fetched.
    func image(for url: URL) -> NSImage? {
        if url.isFileURL {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate?.timeIntervalSince1970 ?? 0
            let key = "\(url.path)|\(mtime)" as NSString
            if let img = cache.object(forKey: key) { return img }
            guard let img = Self.loadLocal(url) else { return nil }
            cache.setObject(img, forKey: key, cost: Self.cost(img))
            return img
        }
        return cache.object(forKey: url.absoluteString as NSString)
    }

    func shouldFetch(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return !failed.contains(url) && !inFlight.contains(url)
    }

    /// Fetches remote images; `onLoaded` runs on the main thread once per batch that produced an image.
    func fetch(_ urls: [URL], onLoaded: @escaping () -> Void) {
        let todo = urls.filter(shouldFetch)
        guard !todo.isEmpty else { return }
        let group = DispatchGroup()
        var gotAny = false
        for url in todo {
            inFlight.insert(url)
            group.enter()
            session.dataTask(with: url) { data, _, _ in
                let img = data.flatMap { Self.decode($0) }
                DispatchQueue.main.async {
                    self.inFlight.remove(url)
                    if let img {
                        self.cache.setObject(img, forKey: url.absoluteString as NSString, cost: Self.cost(img))
                        gotAny = true
                    } else {
                        self.failed.insert(url)
                    }
                    group.leave()
                }
            }.resume()
        }
        group.notify(queue: .main) { if gotAny { onLoaded() } }
    }

    private static func cost(_ img: NSImage) -> Int { Int(img.size.width * img.size.height * 4) }

    private static let maxPixels: CGFloat = 2400

    private static func loadLocal(_ url: URL) -> NSImage? {
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = downsample(src) {
            return img
        }
        return NSImage(contentsOf: url) // SVG, PDF and other formats ImageIO can't decode
    }

    private static func decode(_ data: Data) -> NSImage? {
        if let src = CGImageSourceCreateWithData(data as CFData, nil), let img = downsample(src) {
            return img
        }
        return NSImage(data: data)
    }

    private static func downsample(_ src: CGImageSource) -> NSImage? {
        guard CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let pw = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let ph = props[kCGImagePropertyPixelHeight] as? CGFloat, pw > 0, ph > 0 else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(pw, ph), maxPixels),
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        // Display at the image's natural size: one pixel per point, except Retina
        // images (e.g. macOS screenshots, 144 dpi) which are shown at half size.
        let dpi = props[kCGImagePropertyDPIWidth] as? CGFloat ?? 72
        let scale = dpi > 72 ? 72 / dpi : 1
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        let size = orientation >= 5 ? NSSize(width: ph * scale, height: pw * scale) : NSSize(width: pw * scale, height: ph * scale)
        return NSImage(cgImage: cg, size: size)
    }
}
