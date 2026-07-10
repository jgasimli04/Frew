#!/bin/zsh
# make_app.sh — package BeeDeck as a real macOS app so the build survives as
# a launchable artifact (BEEDECK_ROADMAP; "the software is an exec").
#
#   scripts/make_app.sh            → dist/BeeDeck.app (+ dist/beehive-cli)
#   scripts/make_app.sh --install  → also copy to ~/Applications/BeeDeck.app
#
# The binary is fully static against our own code (CBeeDeck compiled in,
# libbee_ffi.a linked statically), so the bundle is self-contained.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=dist/BeeDeck.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/BeehiveApp "$APP/Contents/MacOS/BeeDeck"
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
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>0.1.0</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSHumanReadableCopyright</key><string>sonoFaig</string>
</dict>
</plist>
PLIST

codesign --force --deep -s - "$APP"

echo "built: $PWD/$APP"
if [[ "${1:-}" == "--install" ]]; then
    mkdir -p ~/Applications
    rm -rf ~/Applications/BeeDeck.app
    cp -R "$APP" ~/Applications/BeeDeck.app
    echo "installed: ~/Applications/BeeDeck.app"
fi
