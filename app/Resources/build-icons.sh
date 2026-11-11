#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
work=$(mktemp -d "${TMPDIR:-/tmp}/peek-icons.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/AppIcon.iconset"
# Conform the full-bleed artwork to Apple's 824x824 icon grid (100px margin)
# so Launchpad shows it the same size as system icons. Source art is untouched.
swiftc Resources/conform-icon.swift -o "$work/conform" -framework AppKit
"$work/conform" Resources/AppIcon-1024.png "$work/AppIcon-1024-grid.png"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$work/AppIcon-1024-grid.png" --out "$work/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$work/AppIcon-1024-grid.png" --out "$work/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$work/AppIcon.iconset" -o "$work/AppIcon.icns"
mv "$work/AppIcon.icns" Resources/AppIcon.icns
