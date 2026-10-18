#!/bin/zsh
# Publishes a new Orbit version that existing copies will offer to update to.
#   scripts/release.sh 1.1
# Bumps the version, builds build/Orbit.dmg, commits and tags v1.1. With GITHUB_TOKEN set
# (a token that can write to the repo), it also pushes and creates the GitHub release with the dmg;
# otherwise it tells you what to upload by hand.
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

./build.sh --dmg
git commit -q -m "Orbit $VERSION" "$PLIST"
git tag "v$VERSION"
echo "✓ Orbit $VERSION committed and tagged v$VERSION"

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  cat <<EOF

Next: push, then publish the release on GitHub.
  git push && git push origin v$VERSION
  Open https://github.com/$REPO/releases/new, pick tag v$VERSION, and attach build/Orbit.dmg.
EOF
  exit 0
fi

git push -q && git push -q origin "v$VERSION"
echo "▸ Creating GitHub release"
API=https://api.github.com/repos/$REPO
AUTH=(-H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json")
UPLOAD=$(curl -fsS "${AUTH[@]}" -X POST "$API/releases" \
  -d "{\"tag_name\":\"v$VERSION\",\"name\":\"Orbit $VERSION\",\"generate_release_notes\":true}" \
  | plutil -extract upload_url raw -o - - | sed 's/{.*}//')
curl -fsS "${AUTH[@]}" -H "Content-Type: application/x-apple-diskimage" \
  --data-binary @build/Orbit.dmg "$UPLOAD?name=Orbit.dmg" >/dev/null
echo "✓ Released https://github.com/$REPO/releases/tag/v$VERSION"
