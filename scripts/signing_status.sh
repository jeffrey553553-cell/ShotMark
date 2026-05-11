#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-$ROOT_DIR/dist/ShotMark.app}"

echo "== Code signing identities =="
security find-identity -v -p codesigning || true

echo
echo "== App signature =="
if [[ -d "$APP_PATH" ]]; then
  codesign -dv --verbose=4 "$APP_PATH" 2>&1 || true
  echo
  codesign --verify --deep --verbose=2 "$APP_PATH" 2>&1 || true
else
  echo "App not found: $APP_PATH"
fi

echo
echo "== Permission note =="
cat <<'NOTE'
For stable Screen Recording permission during development, the app must be signed with a stable identity.
If Signature=adhoc and CDHash changes after rebuilds, reset permissions and grant again, or create a local Code Signing certificate named "ShotMark Local Developer".
NOTE
