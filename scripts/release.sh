#!/bin/zsh
# Publishes a new Orbit version that existing copies will offer to update to.
#   scripts/release.sh 1.1
# Bumps the version, builds build/Orbit.dmg, commits and tags v1.1, then pushes and publishes the
# GitHub release with the dmg attached (needs the GitHub CLI: brew install gh && gh auth login).
set -euo pipefail
cd "${0:A:h}/.."

VERSION="${1:-}"
[[ "$VERSION" =~ '^[0-9]+(\.[0-9]+)*$' ]] || { echo "usage: scripts/release.sh 1.2"; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash your changes first."; exit 1; }

PLIST=Resources/Info.plist
REPO=$(plutil -extract OrbitUpdateRepo raw "$PLIST" 2>/dev/null || true)
[[ "$REPO" == */* ]] || { echo "Set OrbitUpdateRepo in $PLIST to your GitHub repo (owner/name) first."; exit 1; }
CURRENT=$(plutil -extract CFBundleShortVersionString raw "$PLIST")
BUILD=$(( $(plutil -extract CFBundleVersion raw "$PLIST") + 1 ))
[[ "$(printf '%s\n%s\n' "$CURRENT" "$VERSION" | sort -V | tail -1)" == "$VERSION" && "$CURRENT" != "$VERSION" ]] \
  || { echo "$VERSION isn't newer than $CURRENT."; exit 1; }

# Edit the values in place so the plist keeps its formatting.
perl -0pi -e "s|(<key>CFBundleShortVersionString</key>\s*<string>)[^<]*|\${1}$VERSION|; s|(<key>CFBundleVersion</key>\s*<string>)[^<]*|\${1}$BUILD|" "$PLIST"

NO_INSTALL=1 ./build.sh --dmg
git commit -q -m "Orbit $VERSION" "$PLIST"
git tag "v$VERSION"
echo "✓ Orbit $VERSION committed and tagged v$VERSION"

GH=$(command -v gh || echo /opt/homebrew/bin/gh)
if ! "$GH" auth status >/dev/null 2>&1; then
  cat <<EOF

Not logged in to GitHub, so nothing was published. Log in with  gh auth login  then run:
  git push && git push origin v$VERSION
  gh release create v$VERSION build/Orbit.dmg --title "Orbit $VERSION" --generate-notes
EOF
  exit 0
fi

echo "▸ Publishing"
git push -q origin HEAD && git push -q origin "v$VERSION"
NOTES="**Installing:** open Orbit.dmg and drag Orbit to Applications. The first time, macOS may say Orbit \"can't be opened\" because it isn't from the App Store: right-click Orbit in Applications, choose **Open**, then **Open** again (or System Settings → Privacy & Security → **Open Anyway**). After that, Orbit updates itself."
"$GH" release create "v$VERSION" build/Orbit.dmg --repo "$REPO" --title "Orbit $VERSION" --notes "$NOTES" --generate-notes
echo "✓ Released Orbit $VERSION — every copy will offer it within a day (or via Orbit ▸ Check for Updates…)"
