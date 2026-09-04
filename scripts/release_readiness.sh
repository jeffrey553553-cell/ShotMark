#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFO_PLIST="$ROOT_DIR/Resources/Info.plist"
EXPECTED_REPOSITORY="jeffrey553553-cell/ShotMark"

cd "$ROOT_DIR"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: CFBundleShortVersionString must use x.y.z format: $version" >&2
  exit 1
fi
if [[ ! "$build" =~ ^[0-9]+$ ]]; then
  echo "error: CFBundleVersion must be a positive integer: $build" >&2
  exit 1
fi
if (( build < 1 )); then
  echo "error: CFBundleVersion must be greater than zero: $build" >&2
  exit 1
fi
if [[ -n "$(git status --short)" ]]; then
  echo "error: public release requires a clean git worktree." >&2
  git status --short >&2
  exit 1
fi
if [[ "$(git branch --show-current)" != "main" ]]; then
  echo "error: public release must be built from main." >&2
  exit 1
fi
git fetch --quiet origin main
if ! git merge-base --is-ancestor HEAD origin/main || ! git merge-base --is-ancestor origin/main HEAD; then
  echo "error: local main and origin/main must point to the same commit." >&2
  exit 1
fi
if [[ -z "${DEVELOPER_ID_APPLICATION:-}" || "$DEVELOPER_ID_APPLICATION" != Developer\ ID\ Application:* ]]; then
  echo "error: set DEVELOPER_ID_APPLICATION to a Developer ID Application identity." >&2
  exit 1
fi
if ! security find-identity -v -p codesigning | grep -Fq "\"$DEVELOPER_ID_APPLICATION\""; then
  echo "error: Developer ID identity is not available in the current keychain." >&2
  exit 1
fi
if [[ -z "${NOTARY_PROFILE:-}" ]]; then
  echo "error: set NOTARY_PROFILE to a notarytool keychain profile." >&2
  exit 1
fi
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null; then
  echo "error: NOTARY_PROFILE could not authenticate with Apple's notary service." >&2
  exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
  echo "error: GitHub CLI is not authenticated." >&2
  exit 1
fi
remote_url="$(git remote get-url origin)"
if [[ "$remote_url" != *"$EXPECTED_REPOSITORY"* ]]; then
  echo "error: origin does not point to $EXPECTED_REPOSITORY." >&2
  exit 1
fi
if gh release view "v$version" --repo "$EXPECTED_REPOSITORY" >/dev/null 2>&1; then
  echo "error: GitHub Release v$version already exists." >&2
  exit 1
fi

version_is_greater() {
  local candidate_major candidate_minor candidate_patch
  local current_major current_minor current_patch
  IFS=. read -r candidate_major candidate_minor candidate_patch <<<"$1"
  IFS=. read -r current_major current_minor current_patch <<<"$2"
  (( candidate_major > current_major )) && return 0
  (( candidate_major < current_major )) && return 1
  (( candidate_minor > current_minor )) && return 0
  (( candidate_minor < current_minor )) && return 1
  (( candidate_patch > current_patch ))
}

latest_tag="$(gh release view --repo "$EXPECTED_REPOSITORY" --json tagName --jq '.tagName' 2>/dev/null || true)"
latest_version="${latest_tag#v}"
if [[ -n "$latest_version" ]] && ! version_is_greater "$version" "$latest_version"; then
  echo "error: version $version must be newer than latest release $latest_version." >&2
  exit 1
fi

cat <<EOF
ShotMark public release prerequisites are ready.
Version: $version ($build)
Bundle ID: $bundle_id
Identity: $DEVELOPER_ID_APPLICATION
Notary profile: $NOTARY_PROFILE
Repository: $EXPECTED_REPOSITORY
EOF
