#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_CONFIGURATION="${NEARBY_BUILD_CONFIGURATION:-release}"
DIST_DIR="${NEARBY_DIST_DIR:-$PROJECT_ROOT/dist}"
BUILD_RESOURCES="$PROJECT_ROOT/.build/nearby/icon-resources"

cd "$PROJECT_ROOT"
mkdir -p "$DIST_DIR"
DIST_DIR="$(cd "$DIST_DIR" && pwd)"
APP_PATH="$DIST_DIR/Nearby.app"
./scripts/prepare-runtime.sh
/usr/bin/xcrun swift build --configuration "$BUILD_CONFIGURATION" --product Nearby
BIN_PATH="$(/usr/bin/xcrun swift build --configuration "$BUILD_CONFIGURATION" --show-bin-path)"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources" "$BUILD_RESOURCES"
cp "$BIN_PATH/Nearby" "$APP_PATH/Contents/MacOS/Nearby"
cp "$PROJECT_ROOT/Info.plist" "$APP_PATH/Contents/Info.plist"
printf 'APPL????' > "$APP_PATH/Contents/PkgInfo"

# Preserve SwiftPM's generated resource bundle for Bundle.module. Runtime is also
# in the conventional app resource directory for tools and command-line QA.
for RESOURCE_BUNDLE in "$BIN_PATH"/*.bundle; do
    if [ -d "$RESOURCE_BUNDLE" ]; then
        rm -rf "$APP_PATH/Contents/Resources/$(basename "$RESOURCE_BUNDLE")"
        /usr/bin/ditto "$RESOURCE_BUNDLE" "$APP_PATH/Contents/Resources/$(basename "$RESOURCE_BUNDLE")"
    fi
done
rm -rf "$APP_PATH/Contents/Resources/Runtime"
/usr/bin/ditto "$PROJECT_ROOT/Sources/Nearby/Resources/Runtime" "$APP_PATH/Contents/Resources/Runtime"
cp "$PROJECT_ROOT/THIRD-PARTY-NOTICES.txt" "$APP_PATH/Contents/Resources/THIRD-PARTY-NOTICES.txt"
cp "$PROJECT_ROOT/LICENSE" "$APP_PATH/Contents/Resources/LICENSE"

/usr/bin/xcrun swift "$PROJECT_ROOT/scripts/generate-icon.swift" "$BUILD_RESOURCES/Nearby.iconset"
/usr/bin/iconutil -c icns "$BUILD_RESOURCES/Nearby.iconset" -o "$APP_PATH/Contents/Resources/Nearby.icns"

# Development build for this Mac. Ad-hoc signing is not Developer ID signing or
# Apple notarization. Sign nested helper copies before the outer application.
while IFS= read -r -d '' ADB_HELPER; do
    chmod 755 "$ADB_HELPER"
    /usr/bin/codesign --force --sign - "$ADB_HELPER"
done < <(/usr/bin/find "$APP_PATH/Contents/Resources" -type f -name adb -print0)
/usr/bin/codesign --force --sign - "$APP_PATH/Contents/MacOS/Nearby"
/usr/bin/codesign --force --sign - "$APP_PATH"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"
/usr/bin/plutil -lint "$APP_PATH/Contents/Info.plist"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$DIST_DIR/Nearby-macOS.zip"
echo "Built $APP_PATH"
echo "Archive: $DIST_DIR/Nearby-macOS.zip"
echo "Launch with: open \"$APP_PATH\""
