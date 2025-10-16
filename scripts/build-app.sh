#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_CONFIGURATION="${NEARBY_BUILD_CONFIGURATION:-release}"
BUILD_ARCHITECTURES="${NEARBY_BUILD_ARCHITECTURES:-}"
DIST_DIR="${NEARBY_DIST_DIR:-$PROJECT_ROOT/dist}"
BUILD_RESOURCES="$PROJECT_ROOT/.build/nearby/icon-resources"

SWIFT_BUILD_ARGS=(--configuration "$BUILD_CONFIGURATION")
if [ -n "$BUILD_ARCHITECTURES" ]; then
    read -r -a ARCHITECTURES <<< "$BUILD_ARCHITECTURES"
    for ARCHITECTURE in "${ARCHITECTURES[@]}"; do
        case "$ARCHITECTURE" in
            arm64|x86_64) SWIFT_BUILD_ARGS+=(--arch "$ARCHITECTURE") ;;
            *) echo "Unsupported build architecture: $ARCHITECTURE" >&2; exit 1 ;;
        esac
    done
fi

cd "$PROJECT_ROOT"
mkdir -p "$DIST_DIR"
DIST_DIR="$(cd "$DIST_DIR" && pwd)"
APP_PATH="$DIST_DIR/Nearby.app"
# Assemble from scratch so removed resources cannot survive an earlier build.
# The existing output remains usable until the new bundle is verified.
STAGING_DIR="$(/usr/bin/mktemp -d "$DIST_DIR/.nearby-build.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
STAGING_APP="$STAGING_DIR/Nearby.app"
./scripts/prepare-runtime.sh
/usr/bin/xcrun swift build "${SWIFT_BUILD_ARGS[@]}" --product Nearby
BIN_PATH="$(/usr/bin/xcrun swift build "${SWIFT_BUILD_ARGS[@]}" --show-bin-path)"
mkdir -p "$STAGING_APP/Contents/MacOS" "$STAGING_APP/Contents/Resources" "$BUILD_RESOURCES"
cp "$BIN_PATH/Nearby" "$STAGING_APP/Contents/MacOS/Nearby"
cp "$PROJECT_ROOT/Info.plist" "$STAGING_APP/Contents/Info.plist"
printf 'APPL????' > "$STAGING_APP/Contents/PkgInfo"

# Preserve SwiftPM's generated resource bundle for Bundle.module. Runtime is also
# in the conventional app resource directory for tools and command-line QA.
for RESOURCE_BUNDLE in "$BIN_PATH"/*.bundle; do
    if [ -d "$RESOURCE_BUNDLE" ]; then
        /usr/bin/ditto "$RESOURCE_BUNDLE" "$STAGING_APP/Contents/Resources/$(basename "$RESOURCE_BUNDLE")"
    fi
done
/usr/bin/ditto "$PROJECT_ROOT/Sources/Nearby/Resources/Runtime" "$STAGING_APP/Contents/Resources/Runtime"
cp "$PROJECT_ROOT/THIRD-PARTY-NOTICES.txt" "$STAGING_APP/Contents/Resources/THIRD-PARTY-NOTICES.txt"
cp "$PROJECT_ROOT/LICENSE" "$STAGING_APP/Contents/Resources/LICENSE"

/usr/bin/xcrun swift "$PROJECT_ROOT/scripts/generate-icon.swift" "$BUILD_RESOURCES/Nearby.iconset"
/usr/bin/iconutil -c icns "$BUILD_RESOURCES/Nearby.iconset" -o "$STAGING_APP/Contents/Resources/Nearby.icns"

# Development build for this Mac. Ad-hoc signing is not Developer ID signing or
# Apple notarization. Sign nested helper copies before the outer application.
while IFS= read -r -d '' ADB_HELPER; do
    chmod 755 "$ADB_HELPER"
    /usr/bin/codesign --force --sign - "$ADB_HELPER"
done < <(/usr/bin/find "$STAGING_APP/Contents/Resources" -type f -name adb -print0)
/usr/bin/codesign --force --sign - "$STAGING_APP/Contents/MacOS/Nearby"
/usr/bin/codesign --force --sign - "$STAGING_APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$STAGING_APP"
/usr/bin/plutil -lint "$STAGING_APP/Contents/Info.plist"
rm -rf "$APP_PATH"
mv "$STAGING_APP" "$APP_PATH"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$DIST_DIR/Nearby-macOS.zip"
echo "Built $APP_PATH"
echo "Archive: $DIST_DIR/Nearby-macOS.zip"
echo "Launch with: open \"$APP_PATH\""
