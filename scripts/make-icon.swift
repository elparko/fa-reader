import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowBlurRadius = 28
    shadow.set()
    NSColor(srgbRed: 0.16, green: 0.20, blue: 0.42, alpha: 1).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: NSColor(srgbRed: 0.27, green: 0.33, blue: 0.62, alpha: 1),
               ending: NSColor(srgbRed: 0.13, green: 0.16, blue: 0.36, alpha: 1))!.draw(in: shape, angle: -90)

    let page = NSRect(x: 262, y: 190, width: 500, height: 644)
    NSGraphicsContext.saveGraphicsState()
    let pageShadow = NSShadow()
    pageShadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    pageShadow.shadowOffset = NSSize(width: 0, height: -8)
    pageShadow.shadowBlurRadius = 18
    pageShadow.set()
    NSColor(srgbRed: 0.98, green: 0.97, blue: 0.94, alpha: 1).setFill()
    NSBezierPath(roundedRect: page, xRadius: 26, yRadius: 26).fill()
    NSGraphicsContext.restoreGraphicsState()

    let colors: [NSColor?] = [
        nil, NSColor(srgbRed: 0.980, green: 0.804, blue: 0.353, alpha: 0.85), nil,
        NSColor(srgbRed: 0.486, green: 0.784, blue: 0.408, alpha: 0.85), nil,
        NSColor(srgbRed: 0.984, green: 0.361, blue: 0.537, alpha: 0.85), nil,
        NSColor(srgbRed: 0.388, green: 0.639, blue: 0.980, alpha: 0.85), nil,
    ]
    let widths: [CGFloat] = [380, 330, 400, 260, 390, 350, 300, 370, 220]
    for (i, width) in widths.enumerated() {
        let y = page.maxY - 92 - CGFloat(i) * 60
        if let c = colors[i] {
            c.setFill()
            NSBezierPath(roundedRect: NSRect(x: page.minX + 46, y: y - 16, width: width + 8, height: 46), xRadius: 8, yRadius: 8).fill()
        }
        NSColor(srgbRed: 0.30, green: 0.32, blue: 0.38, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: page.minX + 50, y: y, width: width, height: 14), xRadius: 7, yRadius: 7).fill()
    }
    return true
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: out)
