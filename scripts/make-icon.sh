#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
swift scripts/make-icon.swift "$tmp/icon.png"
set_dir="$tmp/AppIcon.iconset"
mkdir "$set_dir"
for s in 16 32 128 256 512; do
    sips -z $s $s "$tmp/icon.png" --out "$set_dir/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d "$tmp/icon.png" --out "$set_dir/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$set_dir" -o Resources/AppIcon.icns
cp "$tmp/icon.png" Resources/AppIcon.png
rm -rf "$tmp"
echo Resources/AppIcon.icns
