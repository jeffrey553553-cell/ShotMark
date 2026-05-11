import AppKit

protocol SelectionOverlayControllerDelegate: AnyObject {
    func selectionOverlayController(_ controller: SelectionOverlayController, didCommit selection: CaptureSelection, annotations: [Annotation], action: CaptureCommitAction)
    func selectionOverlayController(_ controller: SelectionOverlayController, didRequestOCRCapture selection: CaptureSelection, completion: @escaping (Result<CaptureResult, Error>) -> Void)
    func selectionOverlayControllerDidCancel(_ controller: SelectionOverlayController)
}

final class SelectionOverlayController {
    weak var delegate: SelectionOverlayControllerDelegate?
    private var windows: [NSWindow] = []

    func show() {
        NSApp.activate()
        windows = NSScreen.screens.map { screen in
            let view = SelectionOverlayView(screen: screen)
            view.onCancel = { [weak self] in self?.cancel() }
            view.onCommit = { [weak self] selection, annotations, action in
                guard let self else { return }
                self.closeWindows()
                self.delegate?.selectionOverlayController(self, didCommit: selection, annotations: annotations, action: action)
            }
            view.onOCRCapture = { [weak self, weak view] selection, completion in
                guard let self else { return }
                self.windows.forEach { $0.orderOut(nil) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    self.delegate?.selectionOverlayController(self, didRequestOCRCapture: selection) { result in
                        DispatchQueue.main.async {
                            self.bringWindowsToFront(preferred: view?.window)
                            view?.prepareForCaptureFocus()
                            completion(result)
                        }
                    }
                }
            }

            let window = SelectionOverlayPanel(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.level = .screenSaver
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.sharingType = .none
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.contentView = view
            window.setFrame(screen.frame, display: false)
            window.orderFrontRegardless()
            view.prepareForCaptureFocus()
            return window
        }
        bringWindowsToFront()
    }

    func cancel() {
        closeWindows()
        delegate?.selectionOverlayControllerDidCancel(self)
    }

    private func closeWindows() {
        windows.forEach {
            ($0.contentView as? SelectionOverlayView)?.closeTransientPanels()
            $0.orderOut(nil)
        }
        windows.removeAll()
    }

    private func bringWindowsToFront(preferred: NSWindow? = nil) {
        windows.forEach {
            $0.orderFrontRegardless()
            ($0.contentView as? SelectionOverlayView)?.prepareForCaptureFocus()
        }

        let targetWindow = preferred ?? windowUnderCurrentMouse() ?? windows.first
        targetWindow?.makeKeyAndOrderFront(nil)
        (targetWindow?.contentView as? SelectionOverlayView)?.prepareForCaptureFocus()
    }

    private func windowUnderCurrentMouse() -> NSWindow? {
        let mouseLocation = NSEvent.mouseLocation
        return windows.first { $0.frame.contains(mouseLocation) }
    }
}

private final class SelectionOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class SelectionOverlayView: NSView, NSTextViewDelegate {
    var onCommit: ((CaptureSelection, [Annotation], CaptureCommitAction) -> Void)?
    var onOCRCapture: ((CaptureSelection, @escaping (Result<CaptureResult, Error>) -> Void) -> Void)?
    var onCancel: (() -> Void)?

    private enum RectHandle {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    private enum AnnotationRectHandle {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    private enum ArrowEndpoint {
        case start, end
    }

    private enum StyleControl {
        case size, opacity
    }

    private struct EditSnapshot {
        var selectionRect: CGRect?
        var annotations: [Annotation]
        var selectedAnnotationIndex: Int?
        var nextMarkerNumber: Int
    }

    private struct ToolStyle {
        var color: NSColor
        var size: CGFloat
        var opacity: CGFloat
        var filled: Bool = false
    }

    private enum DragMode {
        case drawingSelection(start: CGPoint)
        case movingSelection(startPoint: CGPoint, originalRect: CGRect)
        case resizingSelection(handle: RectHandle, originalRect: CGRect)
        case drawingRectangle(start: CGPoint, current: CGPoint)
        case drawingMosaic(start: CGPoint, current: CGPoint)
        case drawingArrow(start: CGPoint, current: CGPoint)
        case movingAnnotation(index: Int, lastPoint: CGPoint)
        case resizingAnnotation(index: Int, handle: AnnotationRectHandle)
        case movingArrowEndpoint(index: Int, endpoint: ArrowEndpoint)
        case adjustingStyle(control: StyleControl)
    }

    private enum OverlayButton: CaseIterable {
        case rectangle, arrow, number, text, mosaic, ocr, pin, longScreenshot, record, recordQuality, undo, redo, delete, copy, save, cancel

        var title: String {
            switch self {
            case .rectangle: "R"
            case .arrow: "A"
            case .number: "3"
            case .text: "T"
            case .mosaic: "M"
            case .ocr: "OCR"
            case .pin: "P"
            case .longScreenshot: "长"
            case .record: "录制"
            case .recordQuality: "▾"
            case .undo: "↶"
            case .redo: "↷"
            case .delete: "⌫"
            case .copy: "C"
            case .save: "S"
            case .cancel: "×"
            }
        }

        var symbolName: String? {
            switch self {
            case .rectangle: "rectangle"
            case .arrow: "arrow.up.right"
            case .number: "3.circle"
            case .text: nil
            case .mosaic: nil
            case .ocr: nil
            case .pin: "pin"
            case .longScreenshot: nil
            case .record: "record.circle"
            case .recordQuality: "chevron.down"
            case .undo: "arrow.uturn.backward"
            case .redo: "arrow.uturn.forward"
            case .delete: "trash"
            case .copy: "doc.on.doc"
            case .save: "square.and.arrow.down"
            case .cancel: "xmark"
            }
        }
    }

    private struct ShortcutOption {
        let display: String
        let key: String
    }

    private let targetScreen: NSScreen
    private let mosaicPreviewCaptureService = CaptureService()
    private var selectionRect: CGRect?
    private var dragMode: DragMode?
    private var selectedTool: AnnotationTool?
    private var annotations: [Annotation] = []
    private var selectedAnnotationIndex: Int?
    private var nextMarkerNumber = 1
    private var activeTextView: NSTextView?
    private var activeTextOrigin: CGPoint?
    private var ocrPanelController: OCRResultPanelController?
    private var ocrDismissEventMonitor: Any?
    private var isOCRBusy = false
    private var selectedVideoQuality: VideoQualityPreset = .p1080
    private var selectedAudioMode: VideoAudioMode = .none
    private var mosaicBlockSize: CGFloat = 12
    private var undoStack: [EditSnapshot] = []
    private var redoStack: [EditSnapshot] = []
    private var activeTextIsEditingExisting = false
    private var shouldIgnoreNextMouseDownAfterTextEndEditing = false
    private var pendingTextEditIndex: Int?
    private var pendingTextEditStart: CGPoint?
    private var pendingTextEditDidMove = false
    private var isVideoQualityMenuOpen = false
    private var hoveredVideoQuality: VideoQualityPreset?
    private var hoveredAudioMode: VideoAudioMode?
    private var hoveredButton: OverlayButton?
    private var shortcutMenuButton: OverlayButton?
    private var customShortcuts: [OverlayButton: String] = [:]
    private var clearedShortcuts: Set<OverlayButton> = []
    private var mosaicPreviewImage: CGImage?
    private var mosaicPreviewRect: CGRect?
    private var mosaicPreviewGeneration = 0
    private var isMosaicPreviewCaptureInFlight = false
    private var shouldRefreshMosaicPreviewAfterCurrentCapture = false
    private var hoverTrackingArea: NSTrackingArea?
    private var hoverClearWorkItem: DispatchWorkItem?
    private let shortcutOptions: [ShortcutOption] = {
        let letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map { ShortcutOption(display: String($0), key: String($0)) }
        let digits = "0123456789".map { ShortcutOption(display: String($0), key: String($0)) }
        let symbols = [
            ("`", "`"), ("-", "-"), ("=", "="), ("[", "["), ("]", "]"), ("\\", "\\"),
            (";", ";"), ("'", "'"), (",", ","), (".", "."), ("/", "/")
        ].map { ShortcutOption(display: $0.0, key: $0.1) }
        let special = [
            ShortcutOption(display: "Space", key: "SPACE"),
            ShortcutOption(display: "Tab", key: "TAB"),
            ShortcutOption(display: "Enter", key: "RETURN"),
            ShortcutOption(display: "Esc", key: "ESCAPE"),
            ShortcutOption(display: "Del", key: "DELETE"),
            ShortcutOption(display: "↑", key: "UP"),
            ShortcutOption(display: "↓", key: "DOWN"),
            ShortcutOption(display: "←", key: "LEFT"),
            ShortcutOption(display: "→", key: "RIGHT"),
            ShortcutOption(display: "Home", key: "HOME"),
            ShortcutOption(display: "End", key: "END"),
            ShortcutOption(display: "PgUp", key: "PAGE_UP"),
            ShortcutOption(display: "PgDn", key: "PAGE_DOWN")
        ]
        let functionKeys = (1...12).map { ShortcutOption(display: "F\($0)", key: "F\($0)") }
        return letters + digits + symbols + special + functionKeys
    }()
    private var rectangleStyle = ToolStyle(color: .systemRed, size: 3, opacity: 1)
    private var arrowStyle = ToolStyle(color: .systemRed, size: 4, opacity: 1)
    private var numberMarkerStyle = ToolStyle(color: .systemRed, size: 13, opacity: 1)
    private var textStyle = ToolStyle(color: .systemRed, size: 18, opacity: 1)
    private let styleColors: [NSColor] = [
        .systemRed,
        .systemPink,
        .systemCyan,
        .systemYellow,
        .systemGreen,
        .white,
        .black
    ]

    init(screen: NSScreen) {
        targetScreen = screen
        super.init(frame: CGRect(origin: .zero, size: screen.frame.size))
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func viewDidMoveToWindow() {
        prepareForCaptureFocus()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    func prepareForCaptureFocus() {
        window?.acceptsMouseMovedEvents = true
        window?.makeFirstResponder(self)
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func keyDown(with event: NSEvent) {
        if activeTextView != nil {
            super.keyDown(with: event)
            return
        }

        let command = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)
        if command, event.charactersIgnoringModifiers?.lowercased() == "z" {
            shift ? redoEdit() : undoEdit()
            return
        }
        if command, event.charactersIgnoringModifiers?.lowercased() == "y" {
            redoEdit()
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            deleteSelectedAnnotation()
            return
        }
        if
            !command,
            let key = shortcutKey(from: event),
            handleToolbarShortcut(key)
        {
            return
        }

        if command, event.charactersIgnoringModifiers?.lowercased() == "c" {
            commitSelection(.copyToClipboard)
            return
        }

        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if ocrPanelController != nil {
            closeTransientPanels()
            needsDisplay = true
            return
        }

        if shouldIgnoreNextMouseDownAfterTextEndEditing {
            shouldIgnoreNextMouseDownAfterTextEndEditing = false
            window?.makeFirstResponder(self)
            needsDisplay = true
            return
        }

        if activeTextView != nil {
            commitActiveText()
            shouldIgnoreNextMouseDownAfterTextEndEditing = false
            window?.makeFirstResponder(self)
            needsDisplay = true
            return
        }

        if let selectionRect {
            if handleShortcutMenuClick(at: point, selectionRect: selectionRect) {
                return
            }
            if handleTooltipShortcutClick(at: point, selectionRect: selectionRect) {
                return
            }

            if handleVideoQualityMenuClick(at: point, selectionRect: selectionRect) {
                return
            }
            if isVideoQualityMenuOpen {
                isVideoQualityMenuOpen = false
                needsDisplay = true
            }

            if handleButtonClick(at: point, selectionRect: selectionRect) {
                return
            }

            if handleStylePanelClick(at: point, selectionRect: selectionRect) {
                return
            }

            if let selectedAnnotationIndex, let drag = hitSelectedAnnotationHandle(at: point, index: selectedAnnotationIndex) {
                registerUndo()
                dragMode = drag
                return
            }

            if selectionRect.contains(point) {
                let relative = relativePoint(point)
                pendingTextEditIndex = nil
                pendingTextEditStart = nil
                pendingTextEditDidMove = false

                if selectedTextAnnotationContains(relative), let selectedAnnotationIndex {
                    registerUndo()
                    pendingTextEditIndex = selectedAnnotationIndex
                    pendingTextEditStart = relative
                    dragMode = .movingAnnotation(index: selectedAnnotationIndex, lastPoint: relative)
                    return
                }

                if let drag = hitAnnotation(at: relative) {
                    registerUndo()
                    dragMode = drag
                    return
                }

                if let selectedTool {
                    beginAnnotation(tool: selectedTool, at: relative)
                    return
                }

                NSCursor.closedHand.set()
                registerUndo()
                dragMode = .movingSelection(startPoint: point, originalRect: selectionRect)
                return
            }

            if let handle = handleHit(at: point, rect: selectionRect) {
                registerUndo()
                dragMode = .resizingSelection(handle: handle, originalRect: selectionRect)
                return
            }
        }

        selectedTool = nil
        selectedAnnotationIndex = nil
        annotations.removeAll()
        undoStack.removeAll()
        redoStack.removeAll()
        invalidateMosaicPreview()
        dragMode = .drawingSelection(start: point)
        selectionRect = CGRect(origin: point, size: .zero)
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        guard let selectionRect else {
            setHoveredButton(nil)
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        updateRecordingMenuHover(at: point, selectionRect: selectionRect)

        if let button = hoveredToolbarButton(at: point, selectionRect: selectionRect) {
            setHoveredButton(button)
        } else {
            scheduleHoveredButtonClear()
        }
    }

    override func mouseExited(with event: NSEvent) {
        scheduleHoveredButtonClear()
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let relative = relativePoint(point)

        switch dragMode {
        case .drawingSelection(let start):
            selectionRect = normalizedRect(from: start, to: point)
            invalidateMosaicPreview()
        case .movingSelection(let startPoint, let originalRect):
            let delta = CGPoint(x: point.x - startPoint.x, y: point.y - startPoint.y)
            let nextRect = clamped(originalRect.offsetBy(dx: delta.x, dy: delta.y))
            setSelectionRect(nextRect, keepingAnnotationsStationary: true)
        case .resizingSelection(let handle, let originalRect):
            setSelectionRect(clamped(resized(originalRect, handle: handle, to: point)), keepingAnnotationsStationary: true)
        case .drawingRectangle(let start, _):
            dragMode = .drawingRectangle(start: start, current: relative)
        case .drawingMosaic(let start, _):
            dragMode = .drawingMosaic(start: start, current: relative)
            requestMosaicPreviewCaptureIfNeeded()
        case .drawingArrow(let start, _):
            dragMode = .drawingArrow(start: start, current: relative)
        case .movingAnnotation(let index, let lastPoint):
            if let start = pendingTextEditStart, distance(relative, start) > 3 {
                pendingTextEditDidMove = true
            }
            moveAnnotation(at: index, by: CGPoint(x: relative.x - lastPoint.x, y: relative.y - lastPoint.y))
            dragMode = .movingAnnotation(index: index, lastPoint: relative)
        case .resizingAnnotation(let index, let handle):
            resizeAnnotationRectangle(at: index, handle: handle, to: relative)
        case .movingArrowEndpoint(let index, let endpoint):
            moveArrowEndpoint(at: index, endpoint: endpoint, to: relative)
        case .adjustingStyle(let control):
            updateStyle(control: control, at: point)
        case nil:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = relativePoint(convert(event.locationInWindow, from: nil))
        let textEditIndex = pendingTextEditIndex
        let shouldBeginTextEdit = textEditIndex != nil && !pendingTextEditDidMove

        switch dragMode {
        case .drawingRectangle(let start, _):
            let rect = normalizedRect(from: start, to: point)
            if rect.width > 4, rect.height > 4 {
                add(.rectangle(rect: rect, color: effectiveColor(rectangleStyle), lineWidth: rectangleStyle.size, filled: rectangleStyle.filled))
            }
        case .drawingMosaic(let start, _):
            let rect = normalizedRect(from: start, to: point)
            if rect.width > 4, rect.height > 4 {
                add(.mosaic(rect: rect, blockSize: mosaicBlockSize))
                requestMosaicPreviewCaptureIfNeeded()
            }
        case .drawingArrow(let start, _):
            if hypot(point.x - start.x, point.y - start.y) > 4 {
                add(.arrow(start: start, end: point, color: effectiveColor(arrowStyle), lineWidth: arrowStyle.size))
            }
        case .drawingSelection, .movingSelection, .resizingSelection, .movingAnnotation, .resizingAnnotation, .movingArrowEndpoint, .adjustingStyle, nil:
            break
        }

        dragMode = nil
        pendingTextEditIndex = nil
        pendingTextEditStart = nil
        pendingTextEditDidMove = false
        NSCursor.arrow.set()
        if let rect = selectionRect, rect.width < 8 || rect.height < 8 {
            selectionRect = nil
            annotations.removeAll()
        }
        if shouldBeginTextEdit, let textEditIndex {
            beginTextEdit(at: textEditIndex)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.50).setFill()
        bounds.fill()

        guard let selectionRect else {
            drawInitialHint()
            return
        }

        requestMosaicPreviewCaptureIfNeeded()
        NSColor.clear.setFill()
        selectionRect.fill(using: .clear)
        drawSelectionFrame(selectionRect)
        drawAnnotations(in: selectionRect)
        drawDimensionBadge(for: selectionRect)
        drawToolbar(for: selectionRect)
        drawStylePanel(for: selectionRect)
        drawVideoQualityMenu(for: selectionRect)
        drawToolbarTooltip(for: selectionRect)
        drawShortcutLetterMenu(for: selectionRect)
    }

    private func beginAnnotation(tool: AnnotationTool, at point: CGPoint) {
        switch tool {
        case .rectangle:
            dragMode = .drawingRectangle(start: point, current: point)
        case .arrow:
            dragMode = .drawingArrow(start: point, current: point)
        case .mosaic:
            dragMode = .drawingMosaic(start: point, current: point)
            requestMosaicPreviewCaptureIfNeeded()
        case .numberMarker:
            add(.numberMarker(center: point, number: nextMarkerNumber, color: effectiveColor(numberMarkerStyle), markerSize: numberMarkerStyle.size))
            nextMarkerNumber += 1
        case .text:
            beginTextEntry(at: point, initialText: "")
        }
    }

    private func add(_ annotation: Annotation) {
        add(annotation, registersUndo: true)
    }

    private func add(_ annotation: Annotation, registersUndo: Bool) {
        if registersUndo {
            registerUndo()
        }
        annotations.append(annotation)
        selectedAnnotationIndex = annotations.count - 1
        needsDisplay = true
    }

    private func makeSnapshot() -> EditSnapshot {
        EditSnapshot(
            selectionRect: selectionRect,
            annotations: annotations,
            selectedAnnotationIndex: selectedAnnotationIndex,
            nextMarkerNumber: nextMarkerNumber
        )
    }

    private func restoreSnapshot(_ snapshot: EditSnapshot) {
        selectionRect = snapshot.selectionRect
        annotations = snapshot.annotations
        selectedAnnotationIndex = snapshot.selectedAnnotationIndex
        nextMarkerNumber = snapshot.nextMarkerNumber
        dragMode = nil
        closeTransientPanels()
        invalidateMosaicPreview()
        if annotations.contains(where: { $0.isMosaic }) || selectedTool == .mosaic {
            requestMosaicPreviewCaptureIfNeeded()
        }
        needsDisplay = true
    }

    private func registerUndo() {
        undoStack.append(makeSnapshot())
        if undoStack.count > 80 {
            undoStack.removeFirst(undoStack.count - 80)
        }
        redoStack.removeAll()
    }

    private func undoEdit() {
        commitActiveText()
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(makeSnapshot())
        restoreSnapshot(snapshot)
    }

    private func redoEdit() {
        commitActiveText()
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(makeSnapshot())
        restoreSnapshot(snapshot)
    }

    private func deleteSelectedAnnotation() {
        commitActiveText()
        guard let index = selectedAnnotationIndex, annotations.indices.contains(index) else { return }
        registerUndo()
        annotations.remove(at: index)
        selectedAnnotationIndex = nil
        if !annotations.contains(where: { $0.isMosaic }) {
            invalidateMosaicPreview()
        }
        needsDisplay = true
    }

    private func commitSelection(_ action: CaptureCommitAction) {
        commitActiveText()
        guard let selection = currentCaptureSelection() else { return }
        onCommit?(selection, annotations, action)
    }

    private func currentCaptureSelection() -> CaptureSelection? {
        guard let selectionRect else { return nil }
        return captureSelection(for: selectionRect)
    }

    private var hasMosaicWork: Bool {
        if selectedTool == .mosaic {
            return true
        }
        if case .drawingMosaic = dragMode {
            return true
        }
        return annotations.contains { $0.isMosaic }
    }

    private func invalidateMosaicPreview() {
        mosaicPreviewGeneration += 1
        mosaicPreviewImage = nil
        mosaicPreviewRect = nil
        shouldRefreshMosaicPreviewAfterCurrentCapture = false
    }

    private func requestMosaicPreviewCaptureIfNeeded() {
        guard hasMosaicWork, let selectionRect, let selection = currentCaptureSelection() else { return }
        if let mosaicPreviewImage, let mosaicPreviewRect, rectsMatch(mosaicPreviewRect, selectionRect), mosaicPreviewImage.width > 0 {
            return
        }

        if isMosaicPreviewCaptureInFlight {
            shouldRefreshMosaicPreviewAfterCurrentCapture = true
            return
        }

        isMosaicPreviewCaptureInFlight = true
        shouldRefreshMosaicPreviewAfterCurrentCapture = false
        let expectedRect = selectionRect
        let generation = mosaicPreviewGeneration

        mosaicPreviewCaptureService.capture(selection: selection) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isMosaicPreviewCaptureInFlight = false

                defer {
                    if self.shouldRefreshMosaicPreviewAfterCurrentCapture {
                        self.shouldRefreshMosaicPreviewAfterCurrentCapture = false
                        self.requestMosaicPreviewCaptureIfNeeded()
                    }
                }

                guard generation == self.mosaicPreviewGeneration,
                      let currentRect = self.selectionRect,
                      self.rectsMatch(currentRect, expectedRect)
                else { return }

                if case .success(let capture) = result {
                    self.mosaicPreviewImage = capture.image
                    self.mosaicPreviewRect = expectedRect
                    self.needsDisplay = true
                }
            }
        }
    }

    private func rectsMatch(_ first: CGRect, _ second: CGRect) -> Bool {
        abs(first.minX - second.minX) < 0.5
            && abs(first.minY - second.minY) < 0.5
            && abs(first.width - second.width) < 0.5
            && abs(first.height - second.height) < 0.5
    }

    private func drawAnnotations(in selectionRect: CGRect) {
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: selectionRect.minX, yBy: selectionRect.minY)
        transform.concat()

        drawMosaicAnnotations(annotations, in: selectionRect.size)
        AnnotationDrawing.draw(annotations.filter { !$0.isMosaic }, in: selectionRect.size)
        drawSelectedAnnotationHandles()

        switch dragMode {
        case .drawingRectangle(let start, let current):
            AnnotationDrawing.draw([.rectangle(rect: normalizedRect(from: start, to: current), color: effectiveColor(rectangleStyle), lineWidth: rectangleStyle.size, filled: rectangleStyle.filled)], in: selectionRect.size)
        case .drawingMosaic(let start, let current):
            drawMosaic(rect: normalizedRect(from: start, to: current), blockSize: mosaicBlockSize, pointSize: selectionRect.size)
        case .drawingArrow(let start, let current):
            AnnotationDrawing.draw([.arrow(start: start, end: current, color: effectiveColor(arrowStyle), lineWidth: arrowStyle.size)], in: selectionRect.size)
        case .drawingSelection, .movingSelection, .resizingSelection, .movingAnnotation, .resizingAnnotation, .movingArrowEndpoint, .adjustingStyle, nil:
            break
        }

        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawMosaicAnnotations(_ annotations: [Annotation], in pointSize: CGSize) {
        for annotation in annotations {
            guard case .mosaic(let rect, let blockSize) = annotation else { continue }
            drawMosaic(rect: rect, blockSize: blockSize, pointSize: pointSize)
        }
    }

    private func drawMosaic(rect: CGRect, blockSize: CGFloat, pointSize: CGSize) {
        if let image = mosaicPreviewImage {
            MosaicRenderer.drawFrostedMosaic(
                rect: rect,
                blockSize: blockSize,
                sourceImage: image,
                pointSize: pointSize
            )
        } else {
            MosaicRenderer.drawGlassPlaceholder(rect: rect, blockSize: blockSize)
        }
    }

    private func drawSelectionFrame(_ rect: CGRect) {
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 2
        path.stroke()

        NSColor.white.setFill()
        NSColor.controlAccentColor.setStroke()
        for point in handlePoints(for: rect).map(\.1) {
            let handle = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
            let handlePath = NSBezierPath(roundedRect: handle, xRadius: 4, yRadius: 4)
            handlePath.fill()
            handlePath.lineWidth = 1
            handlePath.stroke()
        }
    }

    private func drawToolbar(for rect: CGRect) {
        let bar = toolbarFrame(for: rect)
        drawFloatingPanelBackground(in: bar, radius: 14, alpha: 0.86)

        for button in OverlayButton.allCases {
            if button == .record {
                drawRecordButtonGroup(for: rect)
                continue
            }
            if button == .recordQuality {
                continue
            }

            let highlighted = tool(for: button).map { $0 == selectedTool } ?? false
            drawButton(
                button,
                in: buttonFrame(button, for: rect),
                highlighted: highlighted,
                enabled: isButtonEnabled(button)
            )
        }
    }

    private func drawFloatingPanelBackground(in rect: CGRect, radius: CGFloat, alpha: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 16
        shadow.shadowOffset = CGSize(width: 0, height: -5)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.26)
        shadow.set()

        NSColor(calibratedWhite: 0.08, alpha: alpha).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.withAlphaComponent(0.12).setStroke()
        let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        border.lineWidth = 1
        border.stroke()
    }

    private func buttonTitle(for button: OverlayButton) -> String {
        if button == .ocr, isOCRBusy {
            return "OCR..."
        }
        if button == .record {
            return "录制 \(selectedVideoQuality.title)"
        }
        return button.title
    }

    private func isButtonEnabled(_ button: OverlayButton) -> Bool {
        switch button {
        case .undo:
            return !undoStack.isEmpty
        case .redo:
            return !redoStack.isEmpty
        case .delete:
            return selectedAnnotationIndex.map { annotations.indices.contains($0) } ?? false
        case .recordQuality:
            return false
        default:
            return true
        }
    }

    private func drawStylePanel(for rect: CGRect) {
        guard
            let tool = selectedTool,
            supportsStylePanel(tool),
            let panel = stylePanelFrame(for: rect)
        else { return }

        let style = currentStyle(for: tool)
        drawFloatingPanelBackground(in: panel, radius: 12, alpha: 0.84)

        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92)
        ]
        let valueAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.90)
        ]

        let sizeLabel = tool == .text ? "字号" : (tool == .mosaic ? "强度" : "大小")
        sizeLabel.draw(at: CGPoint(x: panel.minX + 14, y: panel.maxY - 26), withAttributes: labelAttributes)
        "\(Int(round(style.size)))".draw(at: CGPoint(x: panel.maxX - 38, y: panel.maxY - 26), withAttributes: valueAttributes)
        drawSlider(in: sliderFrame(.size, in: panel), value: style.size, range: styleSizeRange(for: tool))

        if tool == .mosaic {
            return
        }

        "不透明度".draw(at: CGPoint(x: panel.minX + 14, y: panel.maxY - 54), withAttributes: labelAttributes)
        "\(Int(round(style.opacity * 100)))".draw(at: CGPoint(x: panel.maxX - 42, y: panel.maxY - 54), withAttributes: valueAttributes)
        drawSlider(in: sliderFrame(.opacity, in: panel), value: style.opacity, range: 0.1...1)

        if tool == .rectangle {
            "填充".draw(at: CGPoint(x: panel.minX + 14, y: panel.maxY - 84), withAttributes: labelAttributes)
            drawFillToggle(in: fillToggleFrame(in: panel), isOn: style.filled)
        }

        for index in styleColors.indices {
            let swatch = colorSwatchFrame(index: index, in: panel)
            let color = styleColors[index]
            color.setFill()
            NSBezierPath(ovalIn: swatch).fill()

            if colorsMatch(color, style.color) {
                NSColor.white.setStroke()
                let ring = swatch.insetBy(dx: -3, dy: -3)
                let path = NSBezierPath(ovalIn: ring)
                path.lineWidth = 2
                path.stroke()
            } else {
                NSColor.white.withAlphaComponent(color == .white ? 0.65 : 0.22).setStroke()
                let path = NSBezierPath(ovalIn: swatch)
                path.lineWidth = 1
                path.stroke()
            }
        }
    }

    private func drawSlider(in rect: CGRect, value: CGFloat, range: ClosedRange<CGFloat>) {
        let progress = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        let clampedProgress = min(1, max(0, progress))
        let track = CGRect(x: rect.minX, y: rect.midY - 1.5, width: rect.width, height: 3)

        NSColor.white.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()

        let filled = CGRect(x: track.minX, y: track.minY, width: track.width * clampedProgress, height: track.height)
        NSColor.white.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: filled, xRadius: 2, yRadius: 2).fill()

        let knobCenter = CGPoint(x: rect.minX + rect.width * clampedProgress, y: rect.midY)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: CGRect(x: knobCenter.x - 6, y: knobCenter.y - 6, width: 12, height: 12)).fill()
    }

    private func drawFillToggle(in rect: CGRect, isOn: Bool) {
        (isOn ? NSColor.controlAccentColor : NSColor.white.withAlphaComponent(0.18)).setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()

        let knobX = isOn ? rect.maxX - rect.height + 3 : rect.minX + 3
        let knob = CGRect(x: knobX, y: rect.minY + 3, width: rect.height - 6, height: rect.height - 6)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knob).fill()
    }

    private func drawVideoQualityMenu(for rect: CGRect) {
        guard isVideoQualityMenuOpen, let panel = videoQualityMenuFrame(for: rect) else { return }

        drawFloatingPanelBackground(in: panel, radius: 12, alpha: 0.86)

        drawMenuSectionTitle("清晰度", at: CGPoint(x: panel.minX + 14, y: panel.maxY - 25))
        for (index, quality) in VideoQualityPreset.allCases.enumerated() {
            let row = videoQualityOptionFrame(index: index, in: panel)
            if quality == hoveredVideoQuality {
                NSColor.white.withAlphaComponent(0.12).setFill()
                NSBezierPath(roundedRect: row.insetBy(dx: 6, dy: 4), xRadius: 7, yRadius: 7).fill()
            }

            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
            let title = videoQualityTitle(quality, for: rect)
            let size = title.size(withAttributes: attributes)
            title.draw(at: CGPoint(x: row.minX + 14, y: row.midY - size.height / 2), withAttributes: attributes)
        }

        let dividerY = panel.maxY - 34 - CGFloat(VideoQualityPreset.allCases.count) * 30 - 8
        NSColor.white.withAlphaComponent(0.10).setStroke()
        let divider = NSBezierPath()
        divider.move(to: CGPoint(x: panel.minX + 12, y: dividerY))
        divider.line(to: CGPoint(x: panel.maxX - 12, y: dividerY))
        divider.lineWidth = 1
        divider.stroke()

        drawMenuSectionTitle("音频", at: CGPoint(x: panel.minX + 14, y: dividerY - 24))
        for (index, audioMode) in VideoAudioMode.allCases.enumerated() {
            let row = audioModeOptionFrame(index: index, in: panel)
            if audioMode == selectedAudioMode {
                NSColor.controlAccentColor.withAlphaComponent(0.72).setFill()
                NSBezierPath(roundedRect: row.insetBy(dx: 6, dy: 4), xRadius: 7, yRadius: 7).fill()
            } else if audioMode == hoveredAudioMode {
                NSColor.white.withAlphaComponent(0.12).setFill()
                NSBezierPath(roundedRect: row.insetBy(dx: 6, dy: 4), xRadius: 7, yRadius: 7).fill()
            }

            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
            let title = audioMode.title
            let size = title.size(withAttributes: attributes)
            title.draw(at: CGPoint(x: row.minX + 14, y: row.midY - size.height / 2), withAttributes: attributes)
        }
    }

    private func drawMenuSectionTitle(_ title: String, at point: CGPoint) {
        title.draw(
            at: point,
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.white.withAlphaComponent(0.55)
            ]
        )
    }

    private func drawRecordButtonGroup(for rect: CGRect) {
        let mainFrame = buttonFrame(.record, for: rect)
        if isVideoQualityMenuOpen {
            NSColor.white.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: mainFrame, xRadius: 10, yRadius: 10).fill()
        }

        drawSymbol(.record, in: iconRect(in: mainFrame), color: NSColor.white.withAlphaComponent(0.88))
    }

    private func handleStylePanelClick(at point: CGPoint, selectionRect: CGRect) -> Bool {
        guard
            let tool = selectedTool,
            supportsStylePanel(tool),
            let panel = stylePanelFrame(for: selectionRect),
            panel.contains(point)
        else { return false }

        if sliderFrame(.size, in: panel).insetBy(dx: -10, dy: -12).contains(point) {
            if selectedAnnotationIndex != nil {
                registerUndo()
            }
            updateStyle(control: .size, at: point)
            dragMode = .adjustingStyle(control: .size)
            return true
        }

        if tool == .mosaic {
            return true
        }

        if sliderFrame(.opacity, in: panel).insetBy(dx: -10, dy: -12).contains(point) {
            if selectedAnnotationIndex != nil {
                registerUndo()
            }
            updateStyle(control: .opacity, at: point)
            dragMode = .adjustingStyle(control: .opacity)
            return true
        }

        if tool == .rectangle, fillToggleFrame(in: panel).insetBy(dx: -8, dy: -8).contains(point) {
            if selectedAnnotationIndex != nil {
                registerUndo()
            }
            rectangleStyle.filled.toggle()
            applyCurrentStyleToSelectedAnnotation()
            needsDisplay = true
            return true
        }

        for index in styleColors.indices where colorSwatchFrame(index: index, in: panel).insetBy(dx: -5, dy: -5).contains(point) {
            if selectedAnnotationIndex != nil {
                registerUndo()
            }
            var style = currentStyle(for: tool)
            style.color = styleColors[index]
            setCurrentStyle(style, for: tool)
            applyCurrentStyleToSelectedAnnotation()
            needsDisplay = true
            return true
        }

        return true
    }

    private func handleVideoQualityMenuClick(at point: CGPoint, selectionRect: CGRect) -> Bool {
        guard isVideoQualityMenuOpen, let panel = videoQualityMenuFrame(for: selectionRect), panel.contains(point) else {
            return false
        }

        for (index, audioMode) in VideoAudioMode.allCases.enumerated()
            where audioModeOptionFrame(index: index, in: panel).contains(point) {
            selectedAudioMode = audioMode
            needsDisplay = true
            return true
        }

        for (index, quality) in VideoQualityPreset.allCases.enumerated()
            where videoQualityOptionFrame(index: index, in: panel).contains(point) {
            selectedVideoQuality = quality
            isVideoQualityMenuOpen = false
            shortcutMenuButton = nil
            commitSelection(.recordVideo(quality: quality, audioMode: selectedAudioMode))
            return true
        }

        return true
    }

    private func stylePanelFrame(for rect: CGRect) -> CGRect? {
        guard let tool = selectedTool, supportsStylePanel(tool) else { return nil }
        let bar = toolbarFrame(for: rect)
        let height: CGFloat
        if tool == .mosaic {
            height = 58
        } else if tool == .rectangle {
            height = 130
        } else {
            height = 104
        }
        let size = CGSize(width: 300, height: height)
        let spacing: CGFloat = 8
        let toolbarIsAboveSelection = bar.minY >= rect.maxY
        var origin = CGPoint(x: bar.midX - size.width / 2, y: 0)

        if toolbarIsAboveSelection {
            origin.y = bar.maxY + spacing
            if origin.y + size.height > bounds.maxY - 10 {
                origin.y = max(bounds.minY + 10, rect.minY - size.height - spacing)
            }
        } else {
            origin.y = bar.minY - size.height - spacing
            if origin.y < bounds.minY + 10 {
                origin.y = min(bounds.maxY - size.height - 10, rect.maxY + spacing)
            }
        }

        origin.x = min(max(origin.x, bounds.minX + 10), bounds.maxX - size.width - 10)
        return CGRect(origin: origin, size: size)
    }

    private func sliderFrame(_ control: StyleControl, in panel: CGRect) -> CGRect {
        switch control {
        case .size:
            return CGRect(x: panel.minX + 74, y: panel.maxY - 23, width: 160, height: 12)
        case .opacity:
            return CGRect(x: panel.minX + 74, y: panel.maxY - 51, width: 160, height: 12)
        }
    }

    private func colorSwatchFrame(index: Int, in panel: CGRect) -> CGRect {
        CGRect(x: panel.minX + 14 + CGFloat(index) * 34, y: panel.minY + 12, width: 20, height: 20)
    }

    private func fillToggleFrame(in panel: CGRect) -> CGRect {
        CGRect(x: panel.minX + 74, y: panel.maxY - 82, width: 38, height: 18)
    }

    private func videoQualityMenuFrame(for rect: CGRect) -> CGRect? {
        let bar = toolbarFrame(for: rect)
        let qualityButton = buttonFrame(.record, for: rect)
        let size = CGSize(width: 174, height: 326)
        let spacing: CGFloat = 8
        let toolbarIsAboveSelection = bar.minY >= rect.maxY
        var origin = CGPoint(x: qualityButton.maxX - size.width, y: 0)

        if toolbarIsAboveSelection {
            origin.y = bar.maxY + spacing
            if origin.y + size.height > bounds.maxY - 10 {
                origin.y = max(bounds.minY + 10, bar.minY - size.height - spacing)
            }
        } else {
            origin.y = bar.minY - size.height - spacing
            if origin.y < bounds.minY + 10 {
                origin.y = min(bounds.maxY - size.height - 10, bar.maxY + spacing)
            }
        }

        origin.x = min(max(origin.x, bounds.minX + 10), bounds.maxX - size.width - 10)
        return CGRect(origin: origin, size: size)
    }

    private func videoQualityOptionFrame(index: Int, in panel: CGRect) -> CGRect {
        CGRect(
            x: panel.minX,
            y: panel.maxY - 34 - CGFloat(index + 1) * 30,
            width: panel.width,
            height: 30
        )
    }

    private func audioModeOptionFrame(index: Int, in panel: CGRect) -> CGRect {
        let top = panel.maxY - 34 - CGFloat(VideoQualityPreset.allCases.count) * 30 - 42
        return CGRect(
            x: panel.minX,
            y: top - CGFloat(index + 1) * 30,
            width: panel.width,
            height: 30
        )
    }

    private func videoQualityTitle(_ quality: VideoQualityPreset, for selectionRect: CGRect) -> String {
        guard quality == .native, let selection = captureSelection(for: selectionRect) else {
            return quality.title
        }
        let size = quality.outputPixelSize(for: selection)
        return "\(quality.title) (\(Int(size.width)) x \(Int(size.height)))"
    }

    private func captureSelection(for selectionRect: CGRect) -> CaptureSelection? {
        guard selectionRect.width >= 8, selectionRect.height >= 8, let window else { return nil }
        let originInWindow = convert(selectionRect.origin, to: nil)
        let maxPointInWindow = convert(CGPoint(x: selectionRect.maxX, y: selectionRect.maxY), to: nil)
        let origin = window.convertPoint(toScreen: originInWindow)
        let maxPoint = window.convertPoint(toScreen: maxPointInWindow)
        let rawScreenRect = CGRect(
            x: min(origin.x, maxPoint.x),
            y: min(origin.y, maxPoint.y),
            width: abs(maxPoint.x - origin.x),
            height: abs(maxPoint.y - origin.y)
        )
        let clippedScreenRect = rawScreenRect.intersection(targetScreen.frame)
        guard !clippedScreenRect.isNull, !clippedScreenRect.isEmpty else { return nil }
        let screenRect = clippedScreenRect
            .integral
            .intersection(targetScreen.frame)
        guard screenRect.width >= 8, screenRect.height >= 8 else { return nil }
        return CaptureSelection(rectInScreen: screenRect, screen: targetScreen)
    }

    private func drawButton(_ button: OverlayButton, in rect: CGRect, highlighted: Bool, enabled: Bool = true) {
        let busy = button == .ocr && isOCRBusy
        if highlighted || busy {
            let color = busy ? NSColor.white.withAlphaComponent(0.18) : NSColor.controlAccentColor.withAlphaComponent(0.88)
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
        }

        let iconColor: NSColor
        if highlighted {
            iconColor = .white
        } else if button == .cancel {
            iconColor = NSColor.white.withAlphaComponent(0.60)
        } else {
            iconColor = NSColor.white.withAlphaComponent(enabled ? 0.86 : 0.28)
        }

        switch button {
        case .ocr:
            drawOCRBadge(in: ocrBadgeRect(in: rect), busy: isOCRBusy)
        case .text:
            drawTextToolGlyph(in: iconRect(in: rect), color: iconColor)
        case .mosaic:
            drawMosaicToolGlyph(in: iconRect(in: rect), color: iconColor)
        case .longScreenshot:
            drawLongScreenshotGlyph(in: iconRect(in: rect), color: iconColor)
        case .copy, .save:
            drawSymbol(button, in: iconRect(in: rect), color: iconColor)
        default:
            drawSymbol(button, in: iconRect(in: rect), color: iconColor)
        }
    }

    private func iconRect(in rect: CGRect, size: CGFloat = 16) -> CGRect {
        CGRect(
            x: rect.midX - size / 2,
            y: rect.midY - size / 2,
            width: size,
            height: size
        )
    }

    private func ocrBadgeRect(in rect: CGRect) -> CGRect {
        CGRect(
            x: rect.midX - 12,
            y: rect.midY - 7,
            width: 24,
            height: 14
        )
    }

    private func drawButtonText(
        _ title: String,
        in rect: CGRect,
        alignment: NSTextAlignment = .center,
        color: NSColor = .white,
        font: NSFont = .systemFont(ofSize: 13, weight: .semibold)
    ) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        let size = title.size(withAttributes: attributes)
        let x = alignment == .left ? rect.minX : rect.midX - size.width / 2
        title.draw(at: CGPoint(x: x, y: rect.midY - size.height / 2), withAttributes: attributes)
    }

    private func drawTextToolGlyph(in rect: CGRect, color: NSColor) {
        drawButtonText(
            "T",
            in: rect,
            color: color,
            font: .systemFont(ofSize: 15, weight: .medium)
        )
    }

    private func drawMosaicToolGlyph(in rect: CGRect, color: NSColor) {
        let cell: CGFloat = 3.8
        let gap: CGFloat = 1.75
        let total = cell * 3 + gap * 2
        let origin = CGPoint(x: rect.midX - total / 2, y: rect.midY - total / 2)

        for row in 0..<3 {
            for column in 0..<3 {
                let rect = CGRect(
                    x: origin.x + CGFloat(column) * (cell + gap),
                    y: origin.y + CGFloat(row) * (cell + gap),
                    width: cell,
                    height: cell
                )
                let path = NSBezierPath(roundedRect: rect, xRadius: 1.0, yRadius: 1.0)
                color.withAlphaComponent((row + column).isMultiple(of: 2) ? 0.78 : 0.34).setFill()
                path.fill()
            }
        }
    }

    private func drawLongScreenshotGlyph(in rect: CGRect, color: NSColor) {
        let page = CGRect(x: rect.midX - 6, y: rect.midY - 8, width: 12, height: 16)
        color.withAlphaComponent(0.74).setStroke()
        let path = NSBezierPath(roundedRect: page, xRadius: 2.8, yRadius: 2.8)
        path.lineWidth = 1.35
        path.stroke()

        for index in 0..<3 {
            let y = page.maxY - 4.2 - CGFloat(index) * 3.2
            let line = NSBezierPath()
            line.lineWidth = 1.2
            line.lineCapStyle = .round
            line.move(to: CGPoint(x: page.minX + 3.1, y: y))
            line.line(to: CGPoint(x: page.maxX - 3.1, y: y))
            color.withAlphaComponent(0.38).setStroke()
            line.stroke()
        }

        let arrow = NSBezierPath()
        arrow.lineWidth = 1.45
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        arrow.move(to: CGPoint(x: page.midX, y: page.midY - 0.4))
        arrow.line(to: CGPoint(x: page.midX, y: page.minY + 4.2))
        arrow.move(to: CGPoint(x: page.midX - 3.1, y: page.minY + 6.9))
        arrow.line(to: CGPoint(x: page.midX, y: page.minY + 4.2))
        arrow.line(to: CGPoint(x: page.midX + 3.1, y: page.minY + 6.9))
        color.withAlphaComponent(0.92).setStroke()
        arrow.stroke()
    }

    private func drawOCRBadge(in rect: CGRect, busy: Bool) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 3.5, yRadius: 3.5)
        if busy {
            NSColor.white.withAlphaComponent(0.12).setFill()
            path.fill()
        }

        NSColor.white.withAlphaComponent(busy ? 0.72 : 0.46).setStroke()
        path.lineWidth = 1.1
        path.stroke()

        drawButtonText(
            busy ? "..." : "OCR",
            in: rect,
            color: NSColor.white.withAlphaComponent(busy ? 0.92 : 0.82),
            font: .monospacedDigitSystemFont(ofSize: 7.8, weight: .medium)
        )
    }

    private func drawToolbarTooltip(for selectionRect: CGRect) {
        guard let hoveredButton else { return }

        let frame = tooltipFrame(for: hoveredButton, selectionRect: selectionRect)
        drawFloatingPanelBackground(in: frame, radius: 9, alpha: 0.91)

        let title = tooltipTitle(for: hoveredButton)
        let shortcut = "快捷键 \(shortcutDisplay(for: hoveredButton))"
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.96)
        ]
        let shortcutAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.72),
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        let titleSize = title.size(withAttributes: titleAttributes)
        let shortcutSize = shortcut.size(withAttributes: shortcutAttributes)

        title.draw(
            at: CGPoint(x: frame.midX - titleSize.width / 2, y: frame.maxY - titleSize.height - 8),
            withAttributes: titleAttributes
        )
        shortcut.draw(
            at: CGPoint(x: frame.midX - shortcutSize.width / 2, y: frame.minY + 7),
            withAttributes: shortcutAttributes
        )
    }

    private func tooltipFrame(for button: OverlayButton, selectionRect: CGRect) -> CGRect {
        let buttonRect = buttonFrame(button, for: selectionRect)
        let title = tooltipTitle(for: button)
        let shortcut = "快捷键 \(shortcutDisplay(for: button))"
        let titleWidth = title.size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width
        let shortcutWidth = shortcut.size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)]).width
        let size = CGSize(width: max(titleWidth, shortcutWidth) + 24, height: 46)
        let spacing: CGFloat = 8
        var origin = CGPoint(
            x: buttonRect.midX - size.width / 2,
            y: buttonRect.maxY + spacing
        )
        if origin.y + size.height > bounds.maxY - 10 {
            origin.y = buttonRect.minY - size.height - spacing
        }
        origin.x = min(max(origin.x, bounds.minX + 10), bounds.maxX - size.width - 10)
        return CGRect(origin: origin, size: size)
    }

    private func tooltipShortcutFrame(for button: OverlayButton, selectionRect: CGRect) -> CGRect {
        let frame = tooltipFrame(for: button, selectionRect: selectionRect)
        return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 24)
    }

    private func drawShortcutLetterMenu(for selectionRect: CGRect) {
        guard let button = shortcutMenuButton else { return }
        let panel = shortcutMenuFrame(for: button, selectionRect: selectionRect)
        drawFloatingPanelBackground(in: panel, radius: 10, alpha: 0.92)

        for (index, option) in shortcutOptions.enumerated() {
            let cell = shortcutLetterFrame(index: index, in: panel)
            let owner = shortcutOwner(for: option.key)
            let disabled = owner != nil && owner != button
            if shortcutKey(for: button) == option.key {
                NSColor.controlAccentColor.withAlphaComponent(0.82).setFill()
                NSBezierPath(roundedRect: cell.insetBy(dx: 3, dy: 3), xRadius: 6, yRadius: 6).fill()
            } else if disabled {
                NSColor.white.withAlphaComponent(0.06).setFill()
                NSBezierPath(roundedRect: cell.insetBy(dx: 3, dy: 3), xRadius: 6, yRadius: 6).fill()
            }

            drawButtonText(
                option.display,
                in: cell,
                color: NSColor.white.withAlphaComponent(disabled ? 0.28 : 0.90),
                font: .systemFont(ofSize: option.display.count > 2 ? 9.5 : 10.5, weight: .semibold)
            )
        }

        let clearFrame = shortcutClearFrame(in: panel)
        NSColor.white.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: clearFrame, xRadius: 7, yRadius: 7).fill()
        drawButtonText(
            "清空快捷键",
            in: clearFrame,
            color: NSColor.white.withAlphaComponent(0.86),
            font: .systemFont(ofSize: 11, weight: .semibold)
        )
    }

    private func shortcutMenuFrame(for button: OverlayButton, selectionRect: CGRect) -> CGRect {
        let tooltip = tooltipFrame(for: button, selectionRect: selectionRect)
        let columns = 10
        let rows = Int(ceil(Double(shortcutOptions.count) / Double(columns)))
        let size = CGSize(width: 352, height: CGFloat(rows) * 26 + 42)
        let spacing: CGFloat = 8
        var origin = CGPoint(x: tooltip.midX - size.width / 2, y: tooltip.maxY + spacing)
        if origin.y + size.height > bounds.maxY - 10 {
            origin.y = tooltip.minY - size.height - spacing
        }
        origin.x = min(max(origin.x, bounds.minX + 10), bounds.maxX - size.width - 10)
        return CGRect(origin: origin, size: size)
    }

    private func shortcutClearFrame(in panel: CGRect) -> CGRect {
        CGRect(x: panel.minX + 8, y: panel.minY + 8, width: panel.width - 16, height: 24)
    }

    private func shortcutLetterFrame(index: Int, in panel: CGRect) -> CGRect {
        let columns = 10
        let column = index % columns
        let row = index / columns
        return CGRect(
            x: panel.minX + 8 + CGFloat(column) * 34,
            y: panel.maxY - 8 - CGFloat(row + 1) * 26,
            width: 32,
            height: 24
        )
    }

    private func drawSymbol(_ button: OverlayButton, in rect: CGRect, color: NSColor) {
        guard
            let symbolName = button.symbolName,
            let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15.2, weight: .medium))
        else {
            drawButtonText(button.title, in: rect)
            return
        }

        var proposedRect = rect
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            drawButtonText(button.title, in: rect)
            return
        }

        NSGraphicsContext.saveGraphicsState()
        guard let context = NSGraphicsContext.current?.cgContext else {
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        context.clip(to: rect, mask: cgImage)
        color.setFill()
        rect.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawDimensionBadge(for rect: CGRect) {
        let text = "\(Int(rect.width)) x \(Int(rect.height))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attributes)
        let badge = CGRect(x: rect.minX, y: min(bounds.maxY - size.height - 16, rect.maxY + 8), width: size.width + 18, height: size.height + 8)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 6, yRadius: 6).fill()
        text.draw(at: CGPoint(x: badge.minX + 9, y: badge.midY - size.height / 2), withAttributes: attributes)
    }

    private func drawInitialHint() {
        let text = "拖拽框选截图区域"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 20, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
    }

    private func handleButtonClick(at point: CGPoint, selectionRect: CGRect) -> Bool {
        for button in OverlayButton.allCases where buttonFrame(button, for: selectionRect).contains(point) {
            guard isButtonEnabled(button) else { return true }
            shortcutMenuButton = nil
            switch button {
            case .rectangle:
                selectTool(.rectangle)
            case .arrow:
                selectTool(.arrow)
            case .number:
                selectTool(.numberMarker)
            case .text:
                selectTool(.text)
            case .mosaic:
                selectTool(.mosaic)
            case .ocr:
                isVideoQualityMenuOpen = false
                runOCR()
            case .pin:
                isVideoQualityMenuOpen = false
                commitSelection(.pinToScreen)
            case .longScreenshot:
                isVideoQualityMenuOpen = false
                commitSelection(.longScreenshot)
            case .record:
                closeTransientPanels()
                selectedTool = nil
                selectedAnnotationIndex = nil
                shortcutMenuButton = nil
                isVideoQualityMenuOpen.toggle()
                needsDisplay = true
            case .recordQuality:
                break
            case .undo:
                undoEdit()
            case .redo:
                redoEdit()
            case .delete:
                deleteSelectedAnnotation()
            case .copy:
                isVideoQualityMenuOpen = false
                commitSelection(.copyToClipboard)
            case .save:
                isVideoQualityMenuOpen = false
                commitSelection(.saveToFile)
            case .cancel:
                closeTransientPanels()
                onCancel?()
            }
            return true
        }
        return false
    }

    private func selectTool(_ tool: AnnotationTool, toggles: Bool = true) {
        isVideoQualityMenuOpen = false
        shortcutMenuButton = nil
        if toggles, selectedTool == tool {
            selectedTool = nil
        } else {
            selectedTool = tool
            selectedAnnotationIndex = nil
        }
        if selectedTool == .mosaic {
            requestMosaicPreviewCaptureIfNeeded()
        }
        needsDisplay = true
    }

    private func setHoveredButton(_ button: OverlayButton?) {
        if button != nil {
            hoverClearWorkItem?.cancel()
            hoverClearWorkItem = nil
        }
        guard hoveredButton != button else { return }
        hoveredButton = button
        needsDisplay = true
    }

    private func scheduleHoveredButtonClear() {
        guard hoveredButton != nil, shortcutMenuButton == nil else { return }
        hoverClearWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.shortcutMenuButton == nil else { return }
            self.hoveredButton = nil
            self.needsDisplay = true
            self.hoverClearWorkItem = nil
        }
        hoverClearWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    private func updateRecordingMenuHover(at point: CGPoint, selectionRect: CGRect) {
        guard isVideoQualityMenuOpen, let panel = videoQualityMenuFrame(for: selectionRect), panel.contains(point) else {
            if hoveredVideoQuality != nil || hoveredAudioMode != nil {
                hoveredVideoQuality = nil
                hoveredAudioMode = nil
                needsDisplay = true
            }
            return
        }

        let nextQuality = VideoQualityPreset.allCases.enumerated().first {
            videoQualityOptionFrame(index: $0.offset, in: panel).contains(point)
        }?.element
        let nextAudioMode = VideoAudioMode.allCases.enumerated().first {
            audioModeOptionFrame(index: $0.offset, in: panel).contains(point)
        }?.element

        if hoveredVideoQuality != nextQuality || hoveredAudioMode != nextAudioMode {
            hoveredVideoQuality = nextQuality
            hoveredAudioMode = nextAudioMode
            needsDisplay = true
        }
    }

    private func hoveredToolbarButton(at point: CGPoint, selectionRect: CGRect) -> OverlayButton? {
        if let hoveredButton, tooltipFrame(for: hoveredButton, selectionRect: selectionRect).contains(point) {
            return hoveredButton
        }
        if let shortcutMenuButton, shortcutMenuFrame(for: shortcutMenuButton, selectionRect: selectionRect).contains(point) {
            return shortcutMenuButton
        }
        return OverlayButton.allCases.first { buttonFrame($0, for: selectionRect).contains(point) }
    }

    private func tooltipTitle(for button: OverlayButton) -> String {
        switch button {
        case .rectangle:
            return "框选"
        case .arrow:
            return "箭头"
        case .number:
            return "序号"
        case .text:
            return "文字"
        case .mosaic:
            return "马赛克"
        case .ocr:
            return "OCR 识别"
        case .pin:
            return "钉住到屏幕"
        case .longScreenshot:
            return "长截图"
        case .record:
            return "录制视频"
        case .recordQuality:
            return "选择清晰度"
        case .undo:
            return "撤销"
        case .redo:
            return "重做"
        case .delete:
            return "删除标注"
        case .copy:
            return "复制"
        case .save:
            return "保存"
        case .cancel:
            return "取消"
        }
    }

    private func shortcutDisplay(for button: OverlayButton) -> String {
        if let shortcut = shortcutKey(for: button) {
            return shortcutDisplayName(for: shortcut)
        }
        if clearedShortcuts.contains(button) {
            return "未设置"
        }
        switch button {
        case .rectangle:
            return "1"
        case .arrow:
            return "2"
        case .number:
            return "3"
        case .text:
            return "T"
        case .mosaic:
            return "5"
        case .ocr:
            return "6"
        case .pin:
            return "7"
        case .longScreenshot:
            return "8"
        case .record:
            return "9"
        case .undo:
            return "Cmd+Z"
        case .redo:
            return "Cmd+Shift+Z / Cmd+Y"
        case .delete:
            return "Delete"
        case .recordQuality:
            return "未设置"
        case .copy:
            return "Enter / Cmd+C"
        case .save:
            return "Space"
        case .cancel:
            return "Esc"
        }
    }

    private func shortcutKey(for button: OverlayButton) -> String? {
        if let custom = customShortcuts[button] {
            return custom
        }
        guard !clearedShortcuts.contains(button) else { return nil }
        return defaultShortcutKey(for: button)
    }

    private func shortcutOwner(for key: String) -> OverlayButton? {
        if let customOwner = customShortcuts.first(where: { $0.value == key })?.key {
            return customOwner
        }
        return OverlayButton.allCases.first { button in
            customShortcuts[button] == nil
                && !clearedShortcuts.contains(button)
                && defaultShortcutKey(for: button) == key
        }
    }

    private func setShortcut(_ key: String, for button: OverlayButton) {
        guard shortcutOwner(for: key).map({ $0 == button }) ?? true else { return }
        clearedShortcuts.remove(button)
        customShortcuts[button] = key
    }

    private func clearShortcut(for button: OverlayButton) {
        customShortcuts.removeValue(forKey: button)
        clearedShortcuts.insert(button)
    }

    private func handleToolbarShortcut(_ key: String) -> Bool {
        if let button = shortcutOwner(for: key) {
            performShortcutAction(button)
            return true
        }
        return false
    }

    private func shortcutKey(from event: NSEvent) -> String? {
        switch event.keyCode {
        case 36, 76:
            return "RETURN"
        case 48:
            return "TAB"
        case 49:
            return "SPACE"
        case 51, 117:
            return "DELETE"
        case 53:
            return "ESCAPE"
        case 115:
            return "HOME"
        case 119:
            return "END"
        case 116:
            return "PAGE_UP"
        case 121:
            return "PAGE_DOWN"
        case 123:
            return "LEFT"
        case 124:
            return "RIGHT"
        case 125:
            return "DOWN"
        case 126:
            return "UP"
        case 122:
            return "F1"
        case 120:
            return "F2"
        case 99:
            return "F3"
        case 118:
            return "F4"
        case 96:
            return "F5"
        case 97:
            return "F6"
        case 98:
            return "F7"
        case 100:
            return "F8"
        case 101:
            return "F9"
        case 109:
            return "F10"
        case 103:
            return "F11"
        case 111:
            return "F12"
        default:
            guard let characters = event.charactersIgnoringModifiers, characters.count == 1 else {
                return nil
            }
            return characters.uppercased()
        }
    }

    private func defaultShortcutKey(for button: OverlayButton) -> String? {
        switch button {
        case .rectangle:
            return "1"
        case .arrow:
            return "2"
        case .number:
            return "3"
        case .text:
            return "T"
        case .mosaic:
            return "5"
        case .ocr:
            return "6"
        case .pin:
            return "7"
        case .longScreenshot:
            return "8"
        case .record:
            return "9"
        case .copy:
            return "RETURN"
        case .save:
            return "SPACE"
        case .cancel:
            return "ESCAPE"
        case .recordQuality, .undo, .redo, .delete:
            return nil
        }
    }

    private func shortcutDisplayName(for key: String) -> String {
        shortcutOptions.first { $0.key == key }?.display ?? key
    }

    private func performShortcutAction(_ button: OverlayButton) {
        switch button {
        case .rectangle:
            selectTool(.rectangle, toggles: false)
        case .arrow:
            selectTool(.arrow, toggles: false)
        case .number:
            selectTool(.numberMarker, toggles: false)
        case .text:
            selectTool(.text, toggles: false)
        case .mosaic:
            selectTool(.mosaic, toggles: false)
        case .ocr:
            runOCR()
        case .pin:
            commitSelection(.pinToScreen)
        case .longScreenshot:
            commitSelection(.longScreenshot)
        case .record:
            closeTransientPanels()
            selectedTool = nil
            selectedAnnotationIndex = nil
            isVideoQualityMenuOpen.toggle()
            needsDisplay = true
        case .recordQuality:
            closeTransientPanels()
            selectedTool = nil
            selectedAnnotationIndex = nil
            isVideoQualityMenuOpen.toggle()
            needsDisplay = true
        case .undo:
            undoEdit()
        case .redo:
            redoEdit()
        case .delete:
            deleteSelectedAnnotation()
        case .copy:
            commitSelection(.copyToClipboard)
        case .save:
            commitSelection(.saveToFile)
        case .cancel:
            closeTransientPanels()
            onCancel?()
        }
    }

    private func handleTooltipShortcutClick(at point: CGPoint, selectionRect: CGRect) -> Bool {
        guard
            let hoveredButton,
            tooltipShortcutFrame(for: hoveredButton, selectionRect: selectionRect).contains(point)
        else { return false }

        shortcutMenuButton = hoveredButton
        isVideoQualityMenuOpen = false
        needsDisplay = true
        return true
    }

    private func handleShortcutMenuClick(at point: CGPoint, selectionRect: CGRect) -> Bool {
        guard let button = shortcutMenuButton else { return false }
        let panel = shortcutMenuFrame(for: button, selectionRect: selectionRect)
        if panel.contains(point) {
            if shortcutClearFrame(in: panel).contains(point) {
                clearShortcut(for: button)
                shortcutMenuButton = nil
                needsDisplay = true
                return true
            }

            for index in shortcutOptions.indices where shortcutLetterFrame(index: index, in: panel).contains(point) {
                let option = shortcutOptions[index]
                if let owner = shortcutOwner(for: option.key), owner != button {
                    return true
                }
                setShortcut(option.key, for: button)
                shortcutMenuButton = nil
                needsDisplay = true
                return true
            }
            return true
        }

        if let hoveredButton, tooltipFrame(for: hoveredButton, selectionRect: selectionRect).contains(point) {
            return false
        }

        shortcutMenuButton = nil
        needsDisplay = true
        return false
    }

    private func toolbarFrame(for rect: CGRect) -> CGRect {
        let size = toolbarSize()
        let usable = usableBounds()
        let spacing: CGFloat = 10
        let margin: CGFloat = 10
        let centeredX = rect.midX - size.width / 2
        let candidates = [
            CGPoint(x: centeredX, y: rect.minY - size.height - spacing),
            CGPoint(x: centeredX, y: rect.maxY + spacing),
            CGPoint(x: centeredX, y: rect.minY + 14),
            CGPoint(x: centeredX, y: rect.maxY - size.height - 14),
            CGPoint(x: usable.midX - size.width / 2, y: usable.minY + margin)
        ]

        var origin = candidates.first { candidate in
            usable.insetBy(dx: margin, dy: margin).contains(CGRect(origin: candidate, size: size))
        } ?? candidates.last ?? CGPoint(x: centeredX, y: usable.minY + margin)

        origin.x = min(max(origin.x, usable.minX + margin), usable.maxX - size.width - margin)
        origin.y = min(max(origin.y, usable.minY + margin), usable.maxY - size.height - margin)
        return CGRect(origin: origin, size: size)
    }

    private func toolbarSize() -> CGSize {
        let visibleButtons = OverlayButton.allCases.filter { $0 != .recordQuality }
        let contentWidth = visibleButtons.reduce(CGFloat.zero) { $0 + buttonWidth($1) }
        let spacing = CGFloat(max(0, visibleButtons.count - 1)) * toolbarButtonSpacing()
        return CGSize(width: ceil(toolbarHorizontalPadding() * 2 + contentWidth + spacing), height: 40)
    }

    private func usableBounds() -> CGRect {
        let visible = targetScreen.visibleFrame.offsetBy(
            dx: -targetScreen.frame.minX,
            dy: -targetScreen.frame.minY
        )
        let usable = bounds.intersection(visible)
        return usable.isNull || usable.isEmpty ? bounds : usable
    }

    private func buttonFrame(_ button: OverlayButton, for rect: CGRect) -> CGRect {
        let bar = toolbarFrame(for: rect)
        var x = bar.minX + toolbarHorizontalPadding()
        let y = bar.minY + 5

        for current in OverlayButton.allCases {
            if current == .record {
                if button == .record {
                    return CGRect(x: x, y: y, width: buttonWidth(.record), height: 30)
                }
                if button == .recordQuality {
                    return .zero
                }
                x += buttonWidth(.record) + toolbarButtonSpacing()
                continue
            }
            if current == .recordQuality {
                continue
            }

            let width = buttonWidth(current)
            if current == button {
                return CGRect(x: x, y: y, width: width, height: 30)
            }
            x += width + toolbarButtonSpacing()
        }

        return CGRect(x: x, y: y, width: 28, height: 30)
    }

    private func buttonWidth(_ button: OverlayButton) -> CGFloat {
        switch button {
        case .rectangle, .arrow, .number, .text, .mosaic, .ocr, .pin, .longScreenshot, .record, .undo, .redo, .delete, .copy, .save, .cancel:
            return 32
        case .recordQuality:
            return 0
        }
    }

    private func toolbarHorizontalPadding() -> CGFloat {
        7
    }

    private func toolbarButtonSpacing() -> CGFloat {
        4
    }

    private func tool(for button: OverlayButton) -> AnnotationTool? {
        switch button {
        case .rectangle: .rectangle
        case .arrow: .arrow
        case .number: .numberMarker
        case .mosaic: .mosaic
        case .text: .text
        case .ocr, .pin, .longScreenshot, .record, .recordQuality, .undo, .redo, .delete, .copy, .save, .cancel: nil
        }
    }

    private func supportsStylePanel(_ tool: AnnotationTool) -> Bool {
        switch tool {
        case .rectangle, .arrow, .numberMarker, .text, .mosaic:
            return true
        }
    }

    private func currentStyle(for tool: AnnotationTool) -> ToolStyle {
        switch tool {
        case .rectangle:
            return rectangleStyle
        case .arrow:
            return arrowStyle
        case .text:
            return textStyle
        case .numberMarker:
            return numberMarkerStyle
        case .mosaic:
            return ToolStyle(color: .white, size: mosaicBlockSize, opacity: 1)
        }
    }

    private func setCurrentStyle(_ style: ToolStyle, for tool: AnnotationTool) {
        switch tool {
        case .rectangle:
            rectangleStyle = style
        case .arrow:
            arrowStyle = style
        case .text:
            textStyle = style
        case .numberMarker:
            numberMarkerStyle = style
        case .mosaic:
            mosaicBlockSize = style.size
        }
    }

    private func styleSizeRange(for tool: AnnotationTool) -> ClosedRange<CGFloat> {
        switch tool {
        case .rectangle:
            return 1...12
        case .arrow:
            return 1...18
        case .text:
            return 12...48
        case .numberMarker:
            return 9...28
        case .mosaic:
            return 6...22
        }
    }

    private func updateStyle(control: StyleControl, at point: CGPoint) {
        guard
            let tool = selectedTool,
            supportsStylePanel(tool),
            let selectionRect,
            let panel = stylePanelFrame(for: selectionRect)
        else { return }

        var style = currentStyle(for: tool)
        switch control {
        case .size:
            let slider = sliderFrame(.size, in: panel)
            let range = styleSizeRange(for: tool)
            let progress = min(1, max(0, (point.x - slider.minX) / slider.width))
            style.size = round(range.lowerBound + (range.upperBound - range.lowerBound) * progress)
        case .opacity:
            let slider = sliderFrame(.opacity, in: panel)
            let progress = min(1, max(0, (point.x - slider.minX) / slider.width))
            style.opacity = max(0.1, round(progress * 100) / 100)
        }
        setCurrentStyle(style, for: tool)
        applyCurrentStyleToSelectedAnnotation()
    }

    private func effectiveColor(_ style: ToolStyle) -> NSColor {
        style.color.withAlphaComponent(style.opacity)
    }

    private func style(from color: NSColor, size: CGFloat) -> ToolStyle {
        let rgba = rgbaComponents(color)
        return ToolStyle(color: rgba.color, size: size, opacity: rgba.alpha)
    }

    private func colorsMatch(_ first: NSColor, _ second: NSColor) -> Bool {
        let a = rgbaComponents(first)
        let b = rgbaComponents(second)
        return abs(a.red - b.red) < 0.01
            && abs(a.green - b.green) < 0.01
            && abs(a.blue - b.blue) < 0.01
    }

    private func rgbaComponents(_ color: NSColor) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat, color: NSColor) {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        return (
            red: rgb.redComponent,
            green: rgb.greenComponent,
            blue: rgb.blueComponent,
            alpha: rgb.alphaComponent,
            color: NSColor(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent, alpha: 1)
        )
    }

    private func selectedTextAnnotationContains(_ point: CGPoint) -> Bool {
        guard
            let index = selectedAnnotationIndex,
            annotations.indices.contains(index),
            case .text = annotations[index]
        else {
            return false
        }
        return annotation(at: index, contains: point)
    }

    private func beginTextEdit(at index: Int) {
        guard annotations.indices.contains(index) else { return }
        guard case .text(let origin, let value, let color, let fontSize) = annotations[index] else { return }
        annotations.remove(at: index)
        selectedAnnotationIndex = nil
        selectedTool = .text
        textStyle = style(from: color, size: fontSize)
        beginTextEntry(at: origin, initialText: value, editingExisting: true)
        needsDisplay = true
    }

    private func beginTextEntry(at point: CGPoint, initialText: String, editingExisting: Bool = false) {
        commitActiveText()
        guard let selectionRect else { return }

        let absolute = CGPoint(x: selectionRect.minX + point.x, y: selectionRect.minY + point.y)
        let textView = NSTextView(frame: CGRect(x: absolute.x, y: absolute.y - 4, width: 80, height: 28))
        textView.delegate = self
        textView.font = .systemFont(ofSize: textStyle.size, weight: .semibold)
        textView.textColor = effectiveColor(textStyle)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.insertionPointColor = .systemRed
        textView.isRichText = false
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = []
        textView.minSize = CGSize(width: 24, height: 24)
        textView.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.lineBreakMode = .byClipping
        textView.textContainer?.containerSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.string = initialText
        addSubview(textView)

        activeTextView = textView
        activeTextOrigin = point
        activeTextIsEditingExisting = editingExisting
        window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
        textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
    }

    private func commitActiveText() {
        guard let textView = activeTextView else { return }
        let origin = activeTextOrigin ?? .zero
        let value = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let isEditingExisting = activeTextIsEditingExisting
        activeTextView = nil
        activeTextOrigin = nil
        activeTextIsEditingExisting = false
        textView.delegate = nil
        textView.removeFromSuperview()
        if !value.isEmpty {
            add(
                .text(origin: origin, value: value, color: effectiveColor(textStyle), fontSize: textStyle.size),
                registersUndo: !isEditingExisting
            )
            selectedAnnotationIndex = nil
        }
    }

    func textDidChange(_ notification: Notification) {
        guard let textView = activeTextView, let textContainer = textView.textContainer else { return }
        textView.layoutManager?.ensureLayout(for: textContainer)
        let used = textView.layoutManager?.usedRect(for: textContainer).size ?? textView.frame.size
        var frame = textView.frame
        let maxWidth = max(80, bounds.maxX - frame.minX - 12)
        frame.size.width = min(maxWidth, max(80, ceil(used.width) + 6))
        frame.size.height = max(28, ceil(used.height) + 6)
        textView.frame = frame
    }

    func textDidEndEditing(_ notification: Notification) {
        guard activeTextView != nil else { return }
        shouldIgnoreNextMouseDownAfterTextEndEditing = true
        commitActiveText()
    }

    private func runOCR() {
        guard !isOCRBusy, let selection = currentCaptureSelection(), let onOCRCapture else { return }
        isOCRBusy = true
        needsDisplay = true

        onOCRCapture(selection) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let capture):
                self.showOCRPanel(text: "OCR 识别中...")
                OCRService().recognizeText(in: capture.image) { [weak self] ocrResult in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.isOCRBusy = false
                        self.needsDisplay = true
                        switch ocrResult {
                        case .success(let lines):
                            self.updateOCRPanel(lines)
                        case .failure(let error):
                            self.showOCRPanel(text: "OCR 失败：\(error.localizedDescription)")
                        }
                    }
                }
            case .failure(let error):
                self.isOCRBusy = false
                self.needsDisplay = true
                self.showOCRPanel(text: "OCR 失败：\(error.localizedDescription)")
            }
        }
    }

    private func showOCRPanel(text: String) {
        ocrPanelController?.close()
        let panel = OCRResultPanelController(text: text)
        panel.onClose = { [weak self, weak panel] in
            guard let self, let panel, self.ocrPanelController === panel else { return }
            self.removeOCRDismissEventMonitor()
            self.ocrPanelController = nil
            self.window?.makeFirstResponder(self)
        }
        panel.onCopyAll = { [weak self] in
            self?.removeOCRDismissEventMonitor()
            self?.ocrPanelController = nil
            ToastWindowController.show(message: "复制成功")
            self?.window?.makeFirstResponder(self)
        }
        ocrPanelController = panel
        if let selectionRect {
            let origin = window?.convertPoint(toScreen: selectionRect.origin) ?? selectionRect.origin
            let maxPoint = window?.convertPoint(toScreen: CGPoint(x: selectionRect.maxX, y: selectionRect.maxY))
                ?? CGPoint(x: selectionRect.maxX, y: selectionRect.maxY)
            panel.position(near: CGRect(
                x: min(origin.x, maxPoint.x),
                y: min(origin.y, maxPoint.y),
                width: abs(maxPoint.x - origin.x),
                height: abs(maxPoint.y - origin.y)
            ))
        }
        panel.show()
        installOCRDismissEventMonitor()
    }

    private func updateOCRPanel(_ lines: [OCRLine]) {
        if lines.isEmpty {
            showOCRPanel(text: "未识别到文字")
            return
        }
        if ocrPanelController == nil {
            showOCRPanel(text: lines.map(\.text).joined(separator: "\n"))
        } else {
            ocrPanelController?.update(lines: lines)
        }
    }

    func closeTransientPanels() {
        isVideoQualityMenuOpen = false
        removeOCRDismissEventMonitor()
        ocrPanelController?.close()
        ocrPanelController = nil
    }

    private func installOCRDismissEventMonitor() {
        removeOCRDismissEventMonitor()
        ocrDismissEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, let panelWindow = self.ocrPanelController?.window else {
                return event
            }
            if event.window === panelWindow {
                return event
            }

            self.closeTransientPanels()
            self.needsDisplay = true
            return nil
        }
    }

    private func removeOCRDismissEventMonitor() {
        if let monitor = ocrDismissEventMonitor {
            NSEvent.removeMonitor(monitor)
            ocrDismissEventMonitor = nil
        }
    }

    private func relativePoint(_ point: CGPoint) -> CGPoint {
        guard let selectionRect else { return point }
        return CGPoint(x: point.x - selectionRect.minX, y: point.y - selectionRect.minY)
    }

    private func hitAnnotation(at point: CGPoint) -> DragMode? {
        for index in annotations.indices.reversed() where annotation(at: index, contains: point) {
            selectedAnnotationIndex = index
            adoptToolAndStyle(from: annotations[index])
            needsDisplay = true
            return .movingAnnotation(index: index, lastPoint: point)
        }
        selectedAnnotationIndex = nil
        return nil
    }

    private func hitSelectedAnnotationHandle(at point: CGPoint, index: Int) -> DragMode? {
        guard annotations.indices.contains(index) else { return nil }
        adoptToolAndStyle(from: annotations[index])
        let relative = relativePoint(point)
        switch annotations[index] {
        case .rectangle(let rect, _, _, _), .mosaic(let rect, _):
            if let handle = annotationRectangleHandleHit(at: relative, rect: rect) {
                return .resizingAnnotation(index: index, handle: handle)
            }
        case .arrow(let start, let end, _, _):
            if distance(relative, start) <= 10 {
                return .movingArrowEndpoint(index: index, endpoint: .start)
            }
            if distance(relative, end) <= 10 {
                return .movingArrowEndpoint(index: index, endpoint: .end)
            }
        case .numberMarker, .text:
            break
        }
        return nil
    }

    private func adoptToolAndStyle(from annotation: Annotation) {
        switch annotation {
        case .rectangle(_, let color, let lineWidth, let filled):
            selectedTool = .rectangle
            var style = style(from: color, size: lineWidth)
            style.filled = filled
            rectangleStyle = style
        case .arrow(_, _, let color, let lineWidth):
            selectedTool = .arrow
            arrowStyle = style(from: color, size: lineWidth)
        case .numberMarker(_, _, let color, let markerSize):
            selectedTool = .numberMarker
            numberMarkerStyle = style(from: color, size: markerSize)
        case .text(_, _, let color, let fontSize):
            selectedTool = .text
            textStyle = style(from: color, size: fontSize)
        case .mosaic(_, let blockSize):
            selectedTool = .mosaic
            mosaicBlockSize = blockSize
        }
    }

    private func annotation(at index: Int, contains point: CGPoint) -> Bool {
        switch annotations[index] {
        case .rectangle(let rect, _, _, _), .mosaic(let rect, _):
            return rect.insetBy(dx: -6, dy: -6).contains(point)
        case .arrow(let start, let end, _, _):
            return distanceFromPoint(point, toLineFrom: start, to: end) <= 7
                || distance(point, start) <= 10
                || distance(point, end) <= 10
        case .numberMarker(let center, _, _, let markerSize):
            return distance(point, center) <= max(16, markerSize + 4)
        case .text(let origin, let value, _, let fontSize):
            let size = AnnotationTextLayout.size(for: value, fontSize: fontSize)
            return CGRect(origin: origin, size: size).insetBy(dx: -6, dy: -6).contains(point)
        }
    }

    private func moveAnnotation(at index: Int, by delta: CGPoint) {
        guard annotations.indices.contains(index) else { return }
        switch annotations[index] {
        case .rectangle(let rect, let color, let lineWidth, let filled):
            annotations[index] = .rectangle(rect: rect.offsetBy(dx: delta.x, dy: delta.y), color: color, lineWidth: lineWidth, filled: filled)
        case .arrow(let start, let end, let color, let lineWidth):
            annotations[index] = .arrow(
                start: CGPoint(x: start.x + delta.x, y: start.y + delta.y),
                end: CGPoint(x: end.x + delta.x, y: end.y + delta.y),
                color: color,
                lineWidth: lineWidth
            )
        case .numberMarker(let center, let number, let color, let markerSize):
            annotations[index] = .numberMarker(
                center: CGPoint(x: center.x + delta.x, y: center.y + delta.y),
                number: number,
                color: color,
                markerSize: markerSize
            )
        case .text(let origin, let value, let color, let fontSize):
            annotations[index] = .text(origin: CGPoint(x: origin.x + delta.x, y: origin.y + delta.y), value: value, color: color, fontSize: fontSize)
        case .mosaic(let rect, let blockSize):
            annotations[index] = .mosaic(rect: rect.offsetBy(dx: delta.x, dy: delta.y), blockSize: blockSize)
        }
    }

    private func moveAllAnnotations(by delta: CGPoint) {
        guard delta.x != 0 || delta.y != 0 else { return }
        for index in annotations.indices {
            moveAnnotation(at: index, by: delta)
        }
    }

    private func applyCurrentStyleToSelectedAnnotation() {
        guard
            let tool = selectedTool,
            let index = selectedAnnotationIndex,
            annotations.indices.contains(index)
        else { return }

        switch (tool, annotations[index]) {
        case (.rectangle, .rectangle(let rect, _, _, _)):
            annotations[index] = .rectangle(rect: rect, color: effectiveColor(rectangleStyle), lineWidth: rectangleStyle.size, filled: rectangleStyle.filled)
        case (.arrow, .arrow(let start, let end, _, _)):
            annotations[index] = .arrow(start: start, end: end, color: effectiveColor(arrowStyle), lineWidth: arrowStyle.size)
        case (.numberMarker, .numberMarker(let center, let number, _, _)):
            annotations[index] = .numberMarker(center: center, number: number, color: effectiveColor(numberMarkerStyle), markerSize: numberMarkerStyle.size)
        case (.text, .text(let origin, let value, _, _)):
            annotations[index] = .text(origin: origin, value: value, color: effectiveColor(textStyle), fontSize: textStyle.size)
        case (.mosaic, .mosaic(let rect, _)):
            annotations[index] = .mosaic(rect: rect, blockSize: mosaicBlockSize)
            requestMosaicPreviewCaptureIfNeeded()
        default:
            break
        }
    }

    private func resizeAnnotationRectangle(at index: Int, handle: AnnotationRectHandle, to point: CGPoint) {
        guard annotations.indices.contains(index) else { return }
        let rect: CGRect
        switch annotations[index] {
        case .rectangle(let value, _, _, _), .mosaic(let value, _):
            rect = value
        default:
            return
        }
        var minX = rect.minX
        var maxX = rect.maxX
        var minY = rect.minY
        var maxY = rect.maxY
        switch handle {
        case .topLeft:
            minX = point.x
            minY = point.y
        case .topRight:
            maxX = point.x
            minY = point.y
        case .bottomLeft:
            minX = point.x
            maxY = point.y
        case .bottomRight:
            maxX = point.x
            maxY = point.y
        }
        let nextRect = CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
        switch annotations[index] {
        case .rectangle(_, let color, let lineWidth, let filled):
            annotations[index] = .rectangle(rect: nextRect, color: color, lineWidth: lineWidth, filled: filled)
        case .mosaic(_, let blockSize):
            annotations[index] = .mosaic(rect: nextRect, blockSize: blockSize)
        default:
            break
        }
    }

    private func moveArrowEndpoint(at index: Int, endpoint: ArrowEndpoint, to point: CGPoint) {
        guard annotations.indices.contains(index) else { return }
        guard case .arrow(let start, let end, let color, let lineWidth) = annotations[index] else { return }
        switch endpoint {
        case .start:
            annotations[index] = .arrow(start: point, end: end, color: color, lineWidth: lineWidth)
        case .end:
            annotations[index] = .arrow(start: start, end: point, color: color, lineWidth: lineWidth)
        }
    }

    private func drawSelectedAnnotationHandles() {
        guard let index = selectedAnnotationIndex, annotations.indices.contains(index) else { return }
        NSColor.white.setFill()
        NSColor.controlAccentColor.setStroke()
        switch annotations[index] {
        case .rectangle(let rect, _, _, _), .mosaic(let rect, _):
            for point in annotationRectangleHandlePoints(rect: rect) {
                drawSmallHandle(at: point)
            }
        case .arrow(let start, let end, _, _):
            drawSmallHandle(at: start)
            drawSmallHandle(at: end)
        case .numberMarker(let center, _, _, _):
            drawSmallHandle(at: center)
        case .text(let origin, _, _, _):
            drawSmallHandle(at: origin)
        }
    }

    private func annotationRectangleHandleHit(at point: CGPoint, rect: CGRect) -> AnnotationRectHandle? {
        let handles: [(AnnotationRectHandle, CGPoint)] = [
            (.topLeft, CGPoint(x: rect.minX, y: rect.minY)),
            (.topRight, CGPoint(x: rect.maxX, y: rect.minY)),
            (.bottomLeft, CGPoint(x: rect.minX, y: rect.maxY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY))
        ]
        return handles.first { distance(point, $0.1) <= 10 }?.0
    }

    private func annotationRectangleHandlePoints(rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.maxY)
        ]
    }

    private func drawSmallHandle(at point: CGPoint) {
        let rect = CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)
        let path = NSBezierPath(ovalIn: rect)
        path.fill()
        path.lineWidth = 1.5
        path.stroke()
    }

    private func handleHit(at point: CGPoint, rect: CGRect) -> RectHandle? {
        handlePoints(for: rect).first { _, handlePoint in
            hypot(point.x - handlePoint.x, point.y - handlePoint.y) <= 8
        }?.0
    }

    private func handlePoints(for rect: CGRect) -> [(RectHandle, CGPoint)] {
        [
            (.bottomLeft, CGPoint(x: rect.minX, y: rect.minY)),
            (.bottom, CGPoint(x: rect.midX, y: rect.minY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.minY)),
            (.right, CGPoint(x: rect.maxX, y: rect.midY)),
            (.topRight, CGPoint(x: rect.maxX, y: rect.maxY)),
            (.top, CGPoint(x: rect.midX, y: rect.maxY)),
            (.topLeft, CGPoint(x: rect.minX, y: rect.maxY)),
            (.left, CGPoint(x: rect.minX, y: rect.midY))
        ]
    }

    private func resized(_ rect: CGRect, handle: RectHandle, to point: CGPoint) -> CGRect {
        var minX = rect.minX
        var maxX = rect.maxX
        var minY = rect.minY
        var maxY = rect.maxY
        switch handle {
        case .topLeft:
            minX = point.x
            maxY = point.y
        case .top:
            maxY = point.y
        case .topRight:
            maxX = point.x
            maxY = point.y
        case .right:
            maxX = point.x
        case .bottomRight:
            maxX = point.x
            minY = point.y
        case .bottom:
            minY = point.y
        case .bottomLeft:
            minX = point.x
            minY = point.y
        case .left:
            minX = point.x
        }
        return CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
    }

    private func normalizedRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    private func setSelectionRect(_ nextRect: CGRect, keepingAnnotationsStationary: Bool) {
        let previousRect = selectionRect ?? nextRect
        if !rectsMatch(previousRect, nextRect) {
            invalidateMosaicPreview()
        }
        selectionRect = nextRect
        guard keepingAnnotationsStationary else { return }
        let appliedDelta = CGPoint(x: nextRect.minX - previousRect.minX, y: nextRect.minY - previousRect.minY)
        moveAllAnnotations(by: CGPoint(x: -appliedDelta.x, y: -appliedDelta.y))
    }

    private func clamped(_ rect: CGRect) -> CGRect {
        var result = rect
        if result.width > bounds.width { result.size.width = bounds.width }
        if result.height > bounds.height { result.size.height = bounds.height }
        result.origin.x = min(max(result.origin.x, bounds.minX), bounds.maxX - result.width)
        result.origin.y = min(max(result.origin.y, bounds.minY), bounds.maxY - result.height)
        return result
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private func distanceFromPoint(_ point: CGPoint, toLineFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let lengthSquared = pow(end.x - start.x, 2) + pow(end.y - start.y, 2)
        guard lengthSquared > 0 else { return distance(point, start) }
        let t = max(0, min(1, ((point.x - start.x) * (end.x - start.x) + (point.y - start.y) * (end.y - start.y)) / lengthSquared))
        let projection = CGPoint(x: start.x + t * (end.x - start.x), y: start.y + t * (end.y - start.y))
        return distance(point, projection)
    }
}
