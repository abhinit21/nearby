#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME_DIR="$PROJECT_ROOT/Sources/Nearby/Resources/Runtime"
NDK_ROOT="${NEARBY_ANDROID_NDK:-$HOME/Library/Android/sdk/ndk/28.0.12674087}"
TOOLCHAIN="$NDK_ROOT/toolchains/llvm/prebuilt/darwin-x86_64/bin"
SOURCE="$PROJECT_ROOT/scripts/nearby-transfer.c"

if [ ! -x "$TOOLCHAIN/aarch64-linux-android28-clang" ]; then
    echo "Set NEARBY_ANDROID_NDK to Android NDK 28 to rebuild the bundled safe transfer helper." >&2
    exit 1
fi

mkdir -p "$RUNTIME_DIR"
for ABI in arm64-v8a x86_64; do
    case "$ABI" in
        arm64-v8a) COMPILER="$TOOLCHAIN/aarch64-linux-android28-clang" ;;
        x86_64) COMPILER="$TOOLCHAIN/x86_64-linux-android28-clang" ;;
    esac
    "$COMPILER" -std=c11 -Os -Wall -Wextra -Werror -fPIE -pie -fstack-protector-strong \
        -Wl,-z,relro,-z,now -o "$RUNTIME_DIR/nearby-transfer-$ABI" "$SOURCE"
    "$TOOLCHAIN/llvm-strip" "$RUNTIME_DIR/nearby-transfer-$ABI"
    chmod 755 "$RUNTIME_DIR/nearby-transfer-$ABI"
done
/usr/bin/shasum -a 256 "$SOURCE" "$RUNTIME_DIR/nearby-transfer-arm64-v8a" "$RUNTIME_DIR/nearby-transfer-x86_64"
