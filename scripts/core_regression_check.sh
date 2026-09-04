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
run_step "Swift tests" swift test --disable-sandbox
run_step "Rendered long screenshot benchmark" "$ROOT_DIR/scripts/run_longshot_benchmark.sh"
run_step "Release app build" "$ROOT_DIR/scripts/build_app.sh"
run_step "Code signature verify" codesign --verify --deep --verbose=2 "$ROOT_DIR/dist/ShotMark.app"
run_step "Privacy metadata verify" env ROOT_DIR="$ROOT_DIR" bash -c '
  set -euo pipefail
  INFO="$ROOT_DIR/dist/ShotMark.app/Contents/Info.plist"
  [[ -n "$(plutil -extract NSMicrophoneUsageDescription raw -o - "$INFO")" ]]
  codesign -dv --verbose=4 "$ROOT_DIR/dist/ShotMark.app" 2>&1 | rg -q "flags=.*runtime"
'
run_step "Permission reset coverage verify" env ROOT_DIR="$ROOT_DIR" bash -c '
  set -euo pipefail
  rg -q "tccutil reset ScreenCapture" "$ROOT_DIR/scripts/reset_permissions.sh"
  rg -q "tccutil reset Accessibility" "$ROOT_DIR/scripts/reset_permissions.sh"
  rg -q "tccutil reset Microphone" "$ROOT_DIR/scripts/reset_permissions.sh"
'
run_step "Microphone entitlement verify" env ROOT_DIR="$ROOT_DIR" bash -c '
  set -euo pipefail
  ENTITLEMENTS="$(codesign -d --entitlements :- "$ROOT_DIR/dist/ShotMark.app" 2>/dev/null)"
  plutil -p - <<<"$ENTITLEMENTS" | rg -q "\"com.apple.security.device.audio-input\" => 1"
'
run_step "App icon verify" env ROOT_DIR="$ROOT_DIR" bash -c '
  set -euo pipefail
  [[ "$(plutil -extract CFBundleIconFile raw -o - "$ROOT_DIR/dist/ShotMark.app/Contents/Info.plist")" == "ShotMark" ]]
  [[ -s "$ROOT_DIR/dist/ShotMark.app/Contents/Resources/ShotMark.icns" ]]
  [[ -s "$ROOT_DIR/dist/ShotMark.app/Contents/Resources/THIRD_PARTY_NOTICES.md" ]]
  rg -q "alpha corners 0 0 0 0" <(
    swift - <<'"'"'SWIFT'"'"'
import AppKit
let image = NSImage(contentsOf: URL(fileURLWithPath: "Resources/ShotMarkIcon.png"))!
let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let width = cg.width
let height = cg.height
let bytesPerPixel = 4
let bytesPerRow = width * bytesPerPixel
var data = [UInt8](repeating: 0, count: height * bytesPerRow)
let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
func alpha(_ x: Int, _ y: Int) -> UInt8 { data[y * bytesPerRow + x * bytesPerPixel + 3] }
print("alpha corners \(alpha(0, 0)) \(alpha(width - 1, 0)) \(alpha(0, height - 1)) \(alpha(width - 1, height - 1))")
SWIFT
  )
'
run_step "DMG package" "$ROOT_DIR/scripts/package_dmg.sh"
run_step "DMG verify" hdiutil verify "$ROOT_DIR/dist/ShotMark.dmg"
run_step "DMG install layout verify" verify_dmg_install_layout
run_step "P1 editing and recording static checks" bash -c '
  set -euo pipefail
  rg -q "case callout, rectangle, ellipse, arrow, pen, highlighter, number, text, mosaic, ocr, pin, longScreenshot, record, more, undo, redo, delete" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "static let moreTools: \[OverlayButton\] = \[\.ellipse, \.pen, \.highlighter\]" Sources/ShotMark/SelectionOverlayController.swift
  ! rg -q "VideoQualityPreset|720p|1080p|2K|recordQuality" Sources/ShotMark
  rg -q "nativeOutputPixelSize" Sources/ShotMark/VideoRecordingService.swift
  rg -q "showMouseClicks = options.showsMouseClicks" Sources/ShotMark/VideoRecordingService.swift
  rg -q "VideoSegmentMerger.merge" Sources/ShotMark/VideoRecordingService.swift
  rg -q "removeRecordingOutput" Sources/ShotMark/VideoRecordingService.swift
  rg -q "case paused" Sources/ShotMark/Models.swift
  rg -q "PinnedScreenshotGeometry" Sources/ShotMark/PinnedScreenshotWindowController.swift
  rg -q "onPinnedCountChanged" Sources/ShotMark/ScreenshotCoordinator.swift Sources/ShotMark/AppDelegate.swift
  rg -q "passThroughTimer" Sources/ShotMark/PinnedScreenshotWindowController.swift
  rg -q "case callout" Sources/ShotMark/Models.swift
  rg -q "case ellipse" Sources/ShotMark/Models.swift
  rg -q "case freehand" Sources/ShotMark/Models.swift
  rg -q "case highlighter" Sources/ShotMark/Models.swift
  rg -q "AnnotationPathGeometry" Sources/ShotMark/AnnotationDrawing.swift Sources/ShotMark/SelectionOverlayController.swift Sources/ShotMark/AnnotationCanvasView.swift
  rg -q "beginTransparencyLayer" Sources/ShotMark/AnnotationDrawing.swift
  rg -q "drawingCallout" Sources/ShotMark/SelectionOverlayController.swift Sources/ShotMark/AnnotationCanvasView.swift
  rg -q "text.bubble" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "beginCalloutTextEdit" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "addCallout" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "case \\.callout" Sources/ShotMark/AnnotationDrawing.swift Sources/ShotMark/SelectionOverlayController.swift Sources/ShotMark/AnnotationCanvasView.swift
  rg -q "AnnotationDrawing.draw\\(state.annotations.filter" Sources/ShotMark/ExportService.swift
  rg -Uq "case \\.callout:\\n[[:space:]]*return \"1\"" Sources/ShotMark/SelectionOverlayController.swift
  rg -Uq "case \\.rectangle:\\n[[:space:]]*return \"2\"" Sources/ShotMark/SelectionOverlayController.swift
  rg -Uq "case \\.arrow:\\n[[:space:]]*return \"3\"" Sources/ShotMark/SelectionOverlayController.swift
  rg -Uq "case \\.number:\\n[[:space:]]*return \"4\"" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "tailHalfWidth" Sources/ShotMark/AnnotationDrawing.swift
  rg -q "neckHalfWidth" Sources/ShotMark/AnnotationDrawing.swift
  rg -q "let placementGap: CGFloat = 84" Sources/ShotMark/AnnotationGeometry.swift
  rg -q "textClearance: CGFloat = 24" Sources/ShotMark/AnnotationGeometry.swift
  rg -q "snappedLineEndpoint\\(from: arrowEnd" Sources/ShotMark/SelectionOverlayController.swift Sources/ShotMark/AnnotationCanvasView.swift
  rg -q "private func undoEdit\\(" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "private func redoEdit\\(" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "private func deleteSelectedAnnotation\\(" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "appearance: NumberMarkerAppearance" Sources/ShotMark/Models.swift
  rg -q "private var numberMarkerStyle" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "var defaultShortcutKey: String?" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "testNumericShortcutButtonsComeFirstInOneThroughNineOrder" Tests/ShotMarkTests/ToolbarOrderingTests.swift
  rg -q "requestMicrophoneAccess" Sources/ShotMark/PermissionService.swift
  rg -q "openMicrophoneSettings" Sources/ShotMark/PermissionService.swift
  rg -q "captureMicrophone = options.audioMode.capturesMicrophone" Sources/ShotMark/VideoRecordingService.swift
  rg -q "window.sharingType = .none" Sources/ShotMark/RecordingRegionOverlayController.swift
  rg -q "acceptsFirstMouse" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "activeSelectionView" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "setInteractionLocked" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "onInteractionStarted" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "installInteractionEventMonitor" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "matching: \\[\\.leftMouseDown, \\.leftMouseDragged, \\.leftMouseUp\\]" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "SelectionMagnifier" Sources/ShotMark/SelectionPrecisionSupport.swift Sources/ShotMark/SelectionOverlayController.swift
  rg -q "pixelColorHex" Sources/ShotMark/SelectionPrecisionSupport.swift
  rg -q "handlePrecisionArrowKey" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "SelectionPrecisionGeometry" Sources/ShotMark/SelectionPrecisionSupport.swift Tests/ShotMarkTests/SelectionPrecisionSupportTests.swift
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
  rg -q "lastScrollDirectionSign" Sources/ShotMark/LongScreenshotSessionController.swift
  rg -q "prepareForScrollDirectionChange" Sources/ShotMark/LongScreenshotSessionController.swift
  rg -q "stitchDirectionByScrollSign" Sources/ShotMark/LongScreenshotSessionController.swift
  rg -q "pendingExpectedScrollDeltaPixels" Sources/ShotMark/LongScreenshotSessionController.swift
  rg -q "LongScreenshotFrameSource" Sources/ShotMark/LongScreenshotFrameSource.swift Sources/ShotMark/LongScreenshotSessionController.swift
  rg -q "LongScreenshotFrameRing" Sources/ShotMark/LongScreenshotFrameRing.swift Sources/ShotMark/LongScreenshotSessionController.swift
  rg -q "requiredConsecutiveFrames: Int = 3" Sources/ShotMark/LongScreenshotFrameRing.swift
  rg -q "sampledSharpness" Sources/ShotMark/LongScreenshotFrameRing.swift Tests/ShotMarkTests/LongScreenshotFrameRingTests.swift
  rg -q "sharpestRecentFrame" Sources/ShotMark/LongScreenshotFrameRing.swift Sources/ShotMark/LongScreenshotSessionController.swift Tests/ShotMarkTests/LongScreenshotFrameRingTests.swift
  rg -q "LongScreenshotAutomaticScrollPolicy.nextStep" Sources/ShotMark/LongScreenshotSessionController.swift Tests/ShotMarkTests/LongScreenshotRetryPolicyTests.swift
  rg -q "SCStreamOutput" Sources/ShotMark/LongScreenshotFrameSource.swift
  rg -q "latestFrame\\(after: sequenceNumber\\)" Sources/ShotMark/LongScreenshotSessionController.swift
  rg -q "frameRing\\.markCommitted" Sources/ShotMark/LongScreenshotSessionController.swift
  rg -q "SHOTMARK_LONGSHOT_V1" Sources/ShotMark/LongScreenshotSessionController.swift
  rg -q "startFrameSourceIfNeeded" Sources/ShotMark/LongScreenshotSessionController.swift
  rg -q "frameSource\\.stop" Sources/ShotMark/LongScreenshotSessionController.swift
  rg -q "LongScreenshotStitcher" Sources/ShotMark/LongScreenshotStitcher.swift Sources/ShotMark/LongScreenshotSessionController.swift
  rg -q "ContentSlice" Sources/ShotMark/LongScreenshotStitcher.swift
  rg -q "croppedRows" Sources/ShotMark/LongScreenshotStitcher.swift
  rg -q "retainedContentPixelBytes" Sources/ShotMark/LongScreenshotStitcher.swift Tests/ShotMarkTests/LongScreenshotStitcherTests.swift
  rg -q "LongScreenshotPreviewPolicy.minimumRenderInterval" Sources/ShotMark/LongScreenshotSessionController.swift Tests/ShotMarkTests/LongScreenshotRetryPolicyTests.swift
  rg -q "LongScreenshotCapacityPolicy" Sources/ShotMark/LongScreenshotCapacityPolicy.swift Sources/ShotMark/LongScreenshotStitcher.swift Tests/ShotMarkTests/LongScreenshotCapacityPolicyTests.swift
  rg -q "reachedMaximumHeight" Sources/ShotMark/LongScreenshotStitcher.swift Sources/ShotMark/LongScreenshotSessionController.swift Tests/ShotMarkTests/LongScreenshotStitcherTests.swift
  rg -q "LongScreenshotQualityReportStore" Sources/ShotMark/LongScreenshotQualityReport.swift Sources/ShotMark/SettingsWindowController.swift Tests/ShotMarkTests/LongScreenshotQualityReportTests.swift
  rg -q "consecutiveAlignmentFailureCount" Sources/ShotMark/LongScreenshotSessionController.swift Tests/ShotMarkTests/LongScreenshotQualityReportTests.swift
  rg -q "isSessionActive" Sources/ShotMark/LongScreenshotSessionController.swift
  rg -q "UpdateCheckService" Sources/ShotMark/UpdateCheckService.swift Sources/ShotMark/AppDelegate.swift Tests/ShotMarkTests/UpdateCheckServiceTests.swift
  rg -q "automaticallyChecksForUpdates" Sources/ShotMark/Models.swift Sources/ShotMark/SettingsWindowController.swift Tests/ShotMarkTests/UpdateCheckServiceTests.swift
  rg -q "SHOTMARK_RELEASE_MODE" scripts/build_app.sh scripts/package_dmg.sh scripts/release_readiness.sh scripts/publish_public_release.sh
  rg -q '"nested", "lowtexture", "sticky-swap"' scripts/generate_longshot_benchmark.mjs
  rg -q "detectStaticBand" Sources/ShotMark/LongScreenshotStitcher.swift
  rg -q "detectStaticSideBand" Sources/ShotMark/LongScreenshotStitcher.swift
  rg -q "matchingColumnBounds" Sources/ShotMark/LongScreenshotStitcher.swift
  rg -q "case upward" Sources/ShotMark/LongScreenshotStitcher.swift
  rg -q "contentSlices.insert\\(slice, at: 0\\)" Sources/ShotMark/LongScreenshotStitcher.swift
  rg -q "ignoredAlignmentFailed" Sources/ShotMark/LongScreenshotStitcher.swift
  rg -q "isAmbiguous" Sources/ShotMark/LongScreenshotStitcher.swift
  rg -q "currentViewportStart" Sources/ShotMark/LongScreenshotStitcher.swift
  rg -q "coveredStart" Sources/ShotMark/LongScreenshotStitcher.swift
  rg -q "coveredEnd" Sources/ShotMark/LongScreenshotStitcher.swift
  rg -q "ignoredCoveredContent" Sources/ShotMark/LongScreenshotStitcher.swift Sources/ShotMark/LongScreenshotSessionController.swift
  rg -q "VNTranslationalImageRegistrationRequest" Sources/ShotMark/LongScreenshotStitcher.swift
  rg -q "estimateVisionAlignment" Sources/ShotMark/LongScreenshotStitcher.swift
  rg -q "testVisionRecoveryHandlesMisleadingScrollDistance" Tests/ShotMarkTests/LongScreenshotStitcherTests.swift
  rg -q "static let defaultShortcut" Sources/ShotMark/GlobalShortcut.swift
  rg -q "\\.defaultShortcut" Sources/ShotMark/Models.swift Sources/ShotMark/SettingsWindowController.swift Sources/ShotMark/AppDelegate.swift
  rg -q "shotmark.captureShortcut" Sources/ShotMark/Models.swift
  rg -q "func register\\(shortcut: GlobalShortcut\\)" Sources/ShotMark/HotKeyService.swift
  rg -q "RegisterEventHotKey\\(" Sources/ShotMark/HotKeyService.swift
  rg -q "startShortcutRecording" Sources/ShotMark/SettingsWindowController.swift
  rg -q "stopShortcutRecording\\(reactivateHotKey:" Sources/ShotMark/SettingsWindowController.swift
  rg -q "setShortcutRecorderActive" Sources/ShotMark/AppDelegate.swift
  rg -q "recordingMenuTitle" Sources/ShotMark/AppDelegate.swift
  rg -q "activeTextTopY" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "currentTextAnnotationOrigin" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "committedValue" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "textInputPadding" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "textContainerInset = NSSize" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "widthTracksTextView = false" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "containerSize = CGSize" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "AnnotationGeometry.contains" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "AnnotationGeometry.contains" Sources/ShotMark/AnnotationCanvasView.swift
  rg -q "constrainedRect" Sources/ShotMark/AnnotationPathGeometry.swift Sources/ShotMark/SelectionOverlayController.swift Sources/ShotMark/AnnotationCanvasView.swift
  rg -q "aspectConstrainedRect" Sources/ShotMark/AnnotationPathGeometry.swift Sources/ShotMark/SelectionOverlayController.swift Sources/ShotMark/AnnotationCanvasView.swift
  rg -q "drawAnnotationMeasurementBadge" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "AnnotationGeometry.calloutLayout" Sources/ShotMark/SelectionOverlayController.swift Sources/ShotMark/AnnotationCanvasView.swift
  rg -q "clampedTranslation" Sources/ShotMark/AnnotationGeometry.swift
  rg -q "testConstrainedRectSupportsSquareAndCenterDrawing" Tests/ShotMarkTests/AnnotationPathGeometryTests.swift
  rg -q "testThickArrowHeadAndShaftAreSelectable" Tests/ShotMarkTests/AnnotationGeometryTests.swift
  rg -q "testBidirectionalMergedPixelsContainEveryContentRowExactlyOnce" Tests/ShotMarkTests/LongScreenshotStitcherTests.swift
  rg -q "testCalloutLayoutKeepsTextVisibleAndArrowAttached" Tests/ShotMarkTests/AnnotationGeometryTests.swift
  rg -q "testCalloutHitRegionsKeepTargetArrowAndTextIndependent" Tests/ShotMarkTests/AnnotationGeometryTests.swift
  rg -q "testMovingCalloutTargetLeavesTextSideFixedAndReattachesArrowHead" Tests/ShotMarkTests/AnnotationGeometryTests.swift
  rg -q "testMovingCalloutTextKeepsArrowTailBoundAndStopsAtCanvasEdge" Tests/ShotMarkTests/AnnotationGeometryTests.swift
  rg -q "testCalloutArrowHeadSnapsNearTargetAndMovesFreelyOutsideSnapRange" Tests/ShotMarkTests/AnnotationGeometryTests.swift
  rg -q "testMovingCalloutTargetPreservesFreelyPositionedArrowHead" Tests/ShotMarkTests/AnnotationGeometryTests.swift
  rg -q "movingCalloutTarget" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "movingCalloutText" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "activeCalloutOriginalAnnotation" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "annotationsForDrawing" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "calloutLineWidth" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "AnnotationInteractionPolicy.pointerDownResolution" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "testCalloutTextCommitContinuesTheSamePointerInteraction" Tests/ShotMarkTests/AnnotationGeometryTests.swift
  rg -q "testNumericShortcutButtonsComeFirstInOneThroughNineOrder" Tests/ShotMarkTests/ToolbarOrderingTests.swift
  rg -q "testToolbarShortcutPreferencesSurviveSettingsRecreation" Tests/ShotMarkTests/ToolbarOrderingTests.swift
  rg -q "toolbarShortcutPreferences" Sources/ShotMark/Models.swift Sources/ShotMark/SelectionOverlayController.swift
  rg -q "case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left" Sources/ShotMark/SelectionOverlayController.swift
  ! rg -q "value\\.isEmpty, calloutWasJustCreated" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "testTextEditorExpandsLeftWhenItReachesSelectionEdge" Tests/ShotMarkTests/AnnotationGeometryTests.swift
  rg -q "testAnnotationShowcaseRendersVisiblePixels" Tests/ShotMarkTests/AnnotationRenderingTests.swift
  rg -q "NumberMarkerAppearance" Sources/ShotMark/Models.swift Sources/ShotMark/SelectionOverlayController.swift
  rg -q "testStrengthProducesContinuousIncreasingObscuration" Tests/ShotMarkTests/MosaicRendererTests.swift
  rg -q "LongScreenshotRetryPolicy" Sources/ShotMark/LongScreenshotSessionController.swift
  rg -q "testDefaultRetryDelaysIncreaseToAllowDynamicContentToSettle" Tests/ShotMarkTests/LongScreenshotRetryPolicyTests.swift
  rg -q "WindowDetectionService" Sources/ShotMark/WindowDetectionService.swift Sources/ShotMark/SelectionOverlayController.swift
  rg -q "SCShareableContent" Sources/ShotMark/WindowDetectionService.swift
  rg -q "CGWindowListCopyWindowInfo" Sources/ShotMark/WindowDetectionService.swift
  rg -q "AXUIElementCreateApplication" Sources/ShotMark/WindowDetectionService.swift
  rg -q "CGDisplayBounds" Sources/ShotMark/WindowDetectionService.swift
  rg -q "SHOTMARK_WINDOW_DEBUG" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "pendingInitialSelection" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "initialSelectionDragThreshold" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "updateHoveredWindowCandidate" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "selectWindowCandidate" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "drawWindowCandidateHover" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "drawWindowCandidateDebugOverlay" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "点击窗口快速选择" Sources/ShotMark/SelectionOverlayController.swift
  rg -q "窗口识别校准" Sources/ShotMark/AppDelegate.swift Sources/ShotMark/SettingsWindowController.swift
'

run_step "Fixed PNG export static checks" bash -c '
  rg -q "AppSettings.defaultSaveDirectory" Sources/ShotMark/ExportService.swift
  rg -q "UTType.png.identifier" Sources/ShotMark/ExportService.swift
  rg -q "exportPNGData" Sources/ShotMark/ScreenshotCoordinator.swift Sources/ShotMark/EditorWindowController.swift Sources/ShotMark/PinnedScreenshotWindowController.swift
  ! rg -q "CaptureHistory|QuickAccess|CaptureDrag|CaptureSharing|ImageExportFormat|ExportNaming|PostCaptureActions" Sources Tests
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
- Swift tests: PASS
- Rendered long screenshot benchmark: PASS
- Release app build: PASS
- Code signature verify: PASS
- Privacy metadata verify: PASS
- Permission reset coverage verify: PASS
- Microphone entitlement verify: PASS
- App icon verify: PASS
- DMG package: PASS
- DMG verify: PASS
- DMG install layout verify: PASS
- P1 editing and recording static checks: PASS
- Fixed PNG export static checks: PASS

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
| Settings | Change screenshot shortcut, then restore default | New shortcut triggers capture; occupied/reserved shortcuts show an error; default returns to Option+A after restore | |
| Single screen | Configured screenshot shortcut on built-in/main screen | Selection overlay appears; selection can move and resize | |
| Window pick | Hover a visible app window before dragging | Window is highlighted with a clear click-to-select hint | |
| Window pick | Click a hovered app window | Selection snaps to that window and remains editable with the normal toolbar | |
| Window pick | Press down on a window, then drag more than a few pixels | Free-form rectangle selection starts instead of selecting the window | |
| Window pick | Hover and click windows on each external display | Highlight and final selection align with the window on that display | |
| Window pick | Launch with \`SHOTMARK_WINDOW_DEBUG=1\` | Candidate window borders and owner/source labels appear for diagnosis | |
| Immediate drag | Press configured shortcut, then drag without a focus click | Selection starts on the first mouse down after the shortcut | |
| Frozen frame | Play a video, press configured shortcut, then select/save later | Overlay and final PNG keep the frame from screenshot entry instead of later video frames | |
| External screen | Configured shortcut with cursor on external screen | Overlay appears on target display; capture area matches selected display | |
| Multiple screens | Finish a selection on one display, then click or drag on another display | The first selection remains the only active selection; other displays stay dimmed and do not create a second selection | |
| Retina | Capture text/icons on Retina screen | Output PNG is sharp and selection bounds match pixels | |
| Precision | Drag or resize a selection | Pixel magnifier follows the active edge and stays within the current display | |
| Precision | Hold Command and move/scroll | Magnifier shows pixel coordinates/color; scrolling changes zoom without moving the selection | |
| Precision | Press arrow keys, then Shift+arrow keys | Selection moves by one physical pixel; Shift resizes by one physical pixel | |
| Precision | Select an annotation and press arrow keys | Annotation moves by one physical pixel; Shift moves it by ten physical pixels | |
| Precision | Draw selection/rectangle/ellipse/mosaic/comment with Shift, Option, then Shift+Option | Shift constrains a square/circle, Option draws from center, combined mode preserves both behaviors at screen edges | |
| Precision | Resize a selection or resizable annotation corner while holding Shift | Original aspect ratio is preserved and the object remains inside the capture bounds | |
| Precision | Draw an arrow or move one endpoint while holding Shift | Direction snaps in 45-degree increments; the live length/angle badge follows without covering the active handle | |
| Full screen | Select nearly entire screen | Toolbar stays visible and final image has no blue selection frame | |
| Small area | Select small area around text | Toolbar stays usable; output only contains selected area | |
| Save | Press Space after annotations | A PNG with annotations is saved to Downloads | |
| Copy | Press Cmd+C or Enter | Clipboard image pastes into Preview/Notes/Chat correctly | |
| Pin | Click pin icon, then scroll/pinch and right-click | Pinned image keeps its aspect ratio; zoom, opacity, copy/save and close work | |
| Pin lock | Lock a pinned image, then move the pointer away and back | Image area passes mouse events through; lock control remains available to unlock | |
| Multiple pins | Create two pins, then use the status menu | Count is correct; Show All and Close All affect every pin | |
| OCR | Click OCR on Chinese+English text | OCR panel shows recognized text; copy all works | |
| OCR | Open OCR panel and press Esc | OCR panel closes and screenshot/editor focus returns | |
| Toast | Save or copy in light mode | Success toast remains readable with dark pill, check icon and white text | |
| Recording | Select area -> record -> choose audio mode | Recording uses the selection's native pixel size; overlay/timer appears; Stop saves MP4 to Downloads without red frame/overlay in the video | |
| Recording audio | Record with Silent/System/Microphone/System+Microphone | Selected audio mode is captured; microphone modes prompt clearly when permission is missing | |
| Recording click highlight | Enable Show Mouse Clicks, then click inside the region | System cursor click circles appear in the saved MP4 | |
| Recording pause | Pause, wait, resume, then stop | Timer freezes while paused; paused time is absent; all recorded segments merge into one playable MP4 | |
| Recording stop | Press configured screenshot shortcut while recording | Recording stops and saved file plays | |
| Mosaic | Draw mosaic over text | Text under the drawn area is blurred, no visible border is drawn | |
| Long screenshot | Start long screenshot and press Esc | Session cancels and returns without saving/copying | |
| Long screenshot | Click Auto Down without Accessibility permission | Capture pauses while System Settings is visible; granting permission does not auto-start; returning to the original page and clicking Auto Down starts scrolling | |
| Long screenshot | Move and click the mouse during automatic scrolling | Pointer remains under user control; the original page keeps scrolling and switching to another app stops automatic scrolling | |
| Long screenshot | Scroll down, then scroll upward repeatedly | Preview does not keep appending reversed/duplicate content | |
| Long screenshot | Reverse direction through already captured content | Preview height stays unchanged while traversing covered content and resumes only after reaching new content | |
| Long screenshot | Start near page bottom, scroll upward | New upper content is prepended above the starting frame | |
| Long screenshot | Scroll through a lazy-loading or animated page | Automatic retries preserve direction/distance context and recover after the page settles | |
| Long screenshot | Auto-scroll through text while animations or loading placeholders are active | Preview only commits a settled sharp frame; moving or blurred intermediate frames do not create broken seams | |
| Long screenshot | Continuously scroll by trackpad without pausing | Preview keeps extending during the gesture using sharp recent frames, then performs a stable trailing capture after scrolling stops | |
| Long screenshot | Auto-scroll through short and tall viewports | Scroll distance adapts to accepted content and confidence without large jumps or repeatedly tiny steps | |
| Long screenshot | Capture down, then beyond the original viewport upward | Every content row appears once in the final image, with no duplicated or missing seam pixels | |
| Long screenshot | Continue scrolling until the safe capacity limit | A warning appears before the limit; capture stops at the limit and the current image can still be saved or copied | |
| Long screenshot | Scroll too far until alignment retries are exhausted | The UI gives a directional rollback instruction; the current result remains exportable | |
| Long screenshot | Cancel while a frame capture is still in flight | The late frame is ignored and no second completion or error appears | |
| Settings | Complete several long screenshots, then copy and clear diagnostics | Summary contains only dimensions, timings and quality counts; clearing removes all retained reports | |
| Updates | Check with the latest version installed | A clear up-to-date message appears and no browser page opens | |
| Updates | Check while a newer stable GitHub Release exists | The version prompt appears and opens only the official Release page after confirmation | |
| Updates | Disable automatic checks, relaunch, then re-enable | The preference persists; enabled checks run no more than once per 24 hours | |
| Updates | Disconnect the network and check manually | A concise retryable error appears without affecting screenshot features | |
| Edit | Draw rectangle/arrow/text/mosaic, then Cmd+Z/Cmd+Shift+Z | Undo and redo restore the previous annotation state | |
| Edit | Select an annotation and press Delete | The selected annotation is removed only after selection | |
| Edit | Select rectangle/mosaic and drag corner handles | The object resizes without moving unrelated annotations | |
| Edit | Select arrow, increase thickness, then draw | Arrow line and arrowhead remain visible at thick sizes | |
| Edit | Select arrow and drag endpoint handles | Arrow start/end handles move independently | |
| Edit | Select number marker and adjust style panel | Filled/outlined/light styles plus size/color/opacity update and export correctly | |
| Toolbar | Start a new capture and scan the toolbar from left to right | Numeric defaults appear first in 1 through 9 order, then E/P/H/T, then edit/export actions | |
| Toolbar | Change a tool shortcut, cancel capture, quit and reopen ShotMark, then capture again | The custom shortcut still triggers the same tool and its icon remains in the fixed default position | |
| Toolbar | Clear a tool shortcut, quit and reopen ShotMark | The cleared shortcut remains unset and no other tool silently takes it | |
| Edit | Click comment tool or press 1, then drag a target box | A target rectangle, arrow and editable text comment are created as one annotation group | |
| Edit | Immediately drag the comment target, a resize handle or an arrow endpoint while the text cursor is active | The first drag works directly; it is not consumed by ending text input and the empty comment remains available | |
| Edit | Select a comment annotation | Target rectangle shows eight resize handles, arrow endpoints remain draggable, and text shows a lightweight selection boundary | |
| Edit | Drag the tail handle of a comment arrow | The comment text moves with the arrow tail and keeps its spacing from the arrow | |
| Edit | Drag the comment arrow head near, inside and outside the target | Near the border it snaps cleanly; beyond the snap range it stays exactly where released, including inside the target | |
| Edit | Move or resize a target after freeing its arrow head | The free arrow head remains fixed instead of being forced back to the target border | |
| Edit | Double-click a free comment arrow head | The arrow head returns to the nearest target border and resumes automatic attachment | |
| Edit | Drag a selected comment target border | Only the target box moves; the arrow head reattaches and the text stays fixed | |
| Edit | Drag selected comment text | Text and arrow tail move together; the target stays fixed | |
| Edit | Drag the shaft of a selected comment arrow | Target, arrow and text move as one group | |
| Edit | Type a long or multiline comment | No duplicate text appears; the arrow remains separated from and attached to the current text bounds | |
| Edit | Create a comment and press Esc before typing | The whole unfinished comment is removed without leaving an empty target or no-op undo step | |
| Edit | Edit a comment, then press Esc | The previous text and connector layout are restored | |
| Edit | Edit a comment and press Cmd+Enter | Editing commits immediately and the comment stays selected | |
| Edit | Adjust comment style panel | Font size, line width, color and opacity update the selected comment consistently | |
| Edit | Export a comment annotation | Saved/copied image contains the rectangle, arrow and comment text without editor handles | |
| Edit | Draw normal and comment arrows | Arrows render with a thin tail, heavier head and no plain-line arrow regression | |
| Edit | Type text annotation continuously, press Return to create a new line, then click outside | Text stays anchored while typing, tail newlines do not shift the block, and it does not jump after focus leaves | |
| Edit | Type a long text annotation without pressing Return | Text input expands horizontally instead of auto-wrapping; committed text matches the input layout | |
| Edit | Select mosaic and adjust style panel strength | Live preview and export use the same subtle-to-strong blur scale without a border | |

## Notes

- If Screen Recording was just enabled in System Settings, quit ShotMark from the status bar and reopen it before marking permission failures.
- For external screen testing, run the same small-area save/copy flow once on each connected display.
REPORT

echo "Regression report written to:"
echo "$REPORT_PATH"
