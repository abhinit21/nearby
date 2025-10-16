#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Info.plist)"
case "$VERSION" in
    ''|*[!0-9.]*) echo "Release version must contain only numbers and dots" >&2; exit 1 ;;
esac
SDK_VERSION="$(/usr/bin/xcrun --sdk macosx --show-sdk-version)"
case "$SDK_VERSION" in
    26.*) ;;
    *) echo "Public releases require the macOS 26 SDK; selected SDK is $SDK_VERSION. Select Xcode 26 before packaging." >&2; exit 1 ;;
esac

RELEASE_DIR="${NEARBY_RELEASE_DIR:-$PROJECT_ROOT/dist/releases/$VERSION}"
mkdir -p "$RELEASE_DIR" "$PROJECT_ROOT/.build/nearby"
RELEASE_DIR="$(cd "$RELEASE_DIR" && pwd)"
WORK_DIR="$(/usr/bin/mktemp -d "$PROJECT_ROOT/.build/nearby/release.XXXXXX")"
MOUNT_PATH="$WORK_DIR/mounted"
cleanup() {
    if /sbin/mount | /usr/bin/grep -Fq " on $MOUNT_PATH "; then
        /usr/bin/hdiutil detach "$MOUNT_PATH" -quiet || true
    fi
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

export NEARBY_BUILD_CONFIGURATION=release
export NEARBY_BUILD_ARCHITECTURES="arm64 x86_64"
export NEARBY_EXPECT_ARCHITECTURES="arm64 x86_64"
export NEARBY_EXPECT_SDK_MAJOR=26
NEARBY_DIST_DIR="$WORK_DIR/build" ./scripts/build-app.sh
APP_PATH="$WORK_DIR/build/Nearby.app"
./scripts/verify-app.sh "$APP_PATH"

ASSET_NAME="Nearby-$VERSION-macOS-universal"
mkdir -p "$WORK_DIR/image" "$WORK_DIR/assets" "$MOUNT_PATH" "$WORK_DIR/zip-check"
/usr/bin/ditto "$APP_PATH" "$WORK_DIR/image/Nearby.app"
ln -s /Applications "$WORK_DIR/image/Applications"
cat > "$WORK_DIR/image/INSTALL.txt" <<'INSTALL'
Nearby for macOS — unsigned alpha

Requires macOS 26 or later, on an Apple silicon or Intel Mac.

1. Drag Nearby.app to the Applications folder.
2. Open Nearby from Applications.
3. This alpha is ad-hoc signed, without Developer ID signing or Apple
   notarization. If macOS blocks the first launch, open System Settings >
   Privacy & Security, find the message about Nearby, choose Open Anyway,
   and confirm Open. This option appears after trying to launch the app.
4. Enable Developer options and Wireless debugging on your Android phone.
   Keep the phone and Mac on the same trusted Wi-Fi network, then follow
   Nearby's pairing instructions.

Only approve the app when you downloaded it from the official repository:
https://github.com/abhinit21/nearby/releases

Setup, limitations, source code, and issue reporting:
https://github.com/abhinit21/nearby
INSTALL

/usr/bin/hdiutil create -volname "Nearby $VERSION" -srcfolder "$WORK_DIR/image" \
    -format UDZO -ov "$WORK_DIR/assets/$ASSET_NAME.dmg"
/usr/bin/hdiutil verify "$WORK_DIR/assets/$ASSET_NAME.dmg"
/usr/bin/hdiutil attach "$WORK_DIR/assets/$ASSET_NAME.dmg" -readonly -nobrowse -mountpoint "$MOUNT_PATH" -quiet
./scripts/verify-app.sh "$MOUNT_PATH/Nearby.app"
[ "$(readlink "$MOUNT_PATH/Applications")" = "/Applications" ]
test -s "$MOUNT_PATH/INSTALL.txt"
/usr/bin/hdiutil detach "$MOUNT_PATH" -quiet

cp "$WORK_DIR/build/Nearby-macOS.zip" "$WORK_DIR/assets/$ASSET_NAME.zip"
/usr/bin/unzip -t "$WORK_DIR/assets/$ASSET_NAME.zip"
/usr/bin/ditto -x -k "$WORK_DIR/assets/$ASSET_NAME.zip" "$WORK_DIR/zip-check"
./scripts/verify-app.sh "$WORK_DIR/zip-check/Nearby.app"

{
    printf 'Nearby %s (build %s)\n' "$VERSION" "$BUILD_NUMBER"
    printf 'Source commit: %s\n' "$(git rev-parse HEAD)"
    printf 'Architectures: arm64, x86_64\nMinimum macOS: 26.0\nSDK: %s\n' "$SDK_VERSION"
    printf 'Signing: ad-hoc; no Developer ID signature; not notarized\n'
    /usr/bin/xcodebuild -version
    /usr/bin/xcrun swift --version
    /usr/bin/sw_vers
} > "$WORK_DIR/assets/BUILD-INFO.txt"
(
    cd "$WORK_DIR/assets"
    /usr/bin/shasum -a 256 "$ASSET_NAME.dmg" "$ASSET_NAME.zip" BUILD-INFO.txt > SHA256SUMS.txt
    /usr/bin/shasum -a 256 -c SHA256SUMS.txt
)
for ASSET in "$WORK_DIR/assets/"*; do
    mv "$ASSET" "$RELEASE_DIR/"
done
printf 'Verified release assets: %s\n' "$RELEASE_DIR"
