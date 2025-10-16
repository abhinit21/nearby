#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-$PROJECT_ROOT/dist/Nearby.app}"
INFO_PATH="$APP_PATH/Contents/Info.plist"
RUNTIME_DIR="$APP_PATH/Contents/Resources/Runtime"
EXPECTED_ARCHITECTURES="${NEARBY_EXPECT_ARCHITECTURES:-}"
EXPECTED_SDK_MAJOR="${NEARBY_EXPECT_SDK_MAJOR:-}"

test -x "$APP_PATH/Contents/MacOS/Nearby"
test -x "$RUNTIME_DIR/adb"
test -f "$RUNTIME_DIR/scrcpy-server-v3.3.4"
test -x "$RUNTIME_DIR/nearby-transfer-arm64-v8a"
test -x "$RUNTIME_DIR/nearby-transfer-x86_64"
test -s "$RUNTIME_DIR/Licenses/android-platform-tools-NOTICE.txt"
test -s "$RUNTIME_DIR/Licenses/scrcpy-LICENSE.txt"
test -s "$APP_PATH/Contents/Resources/Nearby.icns"
test -s "$APP_PATH/Contents/Resources/LICENSE"
test -s "$APP_PATH/Contents/Resources/THIRD-PARTY-NOTICES.txt"
test -s "$RUNTIME_DIR/dependency-manifest.json"
/usr/bin/plutil -lint "$INFO_PATH"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"
while IFS= read -r -d '' ADB_HELPER; do
    /usr/bin/codesign --verify --strict "$ADB_HELPER"
    for ARCHITECTURE in $EXPECTED_ARCHITECTURES; do
        /usr/bin/lipo -verify_arch "$ARCHITECTURE" "$ADB_HELPER"
    done
done < <(/usr/bin/find "$APP_PATH/Contents/Resources" -type f -name adb -print0)
if [ -n "$EXPECTED_ARCHITECTURES" ]; then
    for ARCHITECTURE in $EXPECTED_ARCHITECTURES; do
        /usr/bin/lipo -verify_arch "$ARCHITECTURE" "$APP_PATH/Contents/MacOS/Nearby"
        BUILD_INFO="$(/usr/bin/xcrun vtool -arch "$ARCHITECTURE" -show-build "$APP_PATH/Contents/MacOS/Nearby")"
        printf '%s\n' "$BUILD_INFO"
        MINIMUM_OS="$(printf '%s\n' "$BUILD_INFO" | /usr/bin/awk '$1 == "minos" { print $2 }')"
        case "$MINIMUM_OS" in
            26.0|26.0.0) ;;
            *) echo "Unexpected $ARCHITECTURE deployment target: $MINIMUM_OS (expected 26.0)" >&2; exit 1 ;;
        esac
        if [ -n "$EXPECTED_SDK_MAJOR" ]; then
            SDK_VERSION="$(printf '%s\n' "$BUILD_INFO" | /usr/bin/awk '$1 == "sdk" { print $2 }')"
            [ "${SDK_VERSION%%.*}" = "$EXPECTED_SDK_MAJOR" ] || {
                echo "Unexpected $ARCHITECTURE SDK: $SDK_VERSION (expected $EXPECTED_SDK_MAJOR.x)" >&2; exit 1;
            }
        fi
    done
    [ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO_PATH")" = "26.0" ]
fi
# Public binaries must not depend on Homebrew or files outside the app and OS.
while IFS= read -r LIBRARY; do
    case "$LIBRARY" in
        /System/Library/*|/usr/lib/*|@rpath/libswift*.dylib) ;;
        *) echo "Unexpected non-system dynamic library: $LIBRARY" >&2; exit 1 ;;
    esac
done < <(/usr/bin/otool -L "$APP_PATH/Contents/MacOS/Nearby" | /usr/bin/awk '/^\t/ { print $1 }')
ADB_INFO="$("$RUNTIME_DIR/adb" version)"
printf '%s\n' "$ADB_INFO"
case "$ADB_INFO" in
    *"Version 37.0.1-15733141"*) ;;
    *) echo "Packaged adb does not match pinned version 37.0.1-15733141" >&2; exit 1 ;;
esac
SERVER_SHA="$(/usr/bin/shasum -a 256 "$RUNTIME_DIR/scrcpy-server-v3.3.4" | /usr/bin/awk '{print $1}')"
[ "$SERVER_SHA" = "8588238c9a5a00aa542906b6ec7e6d5541d9ffb9b5d0f6e1bc0e365e2303079e" ]
TRANSFER_ARM64_SHA="$(/usr/bin/shasum -a 256 "$RUNTIME_DIR/nearby-transfer-arm64-v8a" | /usr/bin/awk '{print $1}')"
TRANSFER_X64_SHA="$(/usr/bin/shasum -a 256 "$RUNTIME_DIR/nearby-transfer-x86_64" | /usr/bin/awk '{print $1}')"
[ "$TRANSFER_ARM64_SHA" = "8e8934b5600018f874b7b166c323a3e82d74e568d012772c880b670641611a3b" ]
[ "$TRANSFER_X64_SHA" = "b3c38025a59f5e8f0a2a6438a878a3a368e3f1e3fec1a36c9842cb77089a1f35" ]
echo "Application bundle, signatures, pinned server, adb and transfer helpers, icon, and notices verified."
