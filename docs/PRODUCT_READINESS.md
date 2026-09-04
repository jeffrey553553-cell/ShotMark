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

- Added a first-run setup guide that explains the required screen-recording
  permission before requesting it, keeps Accessibility optional, rechecks
  permission after returning from System Settings, offers a one-click relaunch,
  and starts the first capture directly once ready.
- Existing authorized users are migrated without seeing first-run UI. An
  interrupted setup remains recoverable after relaunch, while the status menu
  keeps a permanent entry for reopening the guide.
- Added user-initiated update checks in the status menu and Settings, plus a
  persisted opt-out for at-most-daily automatic checks.
- Update metadata is accepted only from the official GitHub repository over
  HTTPS. Drafts, prereleases, malformed versions, oversized responses, foreign
  download hosts and releases without `ShotMark.dmg` are rejected.
- Added strict public-release gates for Developer ID Application signing,
  Hardened Runtime, notarytool authentication, stapling, Gatekeeper assessment,
  clean/pushed `main`, authenticated GitHub CLI and duplicate release tags.
- Added one-command notarized release publishing with local/remote SHA-256
  verification. Development packages remain possible but cannot pass the
  public-release gate.
- Added a least-privilege `macos-15` CI workflow for every main push and pull
  request. The checkout action is pinned to an immutable commit and CI runs the
  complete Swift test suite plus a distributable app-bundle verification.
- Sparkle installation remains intentionally disabled until a real Developer ID
  identity and EdDSA update key are provisioned; update discovery opens the
  verified official Release page instead of executing an untrusted installer.

## References

- [CleanShot X changelog](https://cleanshot.com/changelog)
- [CleanShot X URL scheme](https://cleanshot.com/docs-api)
- [Shottr scrolling capture](https://shottr.cc/kb/scrollingcapture)
- [Xnip scrolling capture](https://www.xnipapp.com/scrolling-capture/)
- [iShot App Store listing](https://apps.apple.com/cn/app/id1485844094)
