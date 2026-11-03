#!/bin/bash
# Build the app and wrap it in a drag-to-Applications disk image: dist/AccountDock-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
export VERSION
scripts/build.sh

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "build/AccountDock.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

mkdir -p dist
DMG="dist/AccountDock-${VERSION}.dmg"
rm -f "$DMG"
hdiutil create -quiet -volname "AccountDock" -srcfolder "$STAGE" -format UDZO -ov "$DMG"
( cd dist && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256" )
echo "Packaged: $DMG ($(du -h "$DMG" | cut -f1))"
