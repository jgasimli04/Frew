#!/bin/zsh
# make_app.sh — package BeeDeck as a real macOS app from the *main* worktree
# (canonical source as of 2026-07-11; the helix breathe change lives here).
#
#   scripts/make_app.sh            → dist/BeeDeck.app (+ dist/beehive-cli)
#   scripts/make_app.sh --install  → also copy to ~/Applications/BeeDeck.app
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=dist/BeeDeck.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/BeehiveApp "$APP/Contents/MacOS/BeeDeck"
cp Resources/BeeDeck.icns "$APP/Contents/Resources/BeeDeck.icns"   # scripts/make_icon.swift
cp .build/release/beehive-cli dist/beehive-cli

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>BeeDeck</string>
    <key>CFBundleDisplayName</key>     <string>BeeDeck</string>
    <key>CFBundleExecutable</key>      <string>BeeDeck</string>
    <key>CFBundleIdentifier</key>      <string>com.sonofaig.beedeck</string>
    <key>CFBundleIconFile</key>        <string>BeeDeck</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>0.2.0</string>
    <key>CFBundleVersion</key>         <string>2</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSHumanReadableCopyright</key><string>sonoFaig</string>
</dict>
</plist>
PLIST

codesign --force --deep -s - "$APP"

echo "built: $PWD/$APP"
if [[ "${1:-}" == "--install" ]]; then
    # a running instance holds the old bundle; quit it before the swap
    osascript -e 'tell application "BeeDeck" to quit' 2>/dev/null || true
    mkdir -p ~/Applications
    rm -rf ~/Applications/BeeDeck.app
    cp -R "$APP" ~/Applications/BeeDeck.app
    # re-register so LaunchServices/Dock pick up the icon, then refresh the Dock
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
        -f ~/Applications/BeeDeck.app || true
    killall Dock 2>/dev/null || true
    echo "installed: ~/Applications/BeeDeck.app"
fi
