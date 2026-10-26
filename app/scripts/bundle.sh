#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUNDLE_DIR="$APP_DIR/QATwin.app"

cd "$APP_DIR"
swift build -c release --product QATwinApp

mkdir -p "$BUNDLE_DIR/Contents/MacOS"
cp "$APP_DIR/.build/release/QATwinApp" "$BUNDLE_DIR/Contents/MacOS/QATwin"

cat > "$BUNDLE_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>QA Twin</string>
    <key>CFBundleExecutable</key>
    <string>QATwin</string>
    <key>CFBundleIdentifier</key>
    <string>local.mobile-twin-qa.QATwin</string>
    <key>CFBundleName</key>
    <string>QA Twin</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>27.0</string>
</dict>
</plist>
PLIST

codesign -s - --force "$BUNDLE_DIR"
