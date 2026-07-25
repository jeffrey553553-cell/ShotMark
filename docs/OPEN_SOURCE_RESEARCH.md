# ShotMark Open-Source Research

This document tracks external implementations evaluated while improving
ShotMark. Repository metadata and licenses must be rechecked before code is
adapted because upstream projects can change.

## Reuse Policy

- Permissive licenses such as MIT and BSD-3-Clause may be adapted when their
  notice requirements are preserved.
- GPL projects are interaction and architecture references only. Their code
  must not be copied into ShotMark unless ShotMark intentionally adopts a
  compatible GPL distribution model.
- Repositories without a declared license are behavior references only.
- Apple frameworks and official samples remain the preferred foundation for
  macOS capture, OCR, translation, and recording.

## Evaluated Projects

| Project | License | Useful Areas | ShotMark Decision |
| --- | --- | --- | --- |
| [Snapzy](https://github.com/duongductrong/Snapzy) | BSD-3-Clause | ScreenCaptureKit capture, multi-display selection, magnifier, Vision-assisted scrolling capture, OCR, recording, history | Primary native macOS reference; adapted work is attributed in `THIRD_PARTY_NOTICES.md` |
| [ScrollSnap](https://github.com/Brkgng/ScrollSnap) | MIT | Scrolling capture, Vision translation registration, live preview | Secondary long-screenshot reference |
| [Kap](https://github.com/wulkano/Kap) | MIT | Recording lifecycle, export workflows, plugin-style post-processing | Candidate reference for recording pause/resume and export |
| [Maccy](https://github.com/p0deje/Maccy) | MIT | Local history storage, retention, search, keyboard navigation | Candidate reference for capture history |
| [Flameshot](https://github.com/flameshot-org/flameshot) | GPL-3.0 | Annotation shortcuts, pixel nudging, constrained drawing, export actions | Interaction reference only |
| [ShareX](https://github.com/ShareX/ShareX) | GPL-3.0 | Capture workflows, scrolling capture fallbacks, history and destinations | Interaction and test-matrix reference only |
| [Mio](https://github.com/iSoldLeo/Mio) | No declared license when evaluated | Fast frozen-display activation, transparent window capture | Behavior reference only |
| [Rectangle](https://github.com/rxhanson/Rectangle) | No SPDX license reported when evaluated | Multi-display geometry and hotkey ergonomics | Behavior reference until license is verified manually |

## Capability Matrix

| Capability | Current ShotMark State | Best Reference | Next Improvement |
| --- | --- | --- | --- |
| Frozen multi-display selection | Implemented | Snapzy, Mio | Pre-warm overlay windows and benchmark activation latency |
| Smart window selection | Implemented with ScreenCaptureKit, CGWindow and AX calibration | Snapzy | Add application/element mode and window-shadow export |
| Selection precision | Magnifier, color readout and physical-pixel keyboard movement implemented | Snapzy, Flameshot | Add optional standalone color picker |
| Annotation | Rectangle, arrow, number, text, callout and blur | Flameshot, Snapzy | Add ellipse, freehand/highlighter, constrained geometry and annotation copy/paste |
| OCR and translation | Implemented with Vision and Translation | Snapzy, Apple Vision | Preserve layout, language chooser and searchable OCR history |
| Scrolling capture | Bidirectional stitching with pixel matching and Vision recovery | Snapzy, ScrollSnap, ShareX | Add session metrics, safety state and fixture benchmark corpus |
| Recording | MP4, quality and audio modes | Kap, Snapzy | Pause/resume, GIF export, click highlight and keystroke overlay |
| Pinning | Implemented | Snapzy | Opacity control, zoom and multi-pin management |
| Export | PNG clipboard and Downloads save | Snapzy, ShareX | PNG/JPEG/WebP, naming template, configurable destination and drag-out |
| History | Not implemented | Maccy, Snapzy | Local searchable capture history with retention controls |
| Updates | Manual GitHub Release | Snapzy | Signed Developer ID build, notarization and Sparkle update feed |

## Priority

1. Capture precision and activation latency.
2. Local capture history and quick-access result card.
3. Recording pause/resume, click highlight and GIF export.
4. Additional annotation tools and constrained drawing.
5. Export formats, naming rules and configurable destinations.
6. Signed, notarized automatic updates.
