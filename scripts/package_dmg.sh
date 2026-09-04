#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_MODE="${SHOTMARK_RELEASE_MODE:-development}"

if [[ "$RELEASE_MODE" == "public" ]]; then
  if [[ -z "${DEVELOPER_ID_APPLICATION:-}" || -z "${NOTARY_PROFILE:-}" ]]; then
    echo "error: public releases require DEVELOPER_ID_APPLICATION and NOTARY_PROFILE." >&2
    exit 1
  fi
fi
if [[ -n "${NOTARY_PROFILE:-}" && -z "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  echo "error: notarization requires a Developer ID Application identity." >&2
  exit 1
fi

APP_PATH="$("$ROOT_DIR/scripts/build_app.sh")"
DIST_DIR="$ROOT_DIR/dist"
DMG_PATH="$DIST_DIR/ShotMark.dmg"
VOLUME_NAME="ShotMark"
DMG_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/shotmark-dmg-root.XXXXXX")"

cleanup() {
  rm -rf "$DMG_ROOT"
}
trap cleanup EXIT

mkdir -p "$DIST_DIR"
ditto --norsrc "$APP_PATH" "$DMG_ROOT/ShotMark.app"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create -volname "$VOLUME_NAME" -srcfolder "$DMG_ROOT" -ov -format UDZO "$DMG_PATH"

if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  codesign --force --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$DMG_PATH"
fi

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
  spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"
fi

echo "$DMG_PATH"
