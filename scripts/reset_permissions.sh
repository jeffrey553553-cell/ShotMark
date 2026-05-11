#!/usr/bin/env bash
set -euo pipefail

BUNDLE_ID="${1:-com.local.shotmark}"

echo "Resetting macOS privacy permissions for $BUNDLE_ID"
tccutil reset ScreenCapture "$BUNDLE_ID" || true
tccutil reset Accessibility "$BUNDLE_ID" || true

echo "Done. Reopen ShotMark and grant Screen Recording permission again."
