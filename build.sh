#!/bin/bash
# Builds Claude Task Monitor.app into ./build
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Claude Task Monitor.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -swift-version 5 \
    -framework AppKit -framework SwiftUI \
    -o "$APP/Contents/MacOS/ClaudeTaskMonitor" \
    Sources/main.swift

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>ClaudeTaskMonitor</string>
    <key>CFBundleIdentifier</key><string>com.local.claude-task-monitor</string>
    <key>CFBundleName</key><string>Claude Task Monitor</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Claude Task Monitor selects the terminal tab hosting a Claude session when you click it.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built: $APP"
