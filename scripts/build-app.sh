#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift build -c release --arch arm64 --arch x86_64
bin=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
app="build/FA Reader.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp "$bin/FAReader" "$app/Contents/MacOS/FAReader"
cp Resources/Info.plist "$app/Contents/Info.plist"
build=$(git rev-list --count HEAD 2>/dev/null || echo 0)
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build" -c "Set :CFBundleShortVersionString 1.$build" "$app/Contents/Info.plist"
codesign --force --sign - "$app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app"
echo "$app"
