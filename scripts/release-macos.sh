#!/usr/bin/env sh
# Builds, tests, and inspects the stripped ReleaseSmall macOS artifact.
#
# The object is linked with Apple's ld instead of Zig's linker so that
# -no_data_const can fold the 8-byte __DATA_CONST segment into __DATA.
# Each Mach-O segment occupies a 16 KB page on disk, so that saves 16 KB.
#
# Usage: scripts/release-macos.sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DIST_DIR="$ROOT_DIR/dist"
BINARY_NAME="whichdns"
OBJECT="$ROOT_DIR/zig-out/release/$BINARY_NAME.o"
TARGET_ARCH=$(uname -m)
TARGET_BINARY="$DIST_DIR/whichdns-macos-$TARGET_ARCH"
SDK_PATH=$(xcrun -sdk macosx --show-sdk-path)
SDK_VERSION=$(xcrun -sdk macosx --show-sdk-version)
MIN_MACOS=12.0

cd "$ROOT_DIR"

zig build test

# Keep these flags in step with the ReleaseSmall settings in build.zig.
# -fcompiler-rt bundles the 128-bit division helper the ranking code needs.
mkdir -p "$(dirname "$OBJECT")"
zig build-obj -target "native-macos.$MIN_MACOS" -OReleaseSmall -lc -fstrip -fno-unwind-tables -fno-stack-check \
    -fomit-frame-pointer -fcompiler-rt \
    --dep core -Mroot=src/app/main.zig -Mcore=src/core/root.zig \
    -femit-bin="$OBJECT" --name "$BINARY_NAME"

mkdir -p "$DIST_DIR"
xcrun ld -arch "$TARGET_ARCH" -platform_version macos "$MIN_MACOS" "$SDK_VERSION" \
    -syslibroot "$SDK_PATH" -lSystem -dead_strip -S -x -no_data_const \
    -o "$TARGET_BINARY" "$OBJECT"
strip "$TARGET_BINARY"

"$TARGET_BINARY" --version >/dev/null
"$TARGET_BINARY" --list >/dev/null

printf 'Built %s\n' "$TARGET_BINARY"
printf 'Size: '
ls -lh "$TARGET_BINARY" | awk '{print $5}'
printf 'Segments:\n'
otool -l "$TARGET_BINARY" | awk '/segname/{n=$2} /filesize/{printf "  %-13s %s bytes\n", n, $2}'
printf 'Dependencies:\n'
otool -L "$TARGET_BINARY" | sed '1d; s/^/  /'
