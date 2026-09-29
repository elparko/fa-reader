import AppKit

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

extension NSColor {
    /// A color that resolves differently in light and dark mode at draw time.
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.isDark ? dark : light }
    }
}

enum Theme {
    static let defaultFontSize: CGFloat = 15

    static var fontSize: CGFloat {
        get {
            let v = UserDefaults.standard.double(forKey: "FontSize")
            return v > 0 ? CGFloat(v) : defaultFontSize
        }
        set { UserDefaults.standard.set(Double(min(max(newValue, 9), 32)), forKey: "FontSize") }
    }

    /// Reading column width for the preview; the editor gets a bit more room.
    static let previewColumnWidth: CGFloat = 760
    static let editorColumnWidth: CGFloat = 820

    // Preview colors
    static let text = NSColor.textColor
    static let secondaryText = NSColor.secondaryLabelColor
    static let link = NSColor.linkColor
    static let rule = NSColor.dynamic(light: NSColor(white: 0, alpha: 0.12), dark: NSColor(white: 1, alpha: 0.14))
    static let quoteBar = NSColor.dynamic(light: NSColor(white: 0, alpha: 0.16), dark: NSColor(white: 1, alpha: 0.22))
    static let codeBlockBackground = NSColor.dynamic(light: NSColor(white: 0, alpha: 0.04), dark: NSColor(white: 1, alpha: 0.06))
    static let inlineCodeBackground = NSColor.dynamic(light: NSColor(white: 0, alpha: 0.06), dark: NSColor(white: 1, alpha: 0.10))
    static let tableHeaderBackground = NSColor.dynamic(light: NSColor(white: 0, alpha: 0.035), dark: NSColor(white: 1, alpha: 0.05))
    static let tableBorder = NSColor.dynamic(light: NSColor(white: 0, alpha: 0.14), dark: NSColor(white: 1, alpha: 0.16))

    // Editor syntax colors
    static let syntaxMarker = NSColor.tertiaryLabelColor
    static let syntaxQuote = NSColor.secondaryLabelColor
    static let syntaxListMarker = NSColor.controlAccentColor
    static let syntaxCode = NSColor.dynamic(
        light: NSColor(srgbRed: 0.64, green: 0.18, blue: 0.40, alpha: 1),
        dark: NSColor(srgbRed: 0.96, green: 0.56, blue: 0.72, alpha: 1))
    static let syntaxLink = NSColor.linkColor
}

/// Caches font variants so rendering never hits font lookup in the hot path.
final class FontCache {
    static let shared = FontCache()

    private struct Key: Hashable {
        let size: CGFloat
        let weight: CGFloat
        let italic: Bool
        let mono: Bool
    }

    private var fonts: [Key: NSFont] = [:]

    func font(size: CGFloat, weight: NSFont.Weight = .regular, italic: Bool = false, mono: Bool = false) -> NSFont {
        let key = Key(size: size, weight: weight.rawValue, italic: italic, mono: mono)
        if let f = fonts[key] { return f }
        var f = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
                     : NSFont.systemFont(ofSize: size, weight: weight)
        if italic {
            let d = f.fontDescriptor.withSymbolicTraits(f.fontDescriptor.symbolicTraits.union(.italic))
            f = NSFont(descriptor: d, size: size) ?? f
        }
        fonts[key] = f
        return f
    }
}
