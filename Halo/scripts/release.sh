#!/bin/zsh
# Publishes a new Halo version that every installed copy will update to by itself.
#   Halo/scripts/release.sh 0.2
# Bumps the version, builds Halo.dmg, commits and tags halo-v0.2, pushes, and publishes a GitHub
# release with the dmg. Halo shares the Orbit repo, so its releases are never marked "latest" —
# that stays Orbit's, and Orbit's updater is unaffected.
set -euo pipefail
cd "${0:A:h}/.."

VERSION="${1:-}"
[[ "$VERSION" =~ '^[0-9]+(\.[0-9]+)*$' ]] || { echo "usage: Halo/scripts/release.sh 0.2"; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash your changes first."; exit 1; }

PLIST=Resources/Info.plist
REPO=$(plutil -extract HaloUpdateRepo raw "$PLIST")
CURRENT=$(plutil -extract CFBundleShortVersionString raw "$PLIST")
BUILD=$(( $(plutil -extract CFBundleVersion raw "$PLIST") + 1 ))
[[ "$(printf '%s\n%s\n' "$CURRENT" "$VERSION" | sort -V | tail -1)" == "$VERSION" && "$CURRENT" != "$VERSION" ]] \
  || { echo "$VERSION isn't newer than $CURRENT."; exit 1; }

perl -0pi -e "s|(<key>CFBundleShortVersionString</key>\s*<string>)[^<]*|\${1}$VERSION|; s|(<key>CFBundleVersion</key>\s*<string>)[^<]*|\${1}$BUILD|" "$PLIST"

NO_INSTALL=1 ./build.sh --dmg
git commit -q -m "Halo $VERSION" "$PLIST"
git tag "halo-v$VERSION"
echo "✓ Halo $VERSION committed and tagged halo-v$VERSION"

GH=$(command -v gh || echo /opt/homebrew/bin/gh)
if ! "$GH" auth status >/dev/null 2>&1; then
  cat <<MSG

Not logged in to GitHub, so nothing was published. Log in with  gh auth login  then run:
  git push && git push origin halo-v$VERSION
  gh release create halo-v$VERSION Halo/build/Halo.dmg --repo $REPO --title "Halo $VERSION" --latest=false
MSG
  exit 0
fi

echo "▸ Publishing"
git push -q origin HEAD && git push -q origin "halo-v$VERSION"
"$GH" release create "halo-v$VERSION" build/Halo.dmg --repo "$REPO" --title "Halo $VERSION" --latest=false \
  --notes "Halo $VERSION. Installed copies update themselves within a few hours (or Settings ▸ Check now)."
echo "✓ Released Halo $VERSION"
