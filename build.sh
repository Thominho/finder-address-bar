#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="FinderPathBar.app"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -O -o "$APP/Contents/MacOS/FinderPathBar" Sources/main.swift
codesign --force --sign - "$APP"
echo "Built: $PWD/$APP"
