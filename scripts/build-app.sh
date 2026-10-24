#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift build -c release --arch arm64 --arch x86_64
bin=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
# Folder name stays "FA Reader.app" so the updater already on other Macs, which
# looks for that name inside the zip, can replace the app. The display name
# written below is PRODUCT_NAME from Config/Brand.xcconfig.
app="build/FA Reader.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp Resources/PrivacyInfo.xcprivacy "$app/Contents/Resources/PrivacyInfo.xcprivacy"
cp Resources/Credits.html "$app/Contents/Resources/Credits.html"
cp "$bin/FAReader" "$app/Contents/MacOS/FAReader"
cp Resources/Info.plist "$app/Contents/Info.plist"
brand_value() { sed -n "s/^$1 = //p" Config/Brand.xcconfig | head -n 1; }
name=$(brand_value PRODUCT_NAME)
bundle=$(brand_value PRODUCT_BUNDLE_IDENTIFIER)
marketing=$(brand_value MARKETING_VERSION)
copyright=$(brand_value FA_COPYRIGHT)
build=$(git rev-list --count HEAD 2>/dev/null || echo 0)
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleName $name" \
  -c "Set :CFBundleDisplayName $name" \
  -c "Set :CFBundleIdentifier $bundle" \
  -c "Set :CFBundleShortVersionString $marketing" \
  -c "Set :CFBundleVersion $build" \
  -c "Set :NSHumanReadableCopyright $copyright" \
  -c "Set :CFBundleURLTypes:0:CFBundleURLName $bundle" \
  "$app/Contents/Info.plist"
codesign --force --sign - "$app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app"
echo "$app"
