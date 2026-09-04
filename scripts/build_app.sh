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
RELEASE_MODE="${SHOTMARK_RELEASE_MODE:-development}"

if [[ "$RELEASE_MODE" == "public" ]]; then
  if [[ -z "${DEVELOPER_ID_APPLICATION:-}" ]]; then
    echo "error: public releases require DEVELOPER_ID_APPLICATION." >&2
    exit 1
  fi
  if [[ "$DEVELOPER_ID_APPLICATION" != Developer\ ID\ Application:* ]]; then
    echo "error: public releases must use a Developer ID Application identity." >&2
    exit 1
  fi
fi

cd "$ROOT_DIR"
mkdir -p "$ROOT_DIR/.build/module-cache"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/module-cache"

swift build -c release --disable-sandbox >&2

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$ROOT_DIR/.build/release/$APP_NAME" "$MACOS_DIR/$APP_NAME"
cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ROOT_DIR/Resources/ShotMark.entitlements" "$RESOURCES_DIR/ShotMark.entitlements"
cp "$ROOT_DIR/Resources/ShotMark.icns" "$RESOURCES_DIR/ShotMark.icns"
cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$RESOURCES_DIR/THIRD_PARTY_NOTICES.md"

clear_extended_attrs() {
  for _ in 1 2 3; do
    xattr -cr "$APP_DIR" 2>/dev/null || true
    xattr -c "$APP_DIR" 2>/dev/null || true
    sleep 0.1
  done
}

clear_extended_attrs

SIGNING_IDENTITY="${CODE_SIGN_IDENTITY:-${DEVELOPER_ID_APPLICATION:-}}"
if [[ "$RELEASE_MODE" == "public" ]]; then
  SIGNING_IDENTITY="$DEVELOPER_ID_APPLICATION"
fi
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

MICROPHONE_USAGE_DESCRIPTION="$(plutil -extract NSMicrophoneUsageDescription raw -o - "$CONTENTS_DIR/Info.plist" 2>/dev/null || true)"
if [[ -z "$MICROPHONE_USAGE_DESCRIPTION" ]]; then
  echo "error: NSMicrophoneUsageDescription is missing from the built app." >&2
  exit 1
fi

SIGNATURE_DETAILS="$(codesign -dv --verbose=4 "$APP_DIR" 2>&1)"
if ! grep -q "flags=.*runtime" <<<"$SIGNATURE_DETAILS"; then
  echo "error: the built app is missing Hardened Runtime." >&2
  exit 1
fi
if [[ "$RELEASE_MODE" == "public" ]] && ! grep -q "Authority=Developer ID Application:" <<<"$SIGNATURE_DETAILS"; then
  echo "error: public app is not signed by Developer ID Application." >&2
  exit 1
fi

has_audio_input_entitlement() {
  local signed_entitlements
  signed_entitlements="$(codesign -d --entitlements :- "$APP_DIR" 2>/dev/null || true)"
  plutil -p - <<<"$signed_entitlements" 2>/dev/null \
    | grep -q '"com.apple.security.device.audio-input" => 1'
}

ENTITLEMENT_VERIFIED=0
for _ in 1 2 3; do
  if has_audio_input_entitlement; then
    ENTITLEMENT_VERIFIED=1
    break
  fi
  sleep 0.15
done
if [[ "$ENTITLEMENT_VERIFIED" != "1" ]]; then
  echo "error: the built app is missing the Audio Input entitlement." >&2
  exit 1
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
