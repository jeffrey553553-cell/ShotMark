#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORT_DIR="$ROOT_DIR/dist/regression"
TIMESTAMP="$(date '+%Y-%m-%d_%H.%M.%S')"
REPORT_PATH="$REPORT_DIR/core-regression-$TIMESTAMP.md"

cd "$ROOT_DIR"
mkdir -p "$REPORT_DIR"

run_step() {
  local title="$1"
  shift
  echo "== $title =="
  "$@"
  echo
}

verify_dmg_install_layout() {
  (
    set -euo pipefail
    local mount_dir
    mount_dir="$(mktemp -d "${TMPDIR:-/tmp}/shotmark-dmg-mount.XXXXXX")"
    cleanup() {
      hdiutil detach "$mount_dir" -quiet >/dev/null 2>&1 || true
      rmdir "$mount_dir" >/dev/null 2>&1 || true
    }
    trap cleanup EXIT

    hdiutil attach "$ROOT_DIR/dist/ShotMark.dmg" -nobrowse -readonly -mountpoint "$mount_dir" >/dev/null
    [[ -d "$mount_dir/ShotMark.app" ]]
    [[ -L "$mount_dir/Applications" ]]
    [[ "$(readlink "$mount_dir/Applications")" == "/Applications" ]]
  )
}

run_step "Swift debug build" swift build --disable-sandbox
run_step "Release app build" "$ROOT_DIR/scripts/build_app.sh"
run_step "Code signature verify" codesign --verify --deep --verbose=2 "$ROOT_DIR/dist/ShotMark.app"
run_step "DMG package" "$ROOT_DIR/scripts/package_dmg.sh"
run_step "DMG verify" hdiutil verify "$ROOT_DIR/dist/ShotMark.dmg"
run_step "DMG install layout verify" verify_dmg_install_layout
run_step "P1 editing and recording static checks" bash -c '
  set -euo pipefail
  rg -q "case rectangle, arrow, number, text, mosaic, ocr, pin, longScreenshot, record, recordQuality, undo, redo, delete" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "private func undoEdit\\(" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "private func redoEdit\\(" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "private func deleteSelectedAnnotation\\(" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "case numberMarker\\(center: CGPoint, number: Int, color: NSColor, markerSize: CGFloat\\)" Sources/ShotMark/Models.swift
  rg -q "private var numberMarkerStyle" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "return \"5\"" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "return \"6\"" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "return \"7\"" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "return \"8\"" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "return \"9\"" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "requestMicrophoneAccess" Sources/ShotMark/PermissionService.swift
  rg -q "openMicrophoneSettings" Sources/ShotMark/PermissionService.swift
  rg -q "captureMicrophone = audioMode.capturesMicrophone" Sources/ShotMark/VideoRecordingService.swift
  rg -q "acceptsFirstMouse" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "windowUnderCurrentMouse" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "convert\\(event\\.locationInWindow, from: nil\\)" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "intersection\\(targetScreen\\.frame\\)" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "ToastContentView" Sources/ShotMark/ToastWindowController.swift
  rg -q "NSColor\\(calibratedWhite: 0\\.06, alpha: 0\\.88\\)" Sources/ShotMark/ToastWindowController.swift
  rg -q "installEscapeKeyMonitor" Sources/ShotMark/OCRResultPanelController.swift
  rg -q "event.keyCode == 53" Sources/ShotMark/OCRResultPanelController.swift
  rg -q "onClose" Sources/ShotMark/OCRResultPanelController.swift
  rg -q "ScreenSnapshot" Sources/ShotMark/Models.swift
  rg -q "captureSnapshots" Sources/ShotMark/CaptureService.swift
  rg -q "frozenSnapshot" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "frozenCapture" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "captureFrozenScreensAndShowOverlay" Sources/ShotMark/ScreenshotCoordinator.swift
  rg -q "LongScreenshotHotKeyService" Sources/ShotMark/LongScreenshotSessionController.swift
  rg -q "kVK_Escape" Sources/ShotMark/LongScreenshotSessionController.swift
  rg -q "primaryScrollDirectionSign" Sources/ShotMark/LongScreenshotSessionController.swift
  rg -q "reverseVerticalOverlap" Sources/ShotMark/LongScreenshotSessionController.swift
  rg -q "directionalConfidenceRatio" Sources/ShotMark/LongScreenshotSessionController.swift
  rg -q "primaryStitchDirection" Sources/ShotMark/LongScreenshotSessionController.swift
  rg -q "case upward" Sources/ShotMark/LongScreenshotSessionController.swift
  rg -q "stitchedSegments.insert\\(segment, at: 0\\)" Sources/ShotMark/LongScreenshotSessionController.swift
'

SCREEN_INFO="$(system_profiler SPDisplaysDataType 2>/dev/null || true)"
DISPLAY_COUNT="$(awk '/Resolution:/{count++} END{print count+0}' <<<"$SCREEN_INFO")"
RETINA_COUNT="$(awk '/Retina: Yes/{count++} END{print count+0}' <<<"$SCREEN_INFO")"
SIGNATURE_SUMMARY="$(codesign -dv --verbose=4 "$ROOT_DIR/dist/ShotMark.app" 2>&1 || true)"

cat >"$REPORT_PATH" <<REPORT
# ShotMark Core Regression Report

Generated: $TIMESTAMP

## Automated Checks

- Swift debug build: PASS
- Release app build: PASS
- Code signature verify: PASS
- DMG package: PASS
- DMG verify: PASS
- DMG install layout verify: PASS
- P1 editing and recording static checks: PASS

## Environment Snapshot

- Display count detected: $DISPLAY_COUNT
- Retina displays detected: $RETINA_COUNT
- App: \`$ROOT_DIR/dist/ShotMark.app\`
- DMG: \`$ROOT_DIR/dist/ShotMark.dmg\`

## Signature Snapshot

\`\`\`text
$SIGNATURE_SUMMARY
\`\`\`

## Manual Core Flow Matrix

Before testing, open the freshly built app:

\`\`\`bash
open "$ROOT_DIR/dist/ShotMark.app"
\`\`\`

Mark each item PASS/FAIL after running it.

| Area | Case | Expected | Result |
| --- | --- | --- | --- |
| Permissions | Status bar -> permission rows | Screen Recording and Microphone show allowed after permission is granted; if not, menu offers settings and restart/quit path | |
| Single screen | Option+A on built-in/main screen | Selection overlay appears; selection can move and resize | |
| Immediate drag | Press Option+A, then drag without a focus click | Selection starts on the first mouse down after the shortcut | |
| Frozen frame | Play a video, press Option+A, then select/save later | Overlay and final PNG keep the frame from screenshot entry instead of later video frames | |
| External screen | Option+A with cursor on external screen | Overlay appears on target display; capture area matches selected display | |
| Retina | Capture text/icons on Retina screen | Output PNG is sharp and selection bounds match pixels | |
| Full screen | Select nearly entire screen | Toolbar stays visible and final image has no blue selection frame | |
| Small area | Select small area around text | Toolbar stays usable; output only contains selected area | |
| Save | Press Space after annotations | PNG saved to Downloads with annotations applied | |
| Copy | Press Cmd+C or Enter | Clipboard image pastes into Preview/Notes/Chat correctly | |
| Pin | Click pin icon | Pinned image floats above other windows; close button removes it | |
| OCR | Click OCR on Chinese+English text | OCR panel shows recognized text; copy all works | |
| OCR | Open OCR panel and press Esc | OCR panel closes and screenshot/editor focus returns | |
| Toast | Save or copy in light mode | Success toast remains readable with dark pill, check icon and white text | |
| Recording | Select area -> record -> choose quality | Recording overlay/timer appears; Stop saves MP4 to Downloads | |
| Recording audio | Record with Silent/System/Microphone/System+Microphone | Selected audio mode is captured; microphone modes prompt clearly when permission is missing | |
| Recording stop | Press Option+A while recording | Recording stops and saved file plays | |
| Mosaic | Draw mosaic over text | Text under the drawn area is blurred, no visible border is drawn | |
| Long screenshot | Start long screenshot and press Esc | Session cancels and returns without saving/copying | |
| Long screenshot | Scroll down, then scroll upward repeatedly | Preview does not keep appending reversed/duplicate content | |
| Long screenshot | Start near page bottom, scroll upward | New upper content is prepended above the starting frame | |
| Edit | Draw rectangle/arrow/text/mosaic, then Cmd+Z/Cmd+Shift+Z | Undo and redo restore the previous annotation state | |
| Edit | Select an annotation and press Delete | The selected annotation is removed only after selection | |
| Edit | Select rectangle/mosaic and drag corner handles | The object resizes without moving unrelated annotations | |
| Edit | Select arrow, increase thickness, then draw | Arrow line and arrowhead remain visible at thick sizes | |
| Edit | Select arrow and drag endpoint handles | Arrow start/end handles move independently | |
| Edit | Select number marker and adjust style panel | Marker size/color/opacity update and export correctly | |
| Edit | Select mosaic and adjust style panel strength | Mosaic blur strength changes; no color controls are shown | |

## Notes

- If Screen Recording was just enabled in System Settings, quit ShotMark from the status bar and reopen it before marking permission failures.
- For external screen testing, run the same small-area save/copy flow once on each connected display.
REPORT

echo "Regression report written to:"
echo "$REPORT_PATH"
