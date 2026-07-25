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
| [capcap](https://github.com/realskyrin/capcap) | MIT | Native annotation geometry, smoothed pen paths, non-compounding marker strokes, selection editing | Annotation interaction and rendering reference; adapted work is attributed in `THIRD_PARTY_NOTICES.md` |
| [Capso](https://github.com/lzhgus/Capso) | Business Source License 1.1 | Broad native capture and annotation architecture | Behavior reference only; its current license prohibits use in a third-party screen-capture service |
| [ScrollSnap](https://github.com/Brkgng/ScrollSnap) | MIT | Scrolling capture, Vision translation registration, live preview | Secondary long-screenshot reference |
| [Kap](https://github.com/wulkano/Kap) | MIT | Recording lifecycle, export workflows, plugin-style post-processing | Candidate reference for recording pause/resume and export |
| [Maccy](https://github.com/p0deje/Maccy) | MIT | Local history storage, retention, search, keyboard navigation | Candidate reference for capture history |
| [Shotnix](https://github.com/Rishabh-Bansal/Shotnix) | MIT | Pinned-window copy, save, close and contextual actions | Pin interaction reference; ShotMark uses its own AppKit implementation |
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
| Annotation | Editable rectangle, ellipse, arrow, freehand pen, non-compounding highlighter, number, text, callout and blur | capcap, Snapzy, Flameshot | Add constrained geometry, spotlight and multi-selection |
| OCR and translation | Implemented with Vision and Translation | Snapzy, Apple Vision | Preserve layout, language chooser and searchable OCR history |
| Scrolling capture | Bidirectional stitching with pixel matching and Vision recovery | Snapzy, ScrollSnap, ShareX | Add session metrics, safety state and fixture benchmark corpus |
| Recording | Native selection-size MP4 with silent, system, microphone and mixed audio modes | Kap, Snapzy | Pause/resume, GIF export, click highlight and keystroke overlay |
| Pinning | Independent windows with constrained zoom, opacity, copy/save, mouse pass-through lock and multi-pin management | Snapzy, Shotnix | Drag-out, pin groups and persisted workspaces |
| Export | PNG clipboard and Downloads save | Snapzy, ShareX | PNG/JPEG/WebP, naming template, configurable destination and drag-out |
| History | Searchable local image/video history, private media copies, 30-day/200-item retention and quick result card implemented | Maccy, Snapzy | Add configurable retention, favorites and OCR text indexing |
| Updates | Manual GitHub Release | Snapzy | Signed Developer ID build, notarization and Sparkle update feed |

## Priority

1. Capture precision and activation latency.
2. Local capture history and quick-access result card.
3. Recording pause/resume, click highlight and GIF export.
4. Constrained geometry, spotlight and annotation multi-selection.
5. Export formats, naming rules and configurable destinations.
6. Signed, notarized automatic updates.
