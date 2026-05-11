#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="ShotMark"
PUBLIC_DIST_DIR="$ROOT_DIR/dist"
STAGE_DIR="${SHOTMARK_STAGE_DIR:-/private/tmp/shotmark-build}"
APP_DIR="$STAGE_DIR/$APP_NAME.app"
PUBLIC_APP_DIR="$PUBLIC_DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
PUBLIC_COPY="${SHOTMARK_PUBLIC_COPY:-1}"
LOCAL_SIGNING_NAME="${LOCAL_SIGNING_NAME:-ShotMark Local Developer}"

cd "$ROOT_DIR"
mkdir -p "$ROOT_DIR/.build/module-cache"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/module-cache"

swift build -c release --disable-sandbox >&2

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$ROOT_DIR/.build/release/$APP_NAME" "$MACOS_DIR/$APP_NAME"
cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ROOT_DIR/Resources/ShotMark.entitlements" "$RESOURCES_DIR/ShotMark.entitlements"

clear_extended_attrs() {
  for _ in 1 2 3; do
    xattr -cr "$APP_DIR" 2>/dev/null || true
    xattr -c "$APP_DIR" 2>/dev/null || true
    sleep 0.1
  done
}

clear_extended_attrs

SIGNING_IDENTITY="${CODE_SIGN_IDENTITY:-${DEVELOPER_ID_APPLICATION:-}}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  if grep -q "$LOCAL_SIGNING_NAME" <<<"$SIGNING_IDENTITIES"; then
    SIGNING_IDENTITY="$LOCAL_SIGNING_NAME"
  fi
fi

if [[ -n "$SIGNING_IDENTITY" ]]; then
  TIMESTAMP_ARGS=(--timestamp)
  if [[ "$SIGNING_IDENTITY" == "$LOCAL_SIGNING_NAME" ]]; then
    TIMESTAMP_ARGS=(--timestamp=none)
  fi

  codesign --force --deep "${TIMESTAMP_ARGS[@]}" --options runtime \
    --entitlements "$ROOT_DIR/Resources/ShotMark.entitlements" \
    --sign "$SIGNING_IDENTITY" \
    "$APP_DIR"
else
  cat >&2 <<'WARN'
warning: no code-signing identity found; using ad-hoc signing.
warning: macOS Screen Recording permission may reset after every rebuild because the app CDHash changes.
warning: create a local "ShotMark Local Developer" Code Signing certificate or pass CODE_SIGN_IDENTITY for stable permissions.
WARN
  codesign --force --deep --options runtime \
    --entitlements "$ROOT_DIR/Resources/ShotMark.entitlements" \
    --sign - \
    "$APP_DIR"
fi

if [[ "$PUBLIC_COPY" == "1" ]]; then
  mkdir -p "$PUBLIC_DIST_DIR"
  rm -rf "$PUBLIC_APP_DIR"
  ditto --norsrc "$APP_DIR" "$PUBLIC_APP_DIR"
  xattr -cr "$PUBLIC_APP_DIR" 2>/dev/null || true
  xattr -c "$PUBLIC_APP_DIR" 2>/dev/null || true
  echo "$PUBLIC_APP_DIR"
else
  echo "$APP_DIR"
fi
