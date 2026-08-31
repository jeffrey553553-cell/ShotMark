# ShotMark Product Readiness

This document defines the bar for calling ShotMark a commercially ready macOS
capture product. A feature is not complete until its normal path, failure path,
permissions, multi-display behavior, and regression coverage are all verified.

## Competitive Baseline

| Area | Market baseline | ShotMark status | Exit criterion |
| --- | --- | --- | --- |
| Area and window capture | Fast global shortcut, frozen screen, smart window selection, Retina and multi-display correctness | Implemented | 99.5% successful activation and export across the supported test matrix |
| Scrolling capture | Live preview, fixed-element removal, manual and automatic capture, recovery after poor overlap | Bidirectional manual capture and optional automatic capture implemented | 95% first-attempt success in the real-app corpus; no missing or duplicated content in deterministic fixtures |
| Annotation | Consistent selection, undo/redo, polished arrows, text, counters, blur and callouts | Implemented | Every annotation follows the same select/move/resize/edit/Esc rules and exports pixel-identically |
| OCR and translation | Automatic language recognition, selectable text, reliable copy and translation | Implemented | Chinese and English fixture accuracy is tracked; all empty, permission and network failures are actionable |
| Recording | Native resolution, system and microphone audio, pause/resume, cursor options | Implemented | 30-minute stability run, audio sync, low-disk failure and permission recovery pass |
| Pinning | Multiple always-on-top images, zoom, opacity, pass-through and close-all | Implemented | Multi-display restore and lifecycle tests pass without orphan windows |
| Distribution | Recognizable app icon, signed/notarized installer, replacement install and automatic updates | Local signing and GitHub Releases | Developer ID notarization, Sparkle feed, rollback-safe updates and release automation |
| Commercial operation | Trial/license, privacy policy, support, crash reporting and release notes | Not implemented | Purchase and restore flow, local-first privacy disclosure, support channel and opt-in diagnostics ship |

## Priority Gates

### P0: Trust

- Keep screenshot, save, copy, pin, OCR, recording and long screenshot regression green.
- Maintain a real-app long screenshot corpus covering browsers, Finder, chat,
  documents, nested scrollers, lazy loading, sticky bars and both directions.
- Never silently export a partial long screenshot. Warn before resource limits,
  stop safely at the limit, and keep the current image exportable.
- Report capture permission state accurately and make restart/recovery explicit.

### P1: Daily-use polish

- Keep pointer states, hover feedback, shortcuts and Esc behavior consistent.
- Add capture-previous-area, timer capture and optional window-shadow export.
- Add horizontal scrolling capture and a lightweight final crop/cleanup flow.
- Add recording trim, GIF export and optional keystroke display.

### P2: Commercial release

- Use a Developer ID Application certificate and Apple notarization.
- Add a signed automatic-update feed with phased rollout and rollback notes.
- Add a transparent trial/license flow without blocking access to user files.
- Publish a privacy policy, supported macOS matrix, troubleshooting guide and
  response target for paid users.

## Current Iteration

- Added bounded, local-only long screenshot quality reports. They retain only
  dimensions, timings and stitch statistics; no image, text, application name
  or file path is recorded.
- Added a privacy-visible Settings section to copy a support summary or clear
  all retained diagnostics. Corrupt report data self-recovers and never blocks
  capture.
- Added directional recovery instructions after repeated alignment failures,
  while keeping the current stitched result exportable.
- Added a session lifecycle gate so late asynchronous frames cannot complete a
  capture after the user has cancelled, saved or encountered an error.
- Added regression coverage for retention, corruption recovery, privacy text,
  quality aggregation, idempotent completion and recovery advice.

## References

- [CleanShot X changelog](https://cleanshot.com/changelog)
- [CleanShot X URL scheme](https://cleanshot.com/docs-api)
- [Shottr scrolling capture](https://shottr.cc/kb/scrollingcapture)
- [Xnip scrolling capture](https://www.xnipapp.com/scrolling-capture/)
- [iShot App Store listing](https://apps.apple.com/cn/app/id1485844094)
