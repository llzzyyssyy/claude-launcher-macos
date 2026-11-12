#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
OUTPUT_DIR="${1:-$SCRIPT_DIR/build}"
APP_NAME="Claude 启动器.app"
APP_DIR="$OUTPUT_DIR/$APP_NAME"
MODULE_CACHE="$SCRIPT_DIR/.module-cache"
ICONSET_DIR="$SCRIPT_DIR/build-assets/AppIcon.iconset"

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$MODULE_CACHE" "$ICONSET_DIR"

# Build the macOS multi-resolution icon from the generated 1254 px master.
sips -z 16 16 "$SCRIPT_DIR/Resources/AppIcon-master.png" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
sips -z 32 32 "$SCRIPT_DIR/Resources/AppIcon-master.png" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$SCRIPT_DIR/Resources/AppIcon-master.png" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
sips -z 64 64 "$SCRIPT_DIR/Resources/AppIcon-master.png" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$SCRIPT_DIR/Resources/AppIcon-master.png" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
sips -z 256 256 "$SCRIPT_DIR/Resources/AppIcon-master.png" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$SCRIPT_DIR/Resources/AppIcon-master.png" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
sips -z 512 512 "$SCRIPT_DIR/Resources/AppIcon-master.png" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$SCRIPT_DIR/Resources/AppIcon-master.png" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$SCRIPT_DIR/Resources/AppIcon-master.png" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null

# macOS 26 iconutil currently rejects otherwise valid iconsets in this
# execution environment, so package the standard PNG representations into a
# valid ICNS container directly.
CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
SWIFT_MODULE_CACHE_PATH="$MODULE_CACHE" \
xcrun swiftc -swift-version 5 -O \
  "$SCRIPT_DIR/Tools/make_icns.swift" \
  -o "$SCRIPT_DIR/build-assets/make_icns"
"$SCRIPT_DIR/build-assets/make_icns" \
  "$ICONSET_DIR" \
  "$APP_DIR/Contents/Resources/AppIcon.icns"

CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
SWIFT_MODULE_CACHE_PATH="$MODULE_CACHE" \
xcrun swiftc \
  -swift-version 5 \
  -O \
  -framework AppKit \
  -framework SwiftUI \
  "$SCRIPT_DIR/Sources/ClaudeLauncher/main.swift" \
  -o "$APP_DIR/Contents/MacOS/ClaudeLauncher"

cp "$SCRIPT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
codesign --force --deep --sign - "$APP_DIR"

echo "$APP_DIR"

