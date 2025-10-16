#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-$PROJECT_ROOT/dist/Nearby.app}"
INFO_PATH="$APP_PATH/Contents/Info.plist"
RUNTIME_DIR="$APP_PATH/Contents/Resources/Runtime"

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
/usr/bin/codesign --verify --strict "$RUNTIME_DIR/adb"
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
