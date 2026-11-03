#!/bin/bash
# Build "Account Dock.app" (universal, with icon). With --install, also copy it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.2}"

# Universal binary so it runs on Apple silicon and Intel Macs.
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/AccountDock"

APP="build/Account Dock.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Account Dock"
swift scripts/make-icon.swift "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Account Dock</string>
  <key>CFBundleDisplayName</key><string>Account Dock</string>
  <key>CFBundleIdentifier</key><string>local.account-dock</string>
  <key>CFBundleExecutable</key><string>Account Dock</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF

codesign --force --sign - "$APP" >/dev/null
echo "Built: $APP ($(lipo -archs "$APP/Contents/MacOS/Account Dock"))"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Account Dock.app"
  cp -R "$APP" "$HOME/Applications/"
  echo "Installed: $HOME/Applications/Account Dock.app"
fi
