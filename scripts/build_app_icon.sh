#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_PNG="$ROOT_DIR/Resources/ShotMarkIconSource.png"
OUTPUT_PNG="$ROOT_DIR/Resources/ShotMarkIcon.png"
OUTPUT_ICNS="$ROOT_DIR/Resources/ShotMark.icns"
ICONSET_DIR="$(mktemp -d)/ShotMark.iconset"

cleanup() {
  rm -rf "${ICONSET_DIR:h}"
}
trap cleanup EXIT

swift "$ROOT_DIR/scripts/process_app_icon.swift" "$SOURCE_PNG" "$OUTPUT_PNG"
mkdir -p "$ICONSET_DIR"

for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$OUTPUT_PNG" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
  double_size=$((size * 2))
  sips -z "$double_size" "$double_size" "$OUTPUT_PNG" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET_DIR" -o "$OUTPUT_ICNS"
echo "Updated $OUTPUT_PNG"
echo "Updated $OUTPUT_ICNS"
