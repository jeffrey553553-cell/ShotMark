#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFO_PLIST="$ROOT_DIR/Resources/Info.plist"
REPOSITORY="jeffrey553553-cell/ShotMark"
NOTES_FILE="${1:-}"

if [[ -z "$NOTES_FILE" || ! -f "$NOTES_FILE" ]]; then
  echo "usage: $0 /path/to/release-notes.md" >&2
  exit 64
fi

cd "$ROOT_DIR"
export SHOTMARK_RELEASE_MODE=public
"$ROOT_DIR/scripts/release_readiness.sh"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
tag="v$version"
dmg_path="$("$ROOT_DIR/scripts/package_dmg.sh")"

codesign --verify --deep --strict --verbose=2 "$ROOT_DIR/dist/ShotMark.app"
xcrun stapler validate "$dmg_path"
spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg_path"

digest="$(openssl dgst -sha256 "$dmg_path" | awk '{print $NF}')"
gh release create "$tag" "$dmg_path" \
  --repo "$REPOSITORY" \
  --target main \
  --title "ShotMark $tag" \
  --notes-file "$NOTES_FILE"

remote_digest="$(gh release view "$tag" --repo "$REPOSITORY" --json assets --jq '.assets[] | select(.name == "ShotMark.dmg") | .digest' | sed 's/^sha256://')"
if [[ "$digest" != "$remote_digest" ]]; then
  echo "error: uploaded DMG digest does not match the local artifact." >&2
  exit 1
fi

echo "Published notarized ShotMark $tag"
echo "SHA-256: $digest"
