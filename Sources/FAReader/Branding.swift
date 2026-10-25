import Foundation

/// The name users see. Change `PRODUCT_NAME` in `Config/Brand.xcconfig`.
/// That setting is the app name in Xcode, and `scripts/build-app.sh` copies it into the direct-download app.
/// `CFBundleName` and `CFBundleDisplayName` in `Resources/Info.plist` both use `$(PRODUCT_NAME)`.
enum Branding {
    static var displayName: String {
        let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        if let raw, !raw.isEmpty, !raw.contains("$(") { return raw }
        return "Rowlight"
    }
}
