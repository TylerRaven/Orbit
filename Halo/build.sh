#!/bin/zsh
# Builds Halo.app and installs it to ~/Applications.
#   ./build.sh          build + install
#   ./build.sh --open   build + install + launch
set -euo pipefail
cd "${0:A:h}"

APP=build/Halo.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "▸ Compiling"
swiftc -O -wmo -parse-as-library -swift-version 5 \
  -target "$(uname -m)-apple-macos26.0" \
  Sources/*.swift -o "$APP/Contents/MacOS/Halo"

cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "▸ Icon"
if [[ ! -f build/Halo.icns ]]; then
  swift scripts/make-icon.swift build/Halo.iconset
  iconutil -c icns build/Halo.iconset -o build/Halo.icns
fi
cp build/Halo.icns "$APP/Contents/Resources/Halo.icns"

echo "▸ Signing"
# Screen Recording and Accessibility permissions are tied to the app's signature.
# Signing with a real identity keeps them granted across rebuilds; ad-hoc signing
# means re-granting them after every build.
IDENTITY="$(security find-identity -p codesigning -v 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')"
codesign --force --deep --sign "${IDENTITY:--}" "$APP" >/dev/null

echo "▸ Installing to ~/Applications"
mkdir -p ~/Applications
pkill -x Halo 2>/dev/null && sleep 0.5 || true
rm -rf ~/Applications/Halo.app
cp -R "$APP" ~/Applications/Halo.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f ~/Applications/Halo.app

echo "✓ Halo.app installed"
[[ "${1:-}" == "--open" ]] && open ~/Applications/Halo.app
exit 0
