#!/bin/zsh
# Builds Orbit.app and installs it to ~/Applications.
#   ./build.sh          build + install
#   ./build.sh --open   build + install + launch
#   ./build.sh --dmg    build + install + make build/Orbit.dmg to share
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
# The Liquid Glass icon (Resources/Orbit.icon, editable in Icon Composer) needs actool from Xcode.
ACTOOL_DEV=""
for dev in "$(xcode-select -p 2>/dev/null)" /Applications/Xcode.app/Contents/Developer /Applications/Xcode-beta.app/Contents/Developer; do
  if [[ -x "$dev/usr/bin/actool" ]]; then ACTOOL_DEV="$dev"; break; fi
done
if [[ -n "$ACTOOL_DEV" ]]; then
  # actool resolves relative paths against its own directory, so pass absolute ones.
  DEVELOPER_DIR="$ACTOOL_DEV" xcrun actool --compile "$PWD/$APP/Contents/Resources" --platform macosx \
    --minimum-deployment-target 26.0 --app-icon Orbit \
    --output-partial-info-plist "$PWD/build/icon-partial.plist" "$PWD/Resources/Orbit.icon" >/dev/null
else
  # No Xcode: fall back to a flat icon drawn by script.
  if [[ ! -f build/AppIcon.icns ]]; then
    swift scripts/make-icon.swift build/AppIcon.iconset
    iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
  fi
  cp build/AppIcon.icns "$APP/Contents/Resources/Orbit.icns"
fi

echo "▸ Signing"
codesign --force --deep --sign - "$APP" >/dev/null

echo "▸ Installing to ~/Applications"
mkdir -p ~/Applications
pkill -x Orbit 2>/dev/null && sleep 0.5 || true
rm -rf ~/Applications/Orbit.app
cp -R "$APP" ~/Applications/Orbit.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f ~/Applications/Orbit.app
touch ~/Applications/Orbit.app # nudge Finder and the Dock to pick up a new icon

if [[ "${1:-}" == "--dmg" ]]; then
  echo "▸ Making Orbit.dmg"
  STAGE=build/dmg
  rm -rf "$STAGE" build/Orbit.dmg
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/Orbit.app"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "Orbit" -srcfolder "$STAGE" -ov -format UDZO build/Orbit.dmg >/dev/null
  rm -rf "$STAGE"
  echo "✓ build/Orbit.dmg ($(du -h build/Orbit.dmg | cut -f1))"
fi

echo "✓ Orbit.app installed"
[[ "${1:-}" == "--open" ]] && open ~/Applications/Orbit.app
exit 0
