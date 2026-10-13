#!/bin/bash
# Builds FinderPathBar.app. With --zip also packs it for a release.
set -euo pipefail
cd "$(dirname "$0")"

APP="FinderPathBar.app"
BIN="$APP/Contents/MacOS/FinderPathBar"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"

# universal binary for macOS 13 and later
for arch in arm64 x86_64; do
    swiftc -O -target "$arch-apple-macos13.0" -o "$BIN-$arch" Sources/main.swift
done
lipo -create "$BIN-arm64" "$BIN-x86_64" -output "$BIN"
rm "$BIN-arm64" "$BIN-x86_64"

codesign --force --sign - "$APP"
echo "Built: $PWD/$APP"

if [[ "${1:-}" == "--zip" ]]; then
    ditto -c -k --keepParent "$APP" FinderPathBar.zip
    echo "Packed: $PWD/FinderPathBar.zip"
fi
