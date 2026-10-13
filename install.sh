#!/bin/bash
# Downloads the latest Finder Address Bar, puts it into Applications and starts it.
# Usage: curl -fsSL https://raw.githubusercontent.com/Thominho/finder-address-bar/main/install.sh | bash
set -euo pipefail

URL="https://github.com/Thominho/finder-address-bar/releases/latest/download/FinderPathBar.zip"
APP="FinderPathBar.app"
DEST="${1:-/Applications}"
[ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading Finder Address Bar…"
curl -fsSL "$URL" -o "$TMP/FinderPathBar.zip"
ditto -x -k "$TMP/FinderPathBar.zip" "$TMP"

# replace a running older copy
pkill -x FinderPathBar 2>/dev/null || true
rm -rf "$DEST/$APP"
mv "$TMP/$APP" "$DEST/$APP"
open "$DEST/$APP"

echo "Installed: $DEST/$APP"
echo "It is running now: look for the folder icon in the menu bar."
echo "When macOS asks whether FinderPathBar may control Finder, allow it."
