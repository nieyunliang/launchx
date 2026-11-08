#!/bin/bash
# 生成 LaunchX 原创图标: iconset -> iconutil -> resources/AppIcon.icns
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
ICONSET="$REPO/build/icon.iconset"
OUT="$REPO/resources/AppIcon.icns"

mkdir -p "$ICONSET" "$REPO/resources"
rm -f "$ICONSET"/*.png

gen() { swift "$REPO/scripts/icon_gen.swift" "$1" "$2"; }

gen "$ICONSET/icon_16x16.png"      16
gen "$ICONSET/icon_16x16@2x.png"   32
gen "$ICONSET/icon_32x32.png"      32
gen "$ICONSET/icon_32x32@2x.png"   64
gen "$ICONSET/icon_128x128.png"    128
gen "$ICONSET/icon_128x128@2x.png" 256
gen "$ICONSET/icon_256x256.png"    256
gen "$ICONSET/icon_256x256@2x.png" 512
gen "$ICONSET/icon_512x512.png"    512
gen "$ICONSET/icon_512x512@2x.png" 1024

iconutil -c icns -o "$OUT" "$ICONSET"
rm -rf "$REPO/build"

echo "生成完成: $OUT"
file "$OUT"
