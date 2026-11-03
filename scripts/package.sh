#!/bin/bash
# Build the app and wrap it in a drag-to-Applications disk image: dist/Account-Dock-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
export VERSION
scripts/build.sh

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "build/Account Dock.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

mkdir -p dist
DMG="dist/Account-Dock-${VERSION}.dmg"
rm -f "$DMG"
hdiutil create -quiet -volname "Account Dock" -srcfolder "$STAGE" -format UDZO -ov "$DMG"
( cd dist && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256" )
echo "Packaged: $DMG ($(du -h "$DMG" | cut -f1))"
