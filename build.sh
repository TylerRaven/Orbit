#!/bin/zsh
# Builds Orbit.app and installs it to ~/Applications.
#   ./build.sh          build + install
#   ./build.sh --open   build + install + launch
set -euo pipefail
cd "${0:A:h}"

APP=build/Orbit.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "▸ Compiling"
swiftc -O -wmo -parse-as-library -swift-version 5 \
  -target "$(uname -m)-apple-macos26.0" \
  Sources/*.swift -o "$APP/Contents/MacOS/Orbit"

cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "▸ Icon"
if [[ ! -f build/AppIcon.icns ]]; then
  swift scripts/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "▸ Signing"
codesign --force --deep --sign - "$APP" >/dev/null

echo "▸ Installing to ~/Applications"
mkdir -p ~/Applications
pkill -x Orbit 2>/dev/null && sleep 0.5 || true
rm -rf ~/Applications/Orbit.app
cp -R "$APP" ~/Applications/Orbit.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f ~/Applications/Orbit.app

echo "✓ Orbit.app installed"
[[ "${1:-}" == "--open" ]] && open ~/Applications/Orbit.app
exit 0
