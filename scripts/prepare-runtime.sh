#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME_DIR="$PROJECT_ROOT/Sources/Nearby/Resources/Runtime"
CACHE_DIR="$PROJECT_ROOT/.build/nearby/dependencies"
ADB_VERSION="37.0.1"
ADB_SHA="1811e253b21b12cbfda7201ebaf86c10e7ddcb5c606a7a81f7c82b4c429c2d3b"
NOTICE_SHA="356cc66516060e4da6bdc53e6f0bbb8e8101673f326b73c68d535eddd04dd7b1"
PROPERTIES_SHA="2dccd788c0234d8cf7f7457377e57f57527a86a629c6ed54feb8af0f549dac38"
ADB_ZIP_SHA="ee39ad5967e95c2a07f04dbcbde96b1a0c916ba376096db5d2f498b7727a5d1d"
SERVER_VERSION="3.3.4"
SERVER_SHA="8588238c9a5a00aa542906b6ec7e6d5541d9ffb9b5d0f6e1bc0e365e2303079e"
SCRCPY_LICENSE_SHA="5e6597827749877cca06765747bf29ed9205ed5021c6aec1ad42373711bcda05"
TRANSFER_ARM64_SHA="8e8934b5600018f874b7b166c323a3e82d74e568d012772c880b670641611a3b"
TRANSFER_X64_SHA="b3c38025a59f5e8f0a2a6438a878a3a368e3f1e3fec1a36c9842cb77089a1f35"
TRANSFER_SOURCE_SHA="ee7e7e9a655f8d2c6276ce3cbba3b6885bde245a32c96747b4e541b766086bfb"

verify() {
    [ -f "$1" ] && [ "$(/usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}')" = "$2" ]
}

mkdir -p "$RUNTIME_DIR/Licenses" "$CACHE_DIR"
if ! verify "$RUNTIME_DIR/adb" "$ADB_SHA" || ! verify "$RUNTIME_DIR/Licenses/android-platform-tools-NOTICE.txt" "$NOTICE_SHA" || ! verify "$RUNTIME_DIR/android-platform-tools-source.properties" "$PROPERTIES_SHA"; then
    ZIP_PATH="$CACHE_DIR/platform-tools_r${ADB_VERSION}-darwin.zip"
    if ! verify "$ZIP_PATH" "$ADB_ZIP_SHA"; then
        /usr/bin/curl -fL --retry 2 --connect-timeout 15 "https://dl.google.com/android/repository/platform-tools_r${ADB_VERSION}-darwin.zip" -o "$ZIP_PATH"
    fi
    verify "$ZIP_PATH" "$ADB_ZIP_SHA" || { echo "Android platform tools checksum mismatch" >&2; exit 1; }
    /usr/bin/unzip -p "$ZIP_PATH" platform-tools/adb > "$RUNTIME_DIR/adb"
    /usr/bin/unzip -p "$ZIP_PATH" platform-tools/NOTICE.txt > "$RUNTIME_DIR/Licenses/android-platform-tools-NOTICE.txt"
    /usr/bin/unzip -p "$ZIP_PATH" platform-tools/source.properties > "$RUNTIME_DIR/android-platform-tools-source.properties"
fi
if ! verify "$RUNTIME_DIR/scrcpy-server-v$SERVER_VERSION" "$SERVER_SHA"; then
    /usr/bin/curl -fL --retry 2 --connect-timeout 15 "https://github.com/Genymobile/scrcpy/releases/download/v$SERVER_VERSION/scrcpy-server-v$SERVER_VERSION" -o "$RUNTIME_DIR/scrcpy-server-v$SERVER_VERSION"
fi
if ! verify "$RUNTIME_DIR/Licenses/scrcpy-LICENSE.txt" "$SCRCPY_LICENSE_SHA"; then
    /usr/bin/curl -fL --retry 2 --connect-timeout 15 "https://raw.githubusercontent.com/Genymobile/scrcpy/v$SERVER_VERSION/LICENSE" -o "$RUNTIME_DIR/Licenses/scrcpy-LICENSE.txt"
fi
verify "$RUNTIME_DIR/adb" "$ADB_SHA" || { echo "adb checksum mismatch" >&2; exit 1; }
verify "$RUNTIME_DIR/Licenses/android-platform-tools-NOTICE.txt" "$NOTICE_SHA" || { echo "Android NOTICE checksum mismatch" >&2; exit 1; }
verify "$RUNTIME_DIR/android-platform-tools-source.properties" "$PROPERTIES_SHA" || { echo "Android package metadata checksum mismatch" >&2; exit 1; }
verify "$RUNTIME_DIR/scrcpy-server-v$SERVER_VERSION" "$SERVER_SHA" || { echo "scrcpy server checksum mismatch" >&2; exit 1; }
verify "$RUNTIME_DIR/Licenses/scrcpy-LICENSE.txt" "$SCRCPY_LICENSE_SHA" || { echo "scrcpy license checksum mismatch" >&2; exit 1; }
verify "$RUNTIME_DIR/nearby-transfer-arm64-v8a" "$TRANSFER_ARM64_SHA" || { echo "Safe transfer helper checksum mismatch; run scripts/build-transfer-helper.sh" >&2; exit 1; }
verify "$RUNTIME_DIR/nearby-transfer-x86_64" "$TRANSFER_X64_SHA" || { echo "Safe transfer helper checksum mismatch; run scripts/build-transfer-helper.sh" >&2; exit 1; }
verify "$PROJECT_ROOT/scripts/nearby-transfer.c" "$TRANSFER_SOURCE_SHA" || { echo "Safe transfer source changed; rebuild helpers and refresh pinned runtime hashes" >&2; exit 1; }
chmod 755 "$RUNTIME_DIR/adb"
chmod 755 "$RUNTIME_DIR/nearby-transfer-arm64-v8a" "$RUNTIME_DIR/nearby-transfer-x86_64"
echo "Pinned runtime verified: adb $ADB_VERSION, scrcpy-server $SERVER_VERSION, safe transfer helper v1"
