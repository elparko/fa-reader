#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift build -c release
bin=$(swift build -c release --show-bin-path)
app="build/FA Reader.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin/FAReader" "$app/Contents/MacOS/FAReader"
cp Resources/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app"
echo "$app"
