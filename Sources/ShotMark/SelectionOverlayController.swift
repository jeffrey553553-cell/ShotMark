import AppKit

protocol SelectionOverlayControllerDelegate: AnyObject {
    func selectionOverlayController(_ controller: SelectionOverlayController, didCommit selection: CaptureSelection, frozenCapture: CaptureResult?, annotations: [Annotation], action: CaptureCommitAction)
    func selectionOverlayController(_ controller: SelectionOverlayController, didRequestOCRCapture selection: CaptureSelection, completion: @escaping (Result<CaptureResult, Error>) -> Void)
    func selectionOverlayControllerDidCancel(_ controller: SelectionOverlayController)
}

final class SelectionOverlayController {
    weak var delegate: SelectionOverlayControllerDelegate?
    private var windows: [NSWindow] = []
    private let frozenSnapshots: [ScreenSnapshot]
    private var activeSelectionView: SelectionOverlayView?
    private var interactionEventMonitor: Any?
    private let interactionGate = SelectionInteractionGate()

    init(frozenSnapshots: [ScreenSnapshot] = []) {
        self.frozenSnapshots = frozenSnapshots
    }

    func show() {
        NSApp.activate()
        windows = NSScreen.screens.map { screen in
            let view = SelectionOverlayView(screen: screen, frozenSnapshot: frozenSnapshot(for: screen))
            view.onCancel = { [weak self] in self?.cancel() }
            view.onInteractionStarted = { [weak self, weak view] in
                guard let self, let view else { return false }
                return self.activateSelectionView(view)
            }
            view.onCommit = { [weak self] selection, frozenCapture, annotations, action in
                guard let self else { return }
                self.closeWindows()
                self.delegate?.selectionOverlayController(
                    self,
                    didCommit: selection,
                    frozenCapture: frozenCapture,
                    annotations: annotations,
                    action: action
                )
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
        installInteractionEventMonitor()
        bringWindowsToFront()
    }

    func cancel() {
        closeWindows()
        delegate?.selectionOverlayControllerDidCancel(self)
    }

    private func closeWindows() {
        if let interactionEventMonitor {
            NSEvent.removeMonitor(interactionEventMonitor)
            self.interactionEventMonitor = nil
        }
        windows.forEach {
            ($0.contentView as? SelectionOverlayView)?.closeTransientPanels()
            $0.orderOut(nil)
        }
        windows.removeAll()
        activeSelectionView = nil
        interactionGate.reset()
    }

    @discardableResult
    private func activateSelectionView(_ view: SelectionOverlayView) -> Bool {
        guard interactionGate.claim(view) else {
            view.setInteractionLocked(true)
            if let activeSelectionView {
                activeSelectionView.window?.makeKeyAndOrderFront(nil)
                activeSelectionView.prepareForCaptureFocus()
            }
            return false
        }
        if let activeSelectionView, activeSelectionView !== view {
            activeSelectionView.window?.makeKeyAndOrderFront(nil)
            activeSelectionView.prepareForCaptureFocus()
            return false
        }
        activeSelectionView = view
        windows.forEach { window in
            guard let overlayView = window.contentView as? SelectionOverlayView else { return }
            overlayView.setInteractionLocked(overlayView !== view)
        }
        view.window?.makeKeyAndOrderFront(nil)
        view.prepareForCaptureFocus()
        return true
    }

    private func installInteractionEventMonitor() {
        if let interactionEventMonitor {
            NSEvent.removeMonitor(interactionEventMonitor)
        }
        interactionEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            guard let self else { return event }
            guard let eventWindow = event.window,
                  let eventView = eventWindow.contentView as? SelectionOverlayView,
                  self.windows.contains(where: { $0 === eventWindow }) else {
                return event
            }

            if let activeSelectionView = self.activeSelectionView {
                guard activeSelectionView === eventView else {
                    if event.type == .leftMouseDown {
                        activeSelectionView.window?.makeKeyAndOrderFront(nil)
                        activeSelectionView.prepareForCaptureFocus()
                    }
                    return nil
                }
                return event
            }

            guard event.type == .leftMouseDown else { return nil }
            return self.activateSelectionView(eventView) ? event : nil
        }
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

    private func frozenSnapshot(for screen: NSScreen) -> ScreenSnapshot? {
        frozenSnapshots.first { snapshot in
            if let snapshotDisplayID = snapshot.screen.shotMarkDisplayID,
               let screenDisplayID = screen.shotMarkDisplayID {
                return snapshotDisplayID == screenDisplayID
            }
            return snapshot.screen.frame == screen.frame
        }
    }
}

private final class SelectionOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class SelectionOverlayView: NSView, NSTextViewDelegate {
    var onCommit: ((CaptureSelection, CaptureResult?, [Annotation], CaptureCommitAction) -> Void)?
    var onOCRCapture: ((CaptureSelection, @escaping (Result<CaptureResult, Error>) -> Void) -> Void)?
    var onCancel: (() -> Void)?
    var onInteractionStarted: (() -> Bool)?

    private enum RectHandle {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    private enum AnnotationRectHandle {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    private enum ArrowEndpoint {
        case start, end
    }

    private enum StyleControl {
        case size, opacity, calloutLineWidth
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
        case pendingInitialSelection(start: CGPoint, candidate: WindowCandidate?)
        case drawingSelection(start: CGPoint)
        case movingSelection(startPoint: CGPoint, originalRect: CGRect)
        case resizingSelection(handle: RectHandle, originalRect: CGRect)
        case drawingRectangle(anchor: CGPoint, current: CGPoint, fromCenter: Bool, constrainedSquare: Bool)
        case drawingEllipse(anchor: CGPoint, current: CGPoint, fromCenter: Bool, constrainedSquare: Bool)
        case drawingMosaic(anchor: CGPoint, current: CGPoint, fromCenter: Bool, constrainedSquare: Bool)
        case drawingArrow(start: CGPoint, current: CGPoint)
        case drawingFreehand(points: [CGPoint])
        case drawingHighlighter(points: [CGPoint])
        case drawingCallout(anchor: CGPoint, current: CGPoint, fromCenter: Bool, constrainedSquare: Bool)
        case movingAnnotation(index: Int, lastPoint: CGPoint)
        case movingCalloutTarget(index: Int, lastPoint: CGPoint)
        case movingCalloutText(index: Int, lastPoint: CGPoint)
        case resizingAnnotation(index: Int, handle: AnnotationRectHandle)
        case movingArrowEndpoint(index: Int, endpoint: ArrowEndpoint)
        case adjustingStyle(control: StyleControl)
    }

    enum OverlayButton: CaseIterable, Hashable {
        case callout, rectangle, ellipse, arrow, pen, highlighter, number, text, mosaic, ocr, pin, longScreenshot, record, more, undo, redo, delete, copy, save, cancel

        static let toolbarOrder: [OverlayButton] = [
            .callout, .rectangle, .arrow, .number, .mosaic, .ocr, .pin, .longScreenshot, .record,
            .text, .more,
            .undo, .redo, .delete, .copy, .save, .cancel
        ]

        static let moreTools: [OverlayButton] = [.ellipse, .pen, .highlighter]

        var persistenceID: String {
            switch self {
            case .callout: "callout"
            case .rectangle: "rectangle"
            case .ellipse: "ellipse"
            case .arrow: "arrow"
            case .pen: "pen"
            case .highlighter: "highlighter"
            case .number: "number"
            case .text: "text"
            case .mosaic: "mosaic"
            case .ocr: "ocr"
            case .pin: "pin"
            case .longScreenshot: "longScreenshot"
            case .record: "record"
            case .more: "more"
            case .undo: "undo"
            case .redo: "redo"
            case .delete: "delete"
            case .copy: "copy"
            case .save: "save"
            case .cancel: "cancel"
            }
        }

        init?(persistenceID: String) {
            guard let button = Self.allCases.first(where: { $0.persistenceID == persistenceID }) else {
                return nil
            }
            self = button
        }

        var defaultShortcutKey: String? {
            switch self {
            case .callout: "1"
            case .rectangle: "2"
            case .arrow: "3"
            case .number: "4"
            case .mosaic: "5"
            case .ocr: "6"
            case .pin: "7"
            case .longScreenshot: "8"
            case .record: "9"
            case .ellipse: "E"
            case .pen: "P"
            case .highlighter: "H"
            case .text: "T"
            case .copy: "RETURN"
            case .save: "SPACE"
            case .cancel: "ESCAPE"
            case .more, .undo, .redo, .delete: nil
            }
        }

        var title: String {
            switch self {
            case .rectangle: "R"
            case .ellipse: "E"
            case .arrow: "A"
            case .pen: "P"
            case .highlighter: "H"
            case .number: "3"
            case .callout: "评"
            case .text: "T"
            case .mosaic: "M"
            case .ocr: "OCR"
            case .pin: "P"
            case .longScreenshot: "长"
            case .record: "录制"
            case .more: "更多"
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
            case .ellipse: "circle"
            case .arrow: "arrow.up.right"
            case .pen: "pencil.tip"
            case .highlighter: "highlighter"
            case .number: "3.circle"
            case .callout: "text.bubble"
            case .text: nil
            case .mosaic: nil
            case .ocr: nil
            case .pin: "pin"
            case .longScreenshot: nil
            case .record: "record.circle"
            case .more: "ellipsis"
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
    private let frozenSnapshot: ScreenSnapshot?
    private let frozenCaptureService = CaptureService()
    private let mosaicPreviewCaptureService = CaptureService()
    private let windowDetectionService = WindowDetectionService()
    private var selectionRect: CGRect?
    private var isInteractionLocked = false
    private var dragMode: DragMode?
    private var selectedTool: AnnotationTool?
    private var annotations: [Annotation] = []
    private var selectedAnnotationIndex: Int?
    private var nextMarkerNumber = 1
    private var activeTextView: NSTextView?
    private var activeTextOrigin: CGPoint?
    private var activeTextTopY: CGFloat?
    private var activeCalloutTextEditIndex: Int?
    private var activeCalloutOriginalAnnotation: Annotation?
    private var activeCalloutWasJustCreated = false
    private var ocrPanelController: OCRResultPanelController?
    private var ocrDismissEventMonitor: Any?
    private var isOCRBusy = false
    private var selectedAudioMode: VideoAudioMode = .none
    private var recordingShowsMouseClicks = AppSettings.shared.recordingShowsMouseClicks
    private var mosaicBlockSize: CGFloat = 12
    private var numberMarkerAppearance: NumberMarkerAppearance = .filled
    private var undoStack: [EditSnapshot] = []
    private var redoStack: [EditSnapshot] = []
    private var activeTextIsEditingExisting = false
    private var shouldIgnoreNextMouseDownAfterTextEndEditing = false
    private var pendingTextEditIndex: Int?
    private var pendingTextEditStart: CGPoint?
    private var pendingTextEditDidMove = false
    private var isRecordingMenuOpen = false
    private var isMoreMenuOpen = false
    private var hoveredAudioMode: VideoAudioMode?
    private var hoveredMoreTool: OverlayButton?
    private var isRecordingMouseClicksOptionHovered = false
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
    private var windowCandidates: [WindowCandidate] = []
    private var hoveredWindowCandidate: WindowCandidate?
    private var windowCandidateRefreshGeneration = 0
    private let selectionMagnifier = SelectionMagnifier()
    private var magnifierPoint: CGPoint?
    private var isMagnifierVisible = false
    private let initialSelectionDragThreshold: CGFloat = 5
    private var isWindowDebugEnabled: Bool {
        ProcessInfo.processInfo.environment["SHOTMARK_WINDOW_DEBUG"] == "1"
    }
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
    private var ellipseStyle = ToolStyle(color: .systemRed, size: 3, opacity: 1)
    private var arrowStyle = ToolStyle(color: .systemRed, size: 4, opacity: 1)
    private var penStyle = ToolStyle(color: .systemRed, size: 3, opacity: 1)
    private var highlighterStyle = ToolStyle(color: .systemYellow, size: 16, opacity: 0.35)
    private var numberMarkerStyle = ToolStyle(color: .systemRed, size: 13, opacity: 1)
    private var textStyle = ToolStyle(color: .systemRed, size: 18, opacity: 1)
    private let textInputMinSize = CGSize(width: 80, height: 28)
    private let calloutPlaceholderTextSize = CGSize(width: 96, height: 28)
    private let textInputPadding = CGSize(width: 6, height: 4)
    private let styleColors: [NSColor] = [
        .systemRed,
        .systemPink,
        .systemCyan,
        .systemYellow,
        .systemGreen,
        .white,
        .black
    ]

    init(screen: NSScreen, frozenSnapshot: ScreenSnapshot?) {
        targetScreen = screen
        self.frozenSnapshot = frozenSnapshot
        let shortcutPreferences = AppSettings.shared.toolbarShortcutPreferences
        customShortcuts = shortcutPreferences.overrides.reduce(into: [:]) { result, entry in
            guard let button = OverlayButton(persistenceID: entry.key) else { return }
            result[button] = entry.value
        }
        clearedShortcuts = Set(
            shortcutPreferences.clearedButtonIDs.compactMap(OverlayButton.init(persistenceID:))
        )
        super.init(frame: CGRect(origin: .zero, size: screen.frame.size))
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        windowCandidates = windowDetectionService.candidatesSynchronously(for: screen)
        refreshWindowCandidates()
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
        guard !isInteractionLocked else { return }
        window?.acceptsMouseMovedEvents = true
        window?.makeFirstResponder(self)
        refreshWindowCandidates()
        refreshWindowHoverUnderCurrentMouse()
    }

    func setInteractionLocked(_ locked: Bool) {
        guard isInteractionLocked != locked else { return }
        isInteractionLocked = locked
        if locked {
            dragMode = nil
            hoveredWindowCandidate = nil
            setHoveredButton(nil)
            closeTransientPanels()
            NSCursor.arrow.set()
        }
        needsDisplay = true
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
        guard !isInteractionLocked else { return }
        if activeTextView != nil {
            super.keyDown(with: event)
            return
        }

        let command = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)
        if event.keyCode == 53 {
            handleLayeredEscape()
            return
        }
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
        if handlePrecisionArrowKey(event) {
            return
        }

        if command, event.charactersIgnoringModifiers?.lowercased() == "c" {
            commitSelection(.copyToClipboard)
            return
        }

        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        guard !isInteractionLocked else { return }
        guard onInteractionStarted?() != false else { return }
        if !event.modifierFlags.contains(.command) {
            isMagnifierVisible = false
            magnifierPoint = nil
        }
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

        switch AnnotationInteractionPolicy.pointerDownResolution(
            hasActiveTextEditor: activeTextView != nil,
            isEditingCallout: activeCalloutTextEditIndex != nil
        ) {
        case .commitAndContinue:
            if activeTextView != nil {
                commitActiveText()
            }
            shouldIgnoreNextMouseDownAfterTextEndEditing = false
            window?.makeFirstResponder(self)
        case .commitAndConsume:
            commitActiveText()
            shouldIgnoreNextMouseDownAfterTextEndEditing = false
            window?.makeFirstResponder(self)
            needsDisplay = true
            return
        case .noActiveEditor:
            window?.makeFirstResponder(self)
        }

        if let selectionRect {
            if handleShortcutMenuClick(at: point, selectionRect: selectionRect) {
                return
            }
            if handleTooltipShortcutClick(at: point, selectionRect: selectionRect) {
                return
            }

            if handleRecordingMenuClick(at: point, selectionRect: selectionRect) {
                return
            }
            if isRecordingMenuOpen {
                isRecordingMenuOpen = false
                needsDisplay = true
            }

            if handleMoreMenuClick(at: point, selectionRect: selectionRect) {
                return
            }
            if isMoreMenuOpen {
                isMoreMenuOpen = false
                hoveredMoreTool = nil
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
                if event.clickCount >= 2, reattachCalloutArrowHead(for: drag) {
                    needsDisplay = true
                    return
                }
                dragMode = drag
                return
            }

            if selectionRect.contains(point) {
                let relative = relativePoint(point)
                let hadSelectedAnnotation = selectedAnnotationIndex != nil
                pendingTextEditIndex = nil
                pendingTextEditStart = nil
                pendingTextEditDidMove = false

                if selectedEditableTextAnnotationContains(relative), let selectedAnnotationIndex {
                    registerUndo()
                    pendingTextEditIndex = selectedAnnotationIndex
                    pendingTextEditStart = relative
                    if case .callout = annotations[selectedAnnotationIndex] {
                        dragMode = .movingCalloutText(index: selectedAnnotationIndex, lastPoint: relative)
                    } else {
                        dragMode = .movingAnnotation(index: selectedAnnotationIndex, lastPoint: relative)
                    }
                    return
                }

                if let drag = hitAnnotation(at: relative) {
                    registerUndo()
                    dragMode = drag
                    return
                }

                if AnnotationInteractionPolicy.shouldDeselectBeforeDrawing(
                    hasSelectedAnnotation: hadSelectedAnnotation,
                    didHitAnnotation: false
                ) {
                    selectedAnnotationIndex = nil
                    pendingTextEditIndex = nil
                    needsDisplay = true
                    return
                }

                if let selectedTool {
                    beginAnnotation(tool: selectedTool, at: relative, modifierFlags: event.modifierFlags)
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
        let initialCandidate = windowCandidate(at: point)
        hoveredWindowCandidate = initialCandidate
        dragMode = .pendingInitialSelection(start: point, candidate: initialCandidate)
        selectionRect = nil
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        guard !isInteractionLocked else { return }
        let mousePoint = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.command), frozenSnapshot != nil {
            magnifierPoint = mousePoint
            isMagnifierVisible = true
        } else if dragMode == nil {
            isMagnifierVisible = false
        }
        guard let selectionRect else {
            setHoveredButton(nil)
            updateHoveredWindowCandidate(at: mousePoint)
            needsDisplay = true
            return
        }

        hoveredWindowCandidate = nil
        updateRecordingMenuHover(at: mousePoint, selectionRect: selectionRect)
        updateMoreMenuHover(at: mousePoint, selectionRect: selectionRect)

        if isMoreMenuOpen,
           let panel = moreMenuFrame(for: selectionRect),
           panel.contains(mousePoint) {
            setHoveredButton(nil)
            NSCursor.pointingHand.set()
            needsDisplay = true
            return
        }

        if let button = hoveredToolbarButton(at: mousePoint, selectionRect: selectionRect) {
            setHoveredButton(button)
            NSCursor.pointingHand.set()
        } else {
            scheduleHoveredButtonClear()
            updateCanvasCursor(at: mousePoint, selectionRect: selectionRect)
        }
        needsDisplay = true
    }

    private func updateCanvasCursor(at point: CGPoint, selectionRect: CGRect) {
        guard selectionRect.contains(point) else {
            NSCursor.arrow.set()
            return
        }
        let relative = relativePoint(point)
        if let selectedAnnotationIndex,
           let handle = hitSelectedAnnotationHandle(at: point, index: selectedAnnotationIndex) {
            switch handle {
            case .resizingAnnotation(_, let rectHandle):
                cursor(for: rectHandle).set()
            case .movingArrowEndpoint:
                NSCursor.crosshair.set()
            default:
                NSCursor.openHand.set()
            }
            return
        }
        if
            let selectedAnnotationIndex,
            annotations.indices.contains(selectedAnnotationIndex),
            selectedEditableTextAnnotationContains(relative)
        {
            NSCursor.iBeam.set()
            return
        }
        if annotations.indices.reversed().contains(where: { annotation(at: $0, contains: relative) }) {
            NSCursor.openHand.set()
            return
        }
        if selectedTool != nil {
            NSCursor.crosshair.set()
        } else {
            NSCursor.openHand.set()
        }
    }

    private func cursor(for handle: AnnotationRectHandle) -> NSCursor {
        switch handle {
        case .top, .bottom:
            return .resizeUpDown
        case .left, .right:
            return .resizeLeftRight
        case .topLeft, .bottomRight:
            return .crosshair
        case .topRight, .bottomLeft:
            return .crosshair
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoveredWindowCandidate = nil
        if dragMode == nil {
            isMagnifierVisible = false
        }
        scheduleHoveredButtonClear()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isInteractionLocked else { return }
        let point = convert(event.locationInWindow, from: nil)
        let relative = relativePoint(point)
        let drawingPoint = clampedAnnotationPoint(relative)

        switch dragMode {
        case .pendingInitialSelection(let start, _):
            if distance(point, start) >= initialSelectionDragThreshold {
                hoveredWindowCandidate = nil
                selectionRect = AnnotationConstraintGeometry.constrainedRect(
                    anchor: start,
                    current: point,
                    constrainsToSquare: event.modifierFlags.contains(.shift),
                    drawsFromCenter: event.modifierFlags.contains(.option),
                    inside: bounds
                )
                dragMode = .drawingSelection(start: start)
                invalidateMosaicPreview()
            }
        case .drawingSelection(let start):
            selectionRect = AnnotationConstraintGeometry.constrainedRect(
                anchor: start,
                current: point,
                constrainsToSquare: event.modifierFlags.contains(.shift),
                drawsFromCenter: event.modifierFlags.contains(.option),
                inside: bounds
            )
            invalidateMosaicPreview()
        case .movingSelection(let startPoint, let originalRect):
            let delta = CGPoint(x: point.x - startPoint.x, y: point.y - startPoint.y)
            let nextRect = clamped(originalRect.offsetBy(dx: delta.x, dy: delta.y))
            setSelectionRect(nextRect, keepingAnnotationsStationary: true)
        case .resizingSelection(let handle, let originalRect):
            setSelectionRect(
                clamped(resized(
                    originalRect,
                    handle: handle,
                    to: point,
                    preservesAspectRatio: event.modifierFlags.contains(.shift)
                )),
                keepingAnnotationsStationary: true
            )
        case .drawingRectangle(let anchor, _, _, _):
            dragMode = .drawingRectangle(
                anchor: anchor,
                current: drawingPoint,
                fromCenter: event.modifierFlags.contains(.option),
                constrainedSquare: event.modifierFlags.contains(.shift)
            )
        case .drawingEllipse(let anchor, _, _, _):
            dragMode = .drawingEllipse(
                anchor: anchor,
                current: drawingPoint,
                fromCenter: event.modifierFlags.contains(.option),
                constrainedSquare: event.modifierFlags.contains(.shift)
            )
        case .drawingMosaic(let anchor, _, _, _):
            dragMode = .drawingMosaic(
                anchor: anchor,
                current: drawingPoint,
                fromCenter: event.modifierFlags.contains(.option),
                constrainedSquare: event.modifierFlags.contains(.shift)
            )
            requestMosaicPreviewCaptureIfNeeded()
        case .drawingArrow(let start, _):
            let current = event.modifierFlags.contains(.shift)
                ? clampedAnnotationPoint(AnnotationConstraintGeometry.snappedLineEndpoint(from: start, to: drawingPoint))
                : drawingPoint
            dragMode = .drawingArrow(start: start, current: current)
        case .drawingFreehand(var points):
            appendPathPoint(drawingPoint, to: &points)
            dragMode = .drawingFreehand(points: points)
        case .drawingHighlighter(var points):
            appendPathPoint(drawingPoint, to: &points)
            dragMode = .drawingHighlighter(points: points)
        case .drawingCallout(let anchor, _, _, _):
            dragMode = .drawingCallout(
                anchor: anchor,
                current: drawingPoint,
                fromCenter: event.modifierFlags.contains(.option),
                constrainedSquare: event.modifierFlags.contains(.shift)
            )
        case .movingAnnotation(let index, let lastPoint):
            if let start = pendingTextEditStart, distance(relative, start) > 3 {
                pendingTextEditDidMove = true
            }
            moveAnnotation(at: index, by: CGPoint(x: relative.x - lastPoint.x, y: relative.y - lastPoint.y))
            dragMode = .movingAnnotation(index: index, lastPoint: relative)
        case .movingCalloutTarget(let index, let lastPoint):
            moveCalloutTarget(at: index, by: CGPoint(x: relative.x - lastPoint.x, y: relative.y - lastPoint.y))
            dragMode = .movingCalloutTarget(index: index, lastPoint: relative)
        case .movingCalloutText(let index, let lastPoint):
            if let start = pendingTextEditStart, distance(relative, start) > 3 {
                pendingTextEditDidMove = true
            }
            moveCalloutText(at: index, by: CGPoint(x: relative.x - lastPoint.x, y: relative.y - lastPoint.y))
            dragMode = .movingCalloutText(index: index, lastPoint: relative)
        case .resizingAnnotation(let index, let handle):
            resizeAnnotationRectangle(
                at: index,
                handle: handle,
                to: relative,
                preservesAspectRatio: event.modifierFlags.contains(.shift)
            )
        case .movingArrowEndpoint(let index, let endpoint):
            moveArrowEndpoint(
                at: index,
                endpoint: endpoint,
                to: relative,
                snapsAngle: event.modifierFlags.contains(.shift)
            )
        case .adjustingStyle(let control):
            updateStyle(control: control, at: point)
        case nil:
            break
        }
        if shouldShowMagnifier(for: dragMode) {
            magnifierPoint = point
            isMagnifierVisible = frozenSnapshot != nil
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard !isInteractionLocked else { return }
        let point = clampedAnnotationPoint(
            relativePoint(convert(event.locationInWindow, from: nil))
        )
        let textEditIndex = pendingTextEditIndex
        let shouldBeginTextEdit = textEditIndex != nil && !pendingTextEditDidMove

        switch dragMode {
        case .pendingInitialSelection(_, let candidate):
            if let candidate {
                selectWindowCandidate(candidate)
            }
        case .drawingRectangle(let anchor, let current, let fromCenter, let constrainedSquare):
            let rect = annotationDrawingRect(
                anchor: anchor,
                current: current,
                fromCenter: fromCenter,
                constrainedSquare: constrainedSquare
            )
            if rect.width > 4, rect.height > 4 {
                add(.rectangle(rect: rect, color: effectiveColor(rectangleStyle), lineWidth: rectangleStyle.size, filled: rectangleStyle.filled))
            }
        case .drawingEllipse(let anchor, let current, let fromCenter, let constrainedSquare):
            let rect = annotationDrawingRect(
                anchor: anchor,
                current: current,
                fromCenter: fromCenter,
                constrainedSquare: constrainedSquare
            )
            if rect.width > 4, rect.height > 4 {
                add(.ellipse(rect: rect, color: effectiveColor(ellipseStyle), lineWidth: ellipseStyle.size, filled: ellipseStyle.filled))
            }
        case .drawingMosaic(let anchor, let current, let fromCenter, let constrainedSquare):
            let rect = annotationDrawingRect(
                anchor: anchor,
                current: current,
                fromCenter: fromCenter,
                constrainedSquare: constrainedSquare
            )
            if rect.width > 4, rect.height > 4 {
                add(.mosaic(rect: rect, blockSize: mosaicBlockSize))
                requestMosaicPreviewCaptureIfNeeded()
            }
        case .drawingArrow(let start, let current):
            if hypot(current.x - start.x, current.y - start.y) > 4 {
                add(.arrow(start: start, end: current, color: effectiveColor(arrowStyle), lineWidth: arrowStyle.size))
            }
        case .drawingFreehand(var points):
            appendPathPoint(point, to: &points, minimumDistance: 0.01)
            if points.count > 1 {
                add(.freehand(points: points, color: effectiveColor(penStyle), lineWidth: penStyle.size))
            }
        case .drawingHighlighter(var points):
            appendPathPoint(point, to: &points, minimumDistance: 0.01)
            if points.count > 1 {
                add(.highlighter(points: points, color: effectiveColor(highlighterStyle), lineWidth: highlighterStyle.size))
            }
        case .drawingCallout(let anchor, let current, let fromCenter, let constrainedSquare):
            let rect = annotationDrawingRect(
                anchor: anchor,
                current: current,
                fromCenter: fromCenter,
                constrainedSquare: constrainedSquare
            )
            if rect.width > 8, rect.height > 8 {
                addCallout(targetRect: rect)
            }
        case .drawingSelection, .movingSelection, .resizingSelection, .movingAnnotation,
             .movingCalloutTarget, .movingCalloutText, .resizingAnnotation,
             .movingArrowEndpoint, .adjustingStyle, nil:
            break
        }

        dragMode = nil
        isMagnifierVisible = false
        magnifierPoint = nil
        pendingTextEditIndex = nil
        pendingTextEditStart = nil
        pendingTextEditDidMove = false
        NSCursor.arrow.set()
        if let rect = selectionRect, rect.width < 8 || rect.height < 8 {
            selectionRect = nil
            annotations.removeAll()
        }
        if shouldBeginTextEdit, let textEditIndex {
            beginTextEditLikeAnnotation(at: textEditIndex)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let hoverRect = selectionRect == nil ? hoveredWindowCandidate?.localRect : nil
        if frozenSnapshot != nil {
            drawFrozenSnapshot()
            drawDimmingOverlay(excluding: selectionRect ?? hoverRect)
        } else {
            drawDimmingOverlay(excluding: selectionRect ?? hoverRect)
        }

        guard !isInteractionLocked else { return }
        guard let selectionRect else {
            drawWindowCandidateDebugOverlay()
            if let hoveredWindowCandidate {
                drawWindowCandidateHover(hoveredWindowCandidate)
            }
            drawInitialHint()
            drawSelectionMagnifierIfNeeded()
            return
        }

        requestMosaicPreviewCaptureIfNeeded()
        if frozenSnapshot == nil {
            NSColor.clear.setFill()
            selectionRect.fill(using: .clear)
        }
        drawSelectionFrame(selectionRect)
        drawAnnotations(in: selectionRect)
        drawDimensionBadge(for: selectionRect)
        drawToolbar(for: selectionRect)
        drawStylePanel(for: selectionRect)
        drawRecordingMenu(for: selectionRect)
        drawMoreMenu(for: selectionRect)
        drawToolbarTooltip(for: selectionRect)
        drawShortcutLetterMenu(for: selectionRect)
        drawSelectionMagnifierIfNeeded()
    }

    override func scrollWheel(with event: NSEvent) {
        guard !isInteractionLocked,
              event.modifierFlags.contains(.command),
              frozenSnapshot != nil else {
            super.scrollWheel(with: event)
            return
        }
        let delta = abs(event.scrollingDeltaY) >= abs(event.deltaY) ? event.scrollingDeltaY : event.deltaY
        guard abs(delta) > 0.01 else { return }
        _ = selectionMagnifier.adjustZoom(
            scrollDelta: delta,
            hasPreciseDeltas: event.hasPreciseScrollingDeltas
        )
        magnifierPoint = convert(event.locationInWindow, from: nil)
        isMagnifierVisible = true
        needsDisplay = true
    }

    private func drawFrozenSnapshot() {
        guard let frozenSnapshot else { return }
        NSGraphicsContext.current?.imageInterpolation = .high
        let image = NSImage(cgImage: frozenSnapshot.image, size: bounds.size)
        image.draw(
            in: bounds,
            from: .zero,
            operation: .copy,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
    }

    private func drawSelectionMagnifierIfNeeded() {
        guard isMagnifierVisible, let magnifierPoint, let frozenSnapshot else { return }
        var avoidedRects: [CGRect] = []
        if let selectionRect {
            avoidedRects.append(toolbarFrame(for: selectionRect))
            if let stylePanel = stylePanelFrame(for: selectionRect) {
                avoidedRects.append(stylePanel)
            }
        }
        selectionMagnifier.draw(
            at: magnifierPoint,
            in: bounds,
            snapshot: frozenSnapshot,
            avoiding: avoidedRects
        )
    }

    private func shouldShowMagnifier(for dragMode: DragMode?) -> Bool {
        switch dragMode {
        case .pendingInitialSelection, .drawingSelection, .resizingSelection:
            return true
        case .movingSelection, .drawingRectangle, .drawingEllipse, .drawingMosaic, .drawingArrow,
             .drawingFreehand, .drawingHighlighter, .drawingCallout, .movingAnnotation,
             .movingCalloutTarget, .movingCalloutText, .resizingAnnotation,
             .movingArrowEndpoint, .adjustingStyle, nil:
            return false
        }
    }

    private func handlePrecisionArrowKey(_ event: NSEvent) -> Bool {
        guard !event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.control),
              let direction = arrowDirection(for: event.keyCode),
              let selectionRect else {
            return false
        }

        let pixelStep = SelectionPrecisionGeometry.pixelStep(
            for: frozenSnapshot?.screenScale ?? targetScreen.backingScaleFactor
        )
        if let selectedAnnotationIndex, annotations.indices.contains(selectedAnnotationIndex) {
            registerUndo()
            let distance = event.modifierFlags.contains(.shift) ? pixelStep * 10 : pixelStep
            let delta: CGPoint
            switch direction {
            case .left: delta = CGPoint(x: -distance, y: 0)
            case .right: delta = CGPoint(x: distance, y: 0)
            case .down: delta = CGPoint(x: 0, y: -distance)
            case .up: delta = CGPoint(x: 0, y: distance)
            }
            moveAnnotation(at: selectedAnnotationIndex, by: delta)
        } else if event.modifierFlags.contains(.shift) {
            registerUndo()
            let next = SelectionPrecisionGeometry.resized(
                selectionRect,
                direction: direction,
                distance: pixelStep,
                minimumSize: 8,
                inside: bounds
            )
            setSelectionRect(next, keepingAnnotationsStationary: true)
        } else {
            registerUndo()
            let next = SelectionPrecisionGeometry.moved(
                selectionRect,
                direction: direction,
                distance: pixelStep,
                inside: bounds
            )
            setSelectionRect(next, keepingAnnotationsStationary: true)
        }
        needsDisplay = true
        return true
    }

    private func arrowDirection(for keyCode: UInt16) -> SelectionArrowDirection? {
        switch keyCode {
        case 123: .left
        case 124: .right
        case 125: .down
        case 126: .up
        default: nil
        }
    }

    private func drawDimmingOverlay(excluding rect: CGRect?) {
        NSColor.black.withAlphaComponent(0.50).setFill()
        guard let rect else {
            bounds.fill()
            return
        }

        let clipped = rect.intersection(bounds)
        guard !clipped.isNull, !clipped.isEmpty else {
            bounds.fill()
            return
        }

        CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: max(0, clipped.minY - bounds.minY)).fill()
        CGRect(x: bounds.minX, y: clipped.maxY, width: bounds.width, height: max(0, bounds.maxY - clipped.maxY)).fill()
        CGRect(x: bounds.minX, y: clipped.minY, width: max(0, clipped.minX - bounds.minX), height: clipped.height).fill()
        CGRect(x: clipped.maxX, y: clipped.minY, width: max(0, bounds.maxX - clipped.maxX), height: clipped.height).fill()
    }

    private func beginAnnotation(
        tool: AnnotationTool,
        at point: CGPoint,
        modifierFlags: NSEvent.ModifierFlags
    ) {
        let fromCenter = modifierFlags.contains(.option)
        let constrainedSquare = modifierFlags.contains(.shift)
        switch tool {
        case .rectangle:
            dragMode = .drawingRectangle(
                anchor: point,
                current: point,
                fromCenter: fromCenter,
                constrainedSquare: constrainedSquare
            )
        case .ellipse:
            dragMode = .drawingEllipse(
                anchor: point,
                current: point,
                fromCenter: fromCenter,
                constrainedSquare: constrainedSquare
            )
        case .arrow:
            dragMode = .drawingArrow(start: point, current: point)
        case .pen:
            dragMode = .drawingFreehand(points: [point])
        case .highlighter:
            dragMode = .drawingHighlighter(points: [point])
        case .mosaic:
            dragMode = .drawingMosaic(
                anchor: point,
                current: point,
                fromCenter: fromCenter,
                constrainedSquare: constrainedSquare
            )
            requestMosaicPreviewCaptureIfNeeded()
        case .numberMarker:
            let canvas = CGRect(origin: .zero, size: selectionRect?.size ?? bounds.size)
            add(.numberMarker(
                center: AnnotationGeometry.numberMarkerCenter(
                    forPointer: point,
                    markerSize: numberMarkerStyle.size,
                    inside: canvas
                ),
                number: nextMarkerNumber,
                color: effectiveColor(numberMarkerStyle),
                markerSize: numberMarkerStyle.size,
                appearance: numberMarkerAppearance
            ))
            nextMarkerNumber += 1
        case .text:
            beginTextEntry(at: point, initialText: "")
        case .callout:
            dragMode = .drawingCallout(
                anchor: point,
                current: point,
                fromCenter: fromCenter,
                constrainedSquare: constrainedSquare
            )
        }
    }

    private func addCallout(targetRect: CGRect) {
        guard let selectionRect else { return }
        registerUndo()
        let layout = AnnotationGeometry.calloutLayout(
            for: targetRect,
            in: CGRect(origin: .zero, size: selectionRect.size),
            textSize: calloutPlaceholderTextSize
        )
        let annotation = Annotation.callout(
            targetRect: targetRect,
            arrowStart: layout.arrowStart,
            arrowEnd: layout.arrowEnd,
            textOrigin: layout.textOrigin,
            text: "",
            color: effectiveColor(textStyle),
            lineWidth: max(2, arrowStyle.size),
            fontSize: textStyle.size
        )
        annotations.append(annotation)
        selectedAnnotationIndex = annotations.count - 1
        selectedTool = .callout
        beginCalloutTextEdit(
            at: annotations.count - 1,
            registersUndo: false,
            wasJustCreated: true
        )
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
        onCommit?(selection, frozenCapture(for: selection), annotations, action)
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

        if let capture = frozenCapture(for: selection) {
            mosaicPreviewImage = capture.image
            mosaicPreviewRect = selectionRect
            needsDisplay = true
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

        let drawableAnnotations = annotationsForDrawing()
        drawMosaicAnnotations(drawableAnnotations, in: selectionRect.size)
        AnnotationDrawing.draw(drawableAnnotations.filter { !$0.isMosaic }, in: selectionRect.size)
        drawSelectedAnnotationHandles()

        switch dragMode {
        case .pendingInitialSelection:
            break
        case .drawingRectangle(let anchor, let current, let fromCenter, let constrainedSquare):
            let rect = annotationDrawingRect(
                anchor: anchor,
                current: current,
                fromCenter: fromCenter,
                constrainedSquare: constrainedSquare
            )
            AnnotationDrawing.draw([.rectangle(rect: rect, color: effectiveColor(rectangleStyle), lineWidth: rectangleStyle.size, filled: rectangleStyle.filled)], in: selectionRect.size)
            drawAnnotationMeasurementBadge(text: dimensionText(for: rect), near: CGPoint(x: rect.maxX, y: rect.maxY), inside: selectionRect.size)
        case .drawingEllipse(let anchor, let current, let fromCenter, let constrainedSquare):
            let rect = annotationDrawingRect(
                anchor: anchor,
                current: current,
                fromCenter: fromCenter,
                constrainedSquare: constrainedSquare
            )
            AnnotationDrawing.draw([.ellipse(rect: rect, color: effectiveColor(ellipseStyle), lineWidth: ellipseStyle.size, filled: ellipseStyle.filled)], in: selectionRect.size)
            drawAnnotationMeasurementBadge(text: dimensionText(for: rect), near: CGPoint(x: rect.maxX, y: rect.maxY), inside: selectionRect.size)
        case .drawingMosaic(let anchor, let current, let fromCenter, let constrainedSquare):
            let rect = annotationDrawingRect(
                anchor: anchor,
                current: current,
                fromCenter: fromCenter,
                constrainedSquare: constrainedSquare
            )
            drawMosaic(rect: rect, blockSize: mosaicBlockSize, pointSize: selectionRect.size)
            drawAnnotationMeasurementBadge(text: dimensionText(for: rect), near: CGPoint(x: rect.maxX, y: rect.maxY), inside: selectionRect.size)
        case .drawingArrow(let start, let current):
            AnnotationDrawing.draw([.arrow(start: start, end: current, color: effectiveColor(arrowStyle), lineWidth: arrowStyle.size)], in: selectionRect.size)
            let measurement = AnnotationConstraintGeometry.lineMeasurement(from: start, to: current)
            drawAnnotationMeasurementBadge(
                text: "\(Int(measurement.length.rounded())) px · \(Int(measurement.angleDegrees.rounded()))°",
                near: current,
                inside: selectionRect.size
            )
        case .drawingFreehand(let points):
            AnnotationDrawing.draw([.freehand(points: points, color: effectiveColor(penStyle), lineWidth: penStyle.size)], in: selectionRect.size)
        case .drawingHighlighter(let points):
            AnnotationDrawing.draw([.highlighter(points: points, color: effectiveColor(highlighterStyle), lineWidth: highlighterStyle.size)], in: selectionRect.size)
        case .drawingCallout(let anchor, let current, let fromCenter, let constrainedSquare):
            let rect = annotationDrawingRect(
                anchor: anchor,
                current: current,
                fromCenter: fromCenter,
                constrainedSquare: constrainedSquare
            )
            AnnotationDrawing.draw([.rectangle(rect: rect, color: effectiveColor(rectangleStyle), lineWidth: rectangleStyle.size, filled: false)], in: selectionRect.size)
            drawAnnotationMeasurementBadge(text: dimensionText(for: rect), near: CGPoint(x: rect.maxX, y: rect.maxY), inside: selectionRect.size)
        case .resizingAnnotation(let index, _):
            drawResizableAnnotationMeasurement(at: index, inside: selectionRect.size)
        case .movingArrowEndpoint(let index, _):
            drawArrowAnnotationMeasurement(at: index, inside: selectionRect.size)
        case .drawingSelection, .movingSelection, .resizingSelection, .movingAnnotation,
             .movingCalloutTarget, .movingCalloutText, .adjustingStyle, nil:
            break
        }

        NSGraphicsContext.restoreGraphicsState()
    }

    private func annotationsForDrawing() -> [Annotation] {
        guard let activeCalloutTextEditIndex else { return annotations }
        return annotations.enumerated().map { index, annotation in
            guard index == activeCalloutTextEditIndex else { return annotation }
            guard case .callout(
                let targetRect,
                let arrowStart,
                let arrowEnd,
                let textOrigin,
                _,
                let color,
                let lineWidth,
                let fontSize
            ) = annotation else {
                return annotation
            }
            return .callout(
                targetRect: targetRect,
                arrowStart: arrowStart,
                arrowEnd: arrowEnd,
                textOrigin: textOrigin,
                text: "",
                color: color,
                lineWidth: lineWidth,
                fontSize: fontSize
            )
        }
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

        for button in OverlayButton.toolbarOrder {
            if button == .record {
                drawRecordButtonGroup(for: rect)
                continue
            }

            let highlighted: Bool
            if button == .more {
                highlighted = isMoreMenuOpen || OverlayButton.moreTools.contains {
                    tool(for: $0) == selectedTool
                }
            } else {
                highlighted = tool(for: button).map { $0 == selectedTool } ?? false
            }
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
        default:
            return true
        }
    }

    private func drawStylePanel(for rect: CGRect) {
        guard !isMoreMenuOpen else { return }
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

        let sizeLabel = tool == .text || tool == .callout
            ? "字号"
            : (tool == .mosaic ? "强度" : "大小")
        sizeLabel.draw(at: CGPoint(x: panel.minX + 14, y: panel.maxY - 26), withAttributes: labelAttributes)
        "\(Int(round(style.size)))".draw(at: CGPoint(x: panel.maxX - 38, y: panel.maxY - 26), withAttributes: valueAttributes)
        drawSlider(in: sliderFrame(.size, in: panel), value: style.size, range: styleSizeRange(for: tool))

        if tool == .mosaic {
            return
        }

        "不透明度".draw(at: CGPoint(x: panel.minX + 14, y: panel.maxY - 54), withAttributes: labelAttributes)
        "\(Int(round(style.opacity * 100)))".draw(at: CGPoint(x: panel.maxX - 42, y: panel.maxY - 54), withAttributes: valueAttributes)
        drawSlider(in: sliderFrame(.opacity, in: panel), value: style.opacity, range: 0.1...1)

        if tool == .callout {
            "线宽".draw(at: CGPoint(x: panel.minX + 14, y: panel.maxY - 82), withAttributes: labelAttributes)
            "\(Int(round(arrowStyle.size)))".draw(
                at: CGPoint(x: panel.maxX - 38, y: panel.maxY - 82),
                withAttributes: valueAttributes
            )
            drawSlider(
                in: sliderFrame(.calloutLineWidth, in: panel),
                value: arrowStyle.size,
                range: 2...10
            )
        } else if tool == .rectangle || tool == .ellipse {
            "填充".draw(at: CGPoint(x: panel.minX + 14, y: panel.maxY - 84), withAttributes: labelAttributes)
            drawFillToggle(in: fillToggleFrame(in: panel), isOn: style.filled)
        } else if tool == .numberMarker {
            "样式".draw(at: CGPoint(x: panel.minX + 14, y: panel.maxY - 84), withAttributes: labelAttributes)
            drawNumberMarkerAppearanceSelector(in: panel)
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

    private func drawNumberMarkerAppearanceSelector(in panel: CGRect) {
        for (index, appearance) in NumberMarkerAppearance.allCases.enumerated() {
            let frame = numberMarkerAppearanceFrame(index: index, in: panel)
            if appearance == numberMarkerAppearance {
                NSColor.white.withAlphaComponent(0.16).setFill()
                NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6).fill()
                NSColor.white.withAlphaComponent(0.42).setStroke()
                let border = NSBezierPath(
                    roundedRect: frame.insetBy(dx: 0.5, dy: 0.5),
                    xRadius: 5.5,
                    yRadius: 5.5
                )
                border.lineWidth = 1
                border.stroke()
            }

            AnnotationDrawing.draw(
                [.numberMarker(
                    center: CGPoint(x: frame.minX + 11, y: frame.midY),
                    number: 1,
                    color: effectiveColor(numberMarkerStyle),
                    markerSize: 7,
                    appearance: appearance
                )],
                in: panel.size
            )

            let title: String
            switch appearance {
            case .filled: title = "实心"
            case .outlined: title = "描边"
            case .light: title = "浅色"
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.88)
            ]
            let size = title.size(withAttributes: attributes)
            title.draw(
                at: CGPoint(x: frame.minX + 22, y: frame.midY - size.height / 2),
                withAttributes: attributes
            )
        }
    }

    private func drawRecordingMenu(for rect: CGRect) {
        guard isRecordingMenuOpen, let panel = recordingMenuFrame(for: rect) else { return }

        drawFloatingPanelBackground(in: panel, radius: 12, alpha: 0.86)
        drawMenuSectionTitle("录制设置", at: CGPoint(x: panel.minX + 14, y: panel.maxY - 25))

        let clickRow = recordingMouseClicksOptionFrame(in: panel)
        if isRecordingMouseClicksOptionHovered {
            NSColor.white.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: clickRow.insetBy(dx: 6, dy: 3), xRadius: 7, yRadius: 7).fill()
        }
        drawRecordingCheckbox(
            in: CGRect(x: clickRow.minX + 14, y: clickRow.midY - 8, width: 16, height: 16),
            isOn: recordingShowsMouseClicks
        )
        "显示鼠标点击".draw(
            at: CGPoint(x: clickRow.minX + 40, y: clickRow.midY - 8),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.9)
            ]
        )

        NSColor.white.withAlphaComponent(0.1).setFill()
        CGRect(x: panel.minX + 12, y: clickRow.minY - 5, width: panel.width - 24, height: 1).fill()

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

    private func drawMoreMenu(for rect: CGRect) {
        guard isMoreMenuOpen, let panel = moreMenuFrame(for: rect) else { return }

        drawFloatingPanelBackground(in: panel, radius: 11, alpha: 0.90)
        for (index, button) in OverlayButton.moreTools.enumerated() {
            let row = moreToolOptionFrame(index: index, in: panel)
            let isSelected = tool(for: button) == selectedTool
            if isSelected {
                NSColor.controlAccentColor.withAlphaComponent(0.62).setFill()
                NSBezierPath(roundedRect: row.insetBy(dx: 6, dy: 3), xRadius: 7, yRadius: 7).fill()
            } else if hoveredMoreTool == button {
                NSColor.white.withAlphaComponent(0.11).setFill()
                NSBezierPath(roundedRect: row.insetBy(dx: 6, dy: 3), xRadius: 7, yRadius: 7).fill()
            }

            drawSymbol(
                button,
                in: CGRect(x: row.minX + 12, y: row.midY - 10, width: 20, height: 20),
                color: NSColor.white.withAlphaComponent(0.88)
            )
            let title = tooltipTitle(for: button)
            title.draw(
                at: CGPoint(x: row.minX + 42, y: row.midY - 8),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.92)
                ]
            )
            let shortcut = shortcutDisplay(for: button)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.52)
            ]
            let size = shortcut.size(withAttributes: attributes)
            let shortcutFrame = moreToolShortcutFrame(index: index, in: panel)
            NSColor.white.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: shortcutFrame, xRadius: 5, yRadius: 5).fill()
            shortcut.draw(
                at: CGPoint(x: shortcutFrame.midX - size.width / 2, y: shortcutFrame.midY - size.height / 2),
                withAttributes: attributes
            )
        }
    }

    private func drawRecordingCheckbox(in rect: CGRect, isOn: Bool) {
        (isOn ? NSColor.controlAccentColor : NSColor.white.withAlphaComponent(0.08)).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        NSColor.white.withAlphaComponent(isOn ? 0.9 : 0.28).setStroke()
        let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3.5, yRadius: 3.5)
        border.lineWidth = 1
        border.stroke()
        guard isOn else { return }

        let check = NSBezierPath()
        check.lineWidth = 1.7
        check.lineCapStyle = .round
        check.lineJoinStyle = .round
        check.move(to: CGPoint(x: rect.minX + 4, y: rect.midY))
        check.line(to: CGPoint(x: rect.minX + 7, y: rect.minY + 4.5))
        check.line(to: CGPoint(x: rect.maxX - 3.5, y: rect.maxY - 4))
        NSColor.white.setStroke()
        check.stroke()
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
        if isRecordingMenuOpen {
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

        if tool == .callout,
           sliderFrame(.calloutLineWidth, in: panel).insetBy(dx: -10, dy: -12).contains(point) {
            if selectedAnnotationIndex != nil {
                registerUndo()
            }
            updateStyle(control: .calloutLineWidth, at: point)
            dragMode = .adjustingStyle(control: .calloutLineWidth)
            return true
        }

        if (tool == .rectangle || tool == .ellipse), fillToggleFrame(in: panel).insetBy(dx: -8, dy: -8).contains(point) {
            if selectedAnnotationIndex != nil {
                registerUndo()
            }
            rectangleStyle.filled.toggle()
            applyCurrentStyleToSelectedAnnotation()
            needsDisplay = true
            return true
        }

        if tool == .numberMarker {
            for (index, appearance) in NumberMarkerAppearance.allCases.enumerated()
                where numberMarkerAppearanceFrame(index: index, in: panel).contains(point) {
                if selectedAnnotationIndex != nil {
                    registerUndo()
                }
                numberMarkerAppearance = appearance
                applyCurrentStyleToSelectedAnnotation()
                needsDisplay = true
                return true
            }
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

    private func handleRecordingMenuClick(at point: CGPoint, selectionRect: CGRect) -> Bool {
        guard isRecordingMenuOpen, let panel = recordingMenuFrame(for: selectionRect), panel.contains(point) else {
            return false
        }

        if recordingMouseClicksOptionFrame(in: panel).contains(point) {
            recordingShowsMouseClicks.toggle()
            AppSettings.shared.recordingShowsMouseClicks = recordingShowsMouseClicks
            needsDisplay = true
            return true
        }

        for (index, audioMode) in VideoAudioMode.allCases.enumerated()
            where audioModeOptionFrame(index: index, in: panel).contains(point) {
            selectedAudioMode = audioMode
            isRecordingMenuOpen = false
            shortcutMenuButton = nil
            commitSelection(.recordVideo(options: VideoRecordingOptions(
                audioMode: audioMode,
                showsMouseClicks: recordingShowsMouseClicks
            )))
            return true
        }

        return true
    }

    private func handleMoreMenuClick(at point: CGPoint, selectionRect: CGRect) -> Bool {
        guard isMoreMenuOpen else { return false }
        if buttonFrame(.more, for: selectionRect).contains(point) {
            isMoreMenuOpen = false
            hoveredMoreTool = nil
            needsDisplay = true
            return true
        }
        guard let panel = moreMenuFrame(for: selectionRect), panel.contains(point) else {
            return false
        }

        for (index, button) in OverlayButton.moreTools.enumerated()
            where moreToolOptionFrame(index: index, in: panel).contains(point) {
            if moreToolShortcutFrame(index: index, in: panel).contains(point) {
                isMoreMenuOpen = false
                hoveredMoreTool = nil
                hoveredButton = nil
                shortcutMenuButton = button
                needsDisplay = true
                return true
            }
            guard let tool = tool(for: button) else { return true }
            isMoreMenuOpen = false
            hoveredMoreTool = nil
            selectTool(tool, toggles: false)
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
        } else if tool == .rectangle || tool == .ellipse || tool == .numberMarker || tool == .callout {
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
        case .calloutLineWidth:
            return CGRect(x: panel.minX + 74, y: panel.maxY - 79, width: 160, height: 12)
        }
    }

    private func colorSwatchFrame(index: Int, in panel: CGRect) -> CGRect {
        CGRect(x: panel.minX + 14 + CGFloat(index) * 34, y: panel.minY + 12, width: 20, height: 20)
    }

    private func fillToggleFrame(in panel: CGRect) -> CGRect {
        CGRect(x: panel.minX + 74, y: panel.maxY - 82, width: 38, height: 18)
    }

    private func numberMarkerAppearanceFrame(index: Int, in panel: CGRect) -> CGRect {
        CGRect(
            x: panel.minX + 74 + CGFloat(index) * 66,
            y: panel.maxY - 92,
            width: 60,
            height: 24
        )
    }

    private func recordingMenuFrame(for rect: CGRect) -> CGRect? {
        let bar = toolbarFrame(for: rect)
        let recordButton = buttonFrame(.record, for: rect)
        let size = CGSize(width: 196, height: 210)
        let spacing: CGFloat = 8
        let toolbarIsAboveSelection = bar.minY >= rect.maxY
        var origin = CGPoint(x: recordButton.maxX - size.width, y: 0)

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

    private func moreMenuFrame(for rect: CGRect) -> CGRect? {
        let bar = toolbarFrame(for: rect)
        let moreButton = buttonFrame(.more, for: rect)
        let size = CGSize(width: 154, height: 112)
        let spacing: CGFloat = 8
        let toolbarIsAboveSelection = bar.minY >= rect.maxY
        var origin = CGPoint(x: moreButton.midX - size.width / 2, y: 0)

        if toolbarIsAboveSelection {
            origin.y = bar.maxY + spacing
            if origin.y + size.height > bounds.maxY - 10 {
                origin.y = bar.minY - size.height - spacing
            }
        } else {
            origin.y = bar.minY - size.height - spacing
            if origin.y < bounds.minY + 10 {
                origin.y = bar.maxY + spacing
            }
        }

        origin.x = min(max(origin.x, bounds.minX + 10), bounds.maxX - size.width - 10)
        return CGRect(origin: origin, size: size)
    }

    private func moreToolOptionFrame(index: Int, in panel: CGRect) -> CGRect {
        CGRect(
            x: panel.minX,
            y: panel.maxY - 8 - CGFloat(index + 1) * 32,
            width: panel.width,
            height: 32
        )
    }

    private func moreToolShortcutFrame(index: Int, in panel: CGRect) -> CGRect {
        let row = moreToolOptionFrame(index: index, in: panel)
        return CGRect(x: row.maxX - 48, y: row.midY - 10, width: 38, height: 20)
    }

    private func audioModeOptionFrame(index: Int, in panel: CGRect) -> CGRect {
        return CGRect(
            x: panel.minX,
            y: panel.maxY - 84 - CGFloat(index + 1) * 28,
            width: panel.width,
            height: 28
        )
    }

    private func recordingMouseClicksOptionFrame(in panel: CGRect) -> CGRect {
        CGRect(x: panel.minX, y: panel.maxY - 67, width: panel.width, height: 30)
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

    private func frozenCapture(for selection: CaptureSelection) -> CaptureResult? {
        guard let frozenSnapshot else { return nil }
        return try? frozenCaptureService.capture(selection: selection, from: frozenSnapshot)
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
        guard !(isMoreMenuOpen && hoveredButton == .more) else { return }

        let frame = tooltipFrame(for: hoveredButton, selectionRect: selectionRect)
        drawFloatingPanelBackground(in: frame, radius: 9, alpha: 0.91)

        let title = tooltipTitle(for: hoveredButton)
        let shortcut = hoveredButton == .more
            ? "椭圆 · 画笔 · 荧光笔"
            : "快捷键 \(shortcutDisplay(for: hoveredButton))"
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.96)
        ]
        let shortcutAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.72),
            .underlineStyle: hoveredButton == .more ? 0 : NSUnderlineStyle.single.rawValue
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
        let anchorButton: OverlayButton = OverlayButton.moreTools.contains(button) ? .more : button
        let buttonRect = buttonFrame(anchorButton, for: selectionRect)
        let title = tooltipTitle(for: button)
        let shortcut = button == .more
            ? "椭圆 · 画笔 · 荧光笔"
            : "快捷键 \(shortcutDisplay(for: button))"
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

    private func drawAnnotationMeasurementBadge(text: String, near anchor: CGPoint, inside size: CGSize) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.94)
        ]
        let textSize = text.size(withAttributes: attributes)
        let badgeSize = CGSize(width: textSize.width + 14, height: textSize.height + 7)
        var origin = CGPoint(x: anchor.x + 8, y: anchor.y + 8)
        if origin.x + badgeSize.width > size.width - 4 {
            origin.x = anchor.x - badgeSize.width - 8
        }
        if origin.y + badgeSize.height > size.height - 4 {
            origin.y = anchor.y - badgeSize.height - 8
        }
        origin.x = min(max(4, origin.x), max(4, size.width - badgeSize.width - 4))
        origin.y = min(max(4, origin.y), max(4, size.height - badgeSize.height - 4))

        let badge = CGRect(origin: origin, size: badgeSize)
        NSColor(calibratedWhite: 0.05, alpha: 0.82).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 5, yRadius: 5).fill()
        NSColor.white.withAlphaComponent(0.14).setStroke()
        let border = NSBezierPath(
            roundedRect: badge.insetBy(dx: 0.5, dy: 0.5),
            xRadius: 4.5,
            yRadius: 4.5
        )
        border.lineWidth = 1
        border.stroke()
        text.draw(
            at: CGPoint(x: badge.minX + 7, y: badge.midY - textSize.height / 2),
            withAttributes: attributes
        )
    }

    private func drawResizableAnnotationMeasurement(at index: Int, inside size: CGSize) {
        guard annotations.indices.contains(index) else { return }
        let rect: CGRect
        switch annotations[index] {
        case .rectangle(let value, _, _, _),
             .ellipse(let value, _, _, _),
             .mosaic(let value, _),
             .callout(let value, _, _, _, _, _, _, _):
            rect = value
        default:
            return
        }
        drawAnnotationMeasurementBadge(
            text: dimensionText(for: rect),
            near: CGPoint(x: rect.maxX, y: rect.maxY),
            inside: size
        )
    }

    private func drawArrowAnnotationMeasurement(at index: Int, inside size: CGSize) {
        guard annotations.indices.contains(index) else { return }
        let start: CGPoint
        let end: CGPoint
        switch annotations[index] {
        case .arrow(let valueStart, let valueEnd, _, _):
            start = valueStart
            end = valueEnd
        case .callout(_, let valueStart, let valueEnd, _, _, _, _, _):
            start = valueStart
            end = valueEnd
        default:
            return
        }
        let measurement = AnnotationConstraintGeometry.lineMeasurement(from: start, to: end)
        drawAnnotationMeasurementBadge(
            text: "\(Int(measurement.length.rounded())) px · \(Int(measurement.angleDegrees.rounded()))°",
            near: end,
            inside: size
        )
    }

    private func drawWindowCandidateHover(_ candidate: WindowCandidate) {
        let rect = candidate.localRect.intersection(bounds).integral
        guard !rect.isNull, !rect.isEmpty else { return }

        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowBlurRadius = 14
        glow.shadowOffset = .zero
        glow.shadowColor = NSColor.controlAccentColor.withAlphaComponent(0.40)
        glow.set()

        NSColor.white.withAlphaComponent(0.92).setStroke()
        let outer = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        outer.lineWidth = 2
        outer.stroke()
        NSGraphicsContext.restoreGraphicsState()

        NSColor.controlAccentColor.withAlphaComponent(0.88).setStroke()
        let inner = NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 7, yRadius: 7)
        inner.lineWidth = 1
        inner.stroke()

        let subtitle = candidate.ownerName.isEmpty ? "点击选中窗口" : "点击选中窗口 · \(candidate.ownerName)"
        drawHintPill(subtitle, preferredOrigin: CGPoint(x: rect.minX + 10, y: rect.maxY + 10), maxWidth: bounds.width - 32)
    }

    private func drawWindowCandidateDebugOverlay() {
        guard isWindowDebugEnabled else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white
        ]

        for candidate in windowCandidates {
            let rect = candidate.localRect.intersection(bounds)
            guard !rect.isNull, !rect.isEmpty else { continue }
            NSColor.systemYellow.withAlphaComponent(0.55).setStroke()
            let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 1
            path.stroke()

            let label = "\(candidate.ownerName) #\(candidate.id) \(candidate.source)"
            let size = label.size(withAttributes: attributes)
            let labelFrame = CGRect(
                x: min(max(rect.minX, bounds.minX + 6), bounds.maxX - size.width - 14),
                y: min(max(rect.maxY - size.height - 8, bounds.minY + 6), bounds.maxY - size.height - 8),
                width: size.width + 8,
                height: size.height + 4
            )
            NSColor.black.withAlphaComponent(0.68).setFill()
            NSBezierPath(roundedRect: labelFrame, xRadius: 4, yRadius: 4).fill()
            label.draw(at: CGPoint(x: labelFrame.minX + 4, y: labelFrame.midY - size.height / 2), withAttributes: attributes)
        }
    }

    private func drawInitialHint() {
        let text = hoveredWindowCandidate == nil
            ? "拖拽框选 · 点击窗口快速选择 · Esc 取消"
            : "拖拽框选 · 点击选中窗口 · Esc 取消"
        drawHintPill(text, preferredOrigin: CGPoint(x: bounds.midX, y: bounds.midY), centered: true, maxWidth: bounds.width - 32)
    }

    private func drawHintPill(_ text: String, preferredOrigin: CGPoint, centered: Bool = false, maxWidth: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let rawSize = text.size(withAttributes: attributes)
        let width = min(maxWidth, rawSize.width + 22)
        let height = rawSize.height + 12
        let origin: CGPoint
        if centered {
            origin = CGPoint(x: preferredOrigin.x - width / 2, y: preferredOrigin.y - height / 2)
        } else {
            origin = preferredOrigin
        }
        let frame = CGRect(origin: origin, size: CGSize(width: width, height: height))
        let clampedFrame = CGRect(
            x: min(max(frame.minX, bounds.minX + 16), bounds.maxX - width - 16),
            y: min(max(frame.minY, bounds.minY + 16), bounds.maxY - height - 16),
            width: width,
            height: height
        )

        NSColor.black.withAlphaComponent(0.74).setFill()
        NSBezierPath(roundedRect: clampedFrame, xRadius: 8, yRadius: 8).fill()
        NSColor.white.withAlphaComponent(0.14).setStroke()
        let border = NSBezierPath(roundedRect: clampedFrame.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        border.lineWidth = 1
        border.stroke()

        text.draw(
            at: CGPoint(x: clampedFrame.midX - rawSize.width / 2, y: clampedFrame.midY - rawSize.height / 2),
            withAttributes: attributes
        )
    }

    private func handleButtonClick(at point: CGPoint, selectionRect: CGRect) -> Bool {
        for button in OverlayButton.toolbarOrder where buttonFrame(button, for: selectionRect).contains(point) {
            guard isButtonEnabled(button) else { return true }
            shortcutMenuButton = nil
            switch button {
            case .rectangle:
                selectTool(.rectangle)
            case .ellipse:
                selectTool(.ellipse)
            case .arrow:
                selectTool(.arrow)
            case .pen:
                selectTool(.pen)
            case .highlighter:
                selectTool(.highlighter)
            case .number:
                selectTool(.numberMarker)
            case .callout:
                selectTool(.callout)
            case .text:
                selectTool(.text)
            case .mosaic:
                selectTool(.mosaic)
            case .ocr:
                isRecordingMenuOpen = false
                runOCR()
            case .pin:
                isRecordingMenuOpen = false
                commitSelection(.pinToScreen)
            case .longScreenshot:
                isRecordingMenuOpen = false
                commitSelection(.longScreenshot)
            case .record:
                closeTransientPanels()
                selectedTool = nil
                selectedAnnotationIndex = nil
                shortcutMenuButton = nil
                isRecordingMenuOpen.toggle()
                needsDisplay = true
            case .more:
                isRecordingMenuOpen = false
                shortcutMenuButton = nil
                isMoreMenuOpen.toggle()
                hoveredMoreTool = nil
                needsDisplay = true
            case .undo:
                undoEdit()
            case .redo:
                redoEdit()
            case .delete:
                deleteSelectedAnnotation()
            case .copy:
                isRecordingMenuOpen = false
                commitSelection(.copyToClipboard)
            case .save:
                isRecordingMenuOpen = false
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
        isRecordingMenuOpen = false
        isMoreMenuOpen = false
        hoveredMoreTool = nil
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
        guard isRecordingMenuOpen, let panel = recordingMenuFrame(for: selectionRect), panel.contains(point) else {
            if hoveredAudioMode != nil || isRecordingMouseClicksOptionHovered {
                hoveredAudioMode = nil
                isRecordingMouseClicksOptionHovered = false
                needsDisplay = true
            }
            return
        }

        let nextMouseClicksHovered = recordingMouseClicksOptionFrame(in: panel).contains(point)
        let nextAudioMode = VideoAudioMode.allCases.enumerated().first {
            audioModeOptionFrame(index: $0.offset, in: panel).contains(point)
        }?.element

        if hoveredAudioMode != nextAudioMode
            || isRecordingMouseClicksOptionHovered != nextMouseClicksHovered {
            hoveredAudioMode = nextAudioMode
            isRecordingMouseClicksOptionHovered = nextMouseClicksHovered
            needsDisplay = true
        }
    }

    private func updateMoreMenuHover(at point: CGPoint, selectionRect: CGRect) {
        guard isMoreMenuOpen, let panel = moreMenuFrame(for: selectionRect), panel.contains(point) else {
            if hoveredMoreTool != nil {
                hoveredMoreTool = nil
                needsDisplay = true
            }
            return
        }

        let next = OverlayButton.moreTools.enumerated().first {
            moreToolOptionFrame(index: $0.offset, in: panel).contains(point)
        }?.element
        if hoveredMoreTool != next {
            hoveredMoreTool = next
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
        return OverlayButton.toolbarOrder.first { buttonFrame($0, for: selectionRect).contains(point) }
    }

    private func tooltipTitle(for button: OverlayButton) -> String {
        switch button {
        case .rectangle:
            return "框选"
        case .ellipse:
            return "椭圆"
        case .arrow:
            return "箭头"
        case .pen:
            return "画笔"
        case .highlighter:
            return "荧光笔"
        case .number:
            return "序号"
        case .callout:
            return "评论"
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
        case .more:
            return "更多工具"
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
        case .callout:
            return "1"
        case .rectangle:
            return "2"
        case .ellipse:
            return "E"
        case .arrow:
            return "3"
        case .pen:
            return "P"
        case .highlighter:
            return "H"
        case .number:
            return "4"
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
        case .more:
            return "点击展开"
        case .undo:
            return "Cmd+Z"
        case .redo:
            return "Cmd+Shift+Z / Cmd+Y"
        case .delete:
            return "Delete"
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
        persistToolbarShortcuts()
    }

    private func clearShortcut(for button: OverlayButton) {
        customShortcuts.removeValue(forKey: button)
        clearedShortcuts.insert(button)
        persistToolbarShortcuts()
    }

    private func persistToolbarShortcuts() {
        let overrides = Dictionary(
            uniqueKeysWithValues: customShortcuts.map { ($0.key.persistenceID, $0.value) }
        )
        let clearedButtonIDs = Set(clearedShortcuts.map(\.persistenceID))
        AppSettings.shared.setToolbarShortcutPreferences(
            ToolbarShortcutPreferences(
                overrides: overrides,
                clearedButtonIDs: clearedButtonIDs
            )
        )
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
        button.defaultShortcutKey
    }

    private func shortcutDisplayName(for key: String) -> String {
        shortcutOptions.first { $0.key == key }?.display ?? key
    }

    private func performShortcutAction(_ button: OverlayButton) {
        switch button {
        case .rectangle:
            selectTool(.rectangle, toggles: false)
        case .ellipse:
            selectTool(.ellipse, toggles: false)
        case .arrow:
            selectTool(.arrow, toggles: false)
        case .pen:
            selectTool(.pen, toggles: false)
        case .highlighter:
            selectTool(.highlighter, toggles: false)
        case .number:
            selectTool(.numberMarker, toggles: false)
        case .callout:
            selectTool(.callout, toggles: false)
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
            isRecordingMenuOpen.toggle()
            needsDisplay = true
        case .more:
            isRecordingMenuOpen = false
            shortcutMenuButton = nil
            isMoreMenuOpen.toggle()
            hoveredMoreTool = nil
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

    private func handleLayeredEscape() {
        if ocrPanelController != nil || isRecordingMenuOpen || isMoreMenuOpen || shortcutMenuButton != nil {
            closeTransientPanels()
            shortcutMenuButton = nil
            needsDisplay = true
            return
        }
        if selectedAnnotationIndex != nil {
            selectedAnnotationIndex = nil
            pendingTextEditIndex = nil
            needsDisplay = true
            return
        }
        if selectedTool != nil {
            selectedTool = nil
            needsDisplay = true
            return
        }
        onCancel?()
    }

    private func handleTooltipShortcutClick(at point: CGPoint, selectionRect: CGRect) -> Bool {
        guard
            let hoveredButton,
            hoveredButton != .more,
            tooltipShortcutFrame(for: hoveredButton, selectionRect: selectionRect).contains(point)
        else { return false }

        shortcutMenuButton = hoveredButton
        isRecordingMenuOpen = false
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
        let contentWidth = OverlayButton.toolbarOrder.reduce(CGFloat.zero) { $0 + buttonWidth($1) }
        let spacing = OverlayButton.toolbarOrder.dropLast().reduce(CGFloat.zero) {
            $0 + toolbarButtonSpacing(after: $1)
        }
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

        for current in OverlayButton.toolbarOrder {
            if current == .record {
                if button == .record {
                    return CGRect(x: x, y: y, width: buttonWidth(.record), height: 30)
                }
                x += buttonWidth(.record) + toolbarButtonSpacing(after: current)
                continue
            }

            let width = buttonWidth(current)
            if current == button {
                return CGRect(x: x, y: y, width: width, height: 30)
            }
            x += width + toolbarButtonSpacing(after: current)
        }

        return CGRect(x: x, y: y, width: 28, height: 30)
    }

    private func buttonWidth(_ button: OverlayButton) -> CGFloat {
        switch button {
        case .rectangle, .ellipse, .arrow, .pen, .highlighter, .number, .callout, .text, .mosaic, .ocr, .pin, .longScreenshot, .record, .more, .undo, .redo, .delete, .copy, .save, .cancel:
            return 32
        }
    }

    private func toolbarHorizontalPadding() -> CGFloat {
        7
    }

    private func toolbarButtonSpacing(after button: OverlayButton) -> CGFloat {
        switch button {
        case .record, .text:
            return 10
        default:
            return 4
        }
    }

    private func tool(for button: OverlayButton) -> AnnotationTool? {
        switch button {
        case .rectangle: .rectangle
        case .ellipse: .ellipse
        case .arrow: .arrow
        case .pen: .pen
        case .highlighter: .highlighter
        case .number: .numberMarker
        case .callout: .callout
        case .mosaic: .mosaic
        case .text: .text
        case .ocr, .pin, .longScreenshot, .record, .more, .undo, .redo, .delete, .copy, .save, .cancel: nil
        }
    }

    private func supportsStylePanel(_ tool: AnnotationTool) -> Bool {
        switch tool {
        case .rectangle, .ellipse, .arrow, .pen, .highlighter, .numberMarker, .callout, .text, .mosaic:
            return true
        }
    }

    private func currentStyle(for tool: AnnotationTool) -> ToolStyle {
        switch tool {
        case .rectangle:
            return rectangleStyle
        case .ellipse:
            return ellipseStyle
        case .arrow:
            return arrowStyle
        case .pen:
            return penStyle
        case .highlighter:
            return highlighterStyle
        case .text:
            return textStyle
        case .numberMarker:
            return numberMarkerStyle
        case .callout:
            return textStyle
        case .mosaic:
            return ToolStyle(color: .white, size: mosaicBlockSize, opacity: 1)
        }
    }

    private func setCurrentStyle(_ style: ToolStyle, for tool: AnnotationTool) {
        switch tool {
        case .rectangle:
            rectangleStyle = style
        case .ellipse:
            ellipseStyle = style
        case .arrow:
            arrowStyle = style
        case .pen:
            penStyle = style
        case .highlighter:
            highlighterStyle = style
        case .text:
            textStyle = style
        case .numberMarker:
            numberMarkerStyle = style
        case .callout:
            textStyle = style
            arrowStyle = ToolStyle(color: style.color, size: max(2, min(arrowStyle.size, 10)), opacity: style.opacity)
            rectangleStyle = ToolStyle(color: style.color, size: max(2, min(rectangleStyle.size, 10)), opacity: style.opacity)
        case .mosaic:
            mosaicBlockSize = style.size
        }
    }

    private func styleSizeRange(for tool: AnnotationTool) -> ClosedRange<CGFloat> {
        switch tool {
        case .rectangle, .ellipse:
            return 1...12
        case .arrow:
            return 1...18
        case .pen:
            return 1...16
        case .highlighter:
            return 8...36
        case .text:
            return 12...48
        case .numberMarker:
            return 9...28
        case .callout:
            return 12...48
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
        case .calloutLineWidth:
            guard tool == .callout else { return }
            let slider = sliderFrame(.calloutLineWidth, in: panel)
            let progress = min(1, max(0, (point.x - slider.minX) / slider.width))
            let lineWidth = round(2 + 8 * progress)
            arrowStyle.size = lineWidth
            rectangleStyle.size = lineWidth
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

    private func selectedEditableTextAnnotationContains(_ point: CGPoint) -> Bool {
        guard
            let index = selectedAnnotationIndex,
            annotations.indices.contains(index)
        else {
            return false
        }
        switch annotations[index] {
        case .text:
            return annotation(at: index, contains: point)
        case .callout(_, _, _, let textOrigin, let text, _, _, let fontSize):
            let value = text.isEmpty ? " " : text
            let size = AnnotationTextLayout.size(for: value, fontSize: fontSize)
            return CGRect(origin: textOrigin, size: size).insetBy(dx: -10, dy: -8).contains(point)
        default:
            return false
        }
    }

    private func beginTextEditLikeAnnotation(at index: Int) {
        guard annotations.indices.contains(index) else { return }
        switch annotations[index] {
        case .text:
            beginTextEdit(at: index)
        case .callout:
            beginCalloutTextEdit(at: index, registersUndo: false)
        default:
            break
        }
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

    private func beginCalloutTextEdit(
        at index: Int,
        registersUndo: Bool = true,
        wasJustCreated: Bool = false
    ) {
        guard annotations.indices.contains(index) else { return }
        guard case .callout(_, _, _, let textOrigin, let text, let color, _, let fontSize) = annotations[index] else { return }
        if registersUndo {
            registerUndo()
        }
        let originalAnnotation = annotations[index]
        selectedAnnotationIndex = index
        selectedTool = .callout
        textStyle = style(from: color, size: fontSize)
        beginTextEntry(at: textOrigin, initialText: text, editingExisting: true)
        activeCalloutTextEditIndex = index
        activeCalloutOriginalAnnotation = originalAnnotation
        activeCalloutWasJustCreated = wasJustCreated
        updateCalloutConnector(
            at: index,
            textOrigin: textOrigin,
            textSize: AnnotationTextLayout.size(
                for: text.isEmpty ? " " : text,
                fontSize: fontSize
            )
        )
        needsDisplay = true
    }

    private func beginTextEntry(at point: CGPoint, initialText: String, editingExisting: Bool = false) {
        commitActiveText()
        guard let selectionRect else { return }

        let absolute = CGPoint(x: selectionRect.minX + point.x, y: selectionRect.minY + point.y)
        let textView = NSTextView(frame: CGRect(
            x: absolute.x - textInputPadding.width,
            y: absolute.y - textInputPadding.height,
            width: textInputMinSize.width,
            height: textInputMinSize.height
        ))
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
        textView.textContainerInset = NSSize(width: textInputPadding.width, height: textInputPadding.height)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.lineBreakMode = .byClipping
        textView.textContainer?.containerSize = CGSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.string = initialText
        addSubview(textView)

        activeTextView = textView
        activeTextOrigin = point
        activeTextTopY = absolute.y + AnnotationTextLayout.size(
            for: initialText.isEmpty ? " " : initialText,
            fontSize: textStyle.size
        ).height
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
        let resolvedOrigin = currentTextAnnotationOrigin(for: textView, committedValue: value) ?? origin
        activeTextView = nil
        activeTextOrigin = nil
        activeTextTopY = nil
        let calloutTextEditIndex = activeCalloutTextEditIndex
        activeCalloutTextEditIndex = nil
        activeCalloutOriginalAnnotation = nil
        activeCalloutWasJustCreated = false
        activeTextIsEditingExisting = false
        textView.delegate = nil
        textView.removeFromSuperview()
        if let calloutTextEditIndex {
            updateCalloutText(at: calloutTextEditIndex, value: value, origin: resolvedOrigin)
            selectedAnnotationIndex = calloutTextEditIndex
            needsDisplay = true
            return
        }
        if !value.isEmpty {
            add(
                .text(origin: resolvedOrigin, value: value, color: effectiveColor(textStyle), fontSize: textStyle.size),
                registersUndo: !isEditingExisting
            )
            selectedAnnotationIndex = nil
        }
    }

    func textDidChange(_ notification: Notification) {
        guard let textView = activeTextView else { return }
        let used = AnnotationTextLayout.size(
            for: textView.string.isEmpty ? " " : textView.string,
            fontSize: textStyle.size
        )
        var frame = textView.frame
        if let selectionRect {
            let preferredMinX = selectionRect.minX
                + (activeTextOrigin?.x ?? 0)
                - textInputPadding.width
            let horizontal = AnnotationGeometry.fittedHorizontalEditorFrame(
                preferredMinX: preferredMinX,
                desiredWidth: ceil(used.width) + textInputPadding.width * 2,
                minimumWidth: min(textInputMinSize.width, selectionRect.width),
                in: selectionRect
            )
            frame.origin.x = horizontal.minX
            frame.size.width = horizontal.width
        }
        frame.size.height = max(textInputMinSize.height, ceil(used.height) + textInputPadding.height * 2)
        if let activeTextTopY {
            frame.origin.y = activeTextTopY + textInputPadding.height - frame.height
        }
        textView.frame = frame
        if
            let index = activeCalloutTextEditIndex,
            let origin = currentTextAnnotationOrigin(for: textView, committedValue: textView.string)
        {
            updateCalloutConnector(
                at: index,
                textOrigin: origin,
                textSize: used
            )
        }
        needsDisplay = true
    }

    private func currentTextAnnotationOrigin(for textView: NSTextView, committedValue: String) -> CGPoint? {
        guard let selectionRect, let activeTextTopY else { return nil }
        let committedHeight = AnnotationTextLayout.size(
            for: committedValue.isEmpty ? " " : committedValue,
            fontSize: textStyle.size
        ).height
        return CGPoint(
            x: textView.frame.minX + textInputPadding.width - selectionRect.minX,
            y: activeTextTopY - committedHeight - selectionRect.minY
        )
    }

    private func updateCalloutText(at index: Int, value: String, origin: CGPoint) {
        guard annotations.indices.contains(index) else { return }
        guard case .callout(
            let targetRect,
            _,
            let arrowEnd,
            _,
            _,
            let color,
            let lineWidth,
            let fontSize
        ) = annotations[index] else {
            return
        }
        let textSize = value.isEmpty
            ? AnnotationTextLayout.size(for: " ", fontSize: fontSize)
            : AnnotationTextLayout.size(for: value, fontSize: fontSize)
        let connector = AnnotationGeometry.calloutConnector(
            targetRect: targetRect,
            textFrame: CGRect(origin: origin, size: textSize),
            in: CGRect(origin: .zero, size: selectionRect?.size ?? bounds.size)
        )
        annotations[index] = .callout(
            targetRect: targetRect,
            arrowStart: connector.arrowStart,
            arrowEnd: AnnotationGeometry.calloutArrowHeadIsAttached(arrowEnd, to: targetRect)
                ? connector.arrowEnd
                : arrowEnd,
            textOrigin: origin,
            text: value,
            color: color,
            lineWidth: lineWidth,
            fontSize: fontSize
        )
    }

    private func updateCalloutConnector(at index: Int, textOrigin: CGPoint, textSize: CGSize) {
        guard annotations.indices.contains(index) else { return }
        guard case .callout(
            let targetRect,
            _,
            let arrowEnd,
            _,
            let text,
            let color,
            let lineWidth,
            let fontSize
        ) = annotations[index] else {
            return
        }
        let connector = AnnotationGeometry.calloutConnector(
            targetRect: targetRect,
            textFrame: CGRect(origin: textOrigin, size: textSize),
            in: CGRect(origin: .zero, size: selectionRect?.size ?? bounds.size)
        )
        annotations[index] = .callout(
            targetRect: targetRect,
            arrowStart: connector.arrowStart,
            arrowEnd: AnnotationGeometry.calloutArrowHeadIsAttached(arrowEnd, to: targetRect)
                ? connector.arrowEnd
                : arrowEnd,
            textOrigin: textOrigin,
            text: text,
            color: color,
            lineWidth: lineWidth,
            fontSize: fontSize
        )
    }

    private func cancelActiveCalloutTextEdit() {
        guard let textView = activeTextView, let index = activeCalloutTextEditIndex else { return }
        activeTextView = nil
        activeTextOrigin = nil
        activeTextTopY = nil
        activeCalloutTextEditIndex = nil
        activeTextIsEditingExisting = false
        textView.delegate = nil
        textView.removeFromSuperview()

        if activeCalloutWasJustCreated {
            if annotations.indices.contains(index) {
                annotations.remove(at: index)
            }
            selectedAnnotationIndex = nil
        } else if let original = activeCalloutOriginalAnnotation, annotations.indices.contains(index) {
            annotations[index] = original
            selectedAnnotationIndex = index
        }
        _ = undoStack.popLast()
        activeCalloutOriginalAnnotation = nil
        activeCalloutWasJustCreated = false
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            if activeCalloutTextEditIndex != nil {
                cancelActiveCalloutTextEdit()
            } else {
                commitActiveText()
                window?.makeFirstResponder(self)
            }
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)),
           NSApp.currentEvent?.modifierFlags.contains(.command) == true {
            commitActiveText()
            window?.makeFirstResponder(self)
            return true
        }
        return false
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

        if let capture = frozenCapture(for: selection) {
            handleOCRCaptureResult(.success(capture))
            return
        }

        onOCRCapture(selection) { [weak self] result in
            guard let self else { return }
            self.handleOCRCaptureResult(result)
        }
    }

    private func handleOCRCaptureResult(_ result: Result<CaptureResult, Error>) {
        switch result {
        case .success(let capture):
            showOCRPanel(text: "OCR 识别中...")
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
            isOCRBusy = false
            needsDisplay = true
            showOCRPanel(text: "OCR 失败：\(error.localizedDescription)")
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
        isRecordingMenuOpen = false
        isMoreMenuOpen = false
        hoveredMoreTool = nil
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

    private func updateHoveredWindowCandidate(at point: CGPoint) {
        let next = windowCandidate(at: point)
        if hoveredWindowCandidate?.id != next?.id {
            hoveredWindowCandidate = next
            needsDisplay = true
        }
        if next == nil {
            NSCursor.crosshair.set()
        } else {
            NSCursor.pointingHand.set()
        }
    }

    private func refreshWindowCandidates() {
        windowCandidateRefreshGeneration += 1
        let generation = windowCandidateRefreshGeneration
        windowDetectionService.candidates(for: targetScreen) { [weak self] candidates in
            guard let self, generation == self.windowCandidateRefreshGeneration else { return }
            self.windowCandidates = candidates
            self.refreshWindowHoverUnderCurrentMouse()
            self.needsDisplay = true
        }
    }

    private func refreshWindowHoverUnderCurrentMouse() {
        guard selectionRect == nil, let window else { return }
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let localPoint = convert(windowPoint, from: nil)
        guard bounds.contains(localPoint) else { return }
        updateHoveredWindowCandidate(at: localPoint)
    }

    private func windowCandidate(at point: CGPoint) -> WindowCandidate? {
        windowCandidates.first { $0.localRect.insetBy(dx: -2, dy: -2).contains(point) }
    }

    private func selectWindowCandidate(_ candidate: WindowCandidate) {
        selectedTool = nil
        selectedAnnotationIndex = nil
        annotations.removeAll()
        undoStack.removeAll()
        redoStack.removeAll()
        hoveredWindowCandidate = nil
        setSelectionRect(clamped(candidate.localRect), keepingAnnotationsStationary: false)
        needsDisplay = true
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
            if let region = calloutHitRegion(at: point, annotation: annotations[index]) {
                switch region {
                case .targetBorder:
                    return .movingCalloutTarget(index: index, lastPoint: point)
                case .text:
                    return .movingCalloutText(index: index, lastPoint: point)
                case .arrow:
                    return .movingAnnotation(index: index, lastPoint: point)
                }
            }
            return .movingAnnotation(index: index, lastPoint: point)
        }
        return nil
    }

    private func calloutHitRegion(at point: CGPoint, annotation: Annotation) -> CalloutHitRegion? {
        guard case .callout(
            let targetRect,
            let arrowStart,
            let arrowEnd,
            let textOrigin,
            let text,
            _,
            let lineWidth,
            let fontSize
        ) = annotation else {
            return nil
        }
        let textSize = text.isEmpty
            ? calloutPlaceholderTextSize
            : AnnotationTextLayout.size(for: text, fontSize: fontSize)
        return AnnotationGeometry.calloutHitRegion(
            at: point,
            targetRect: targetRect,
            arrowStart: arrowStart,
            arrowEnd: arrowEnd,
            textFrame: CGRect(origin: textOrigin, size: textSize),
            lineWidth: lineWidth
        )
    }

    private func hitSelectedAnnotationHandle(at point: CGPoint, index: Int) -> DragMode? {
        guard annotations.indices.contains(index) else { return nil }
        adoptToolAndStyle(from: annotations[index])
        let relative = relativePoint(point)
        switch annotations[index] {
        case .rectangle(let rect, _, _, _), .ellipse(let rect, _, _, _), .mosaic(let rect, _):
            if let handle = annotationRectangleHandleHit(at: relative, rect: rect) {
                return .resizingAnnotation(index: index, handle: handle)
            }
        case .arrow(let start, let end, _, _):
            if distance(relative, start) <= 14 {
                return .movingArrowEndpoint(index: index, endpoint: .start)
            }
            if distance(relative, end) <= 14 {
                return .movingArrowEndpoint(index: index, endpoint: .end)
            }
        case .callout(let targetRect, let arrowStart, let arrowEnd, _, _, _, _, _):
            if distance(relative, arrowStart) <= 14 {
                return .movingArrowEndpoint(index: index, endpoint: .start)
            }
            if distance(relative, arrowEnd) <= 14 {
                return .movingArrowEndpoint(index: index, endpoint: .end)
            }
            if let handle = annotationRectangleHandleHit(at: relative, rect: targetRect) {
                return .resizingAnnotation(index: index, handle: handle)
            }
        case .freehand, .highlighter, .numberMarker, .text:
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
        case .ellipse(_, let color, let lineWidth, let filled):
            selectedTool = .ellipse
            var style = style(from: color, size: lineWidth)
            style.filled = filled
            ellipseStyle = style
        case .arrow(_, _, let color, let lineWidth):
            selectedTool = .arrow
            arrowStyle = style(from: color, size: lineWidth)
        case .freehand(_, let color, let lineWidth):
            selectedTool = .pen
            penStyle = style(from: color, size: lineWidth)
        case .highlighter(_, let color, let lineWidth):
            selectedTool = .highlighter
            highlighterStyle = style(from: color, size: lineWidth)
        case .numberMarker(_, _, let color, let markerSize, let appearance):
            selectedTool = .numberMarker
            numberMarkerStyle = style(from: color, size: markerSize)
            numberMarkerAppearance = appearance
        case .text(_, _, let color, let fontSize):
            selectedTool = .text
            textStyle = style(from: color, size: fontSize)
        case .mosaic(_, let blockSize):
            selectedTool = .mosaic
            mosaicBlockSize = blockSize
        case .callout(_, _, _, _, _, let color, let lineWidth, let fontSize):
            selectedTool = .callout
            rectangleStyle = style(from: color, size: lineWidth)
            arrowStyle = style(from: color, size: lineWidth)
            textStyle = style(from: color, size: fontSize)
        }
    }

    private func annotation(at index: Int, contains point: CGPoint) -> Bool {
        AnnotationGeometry.contains(
            point,
            annotation: annotations[index],
            emptyCalloutTextSize: calloutPlaceholderTextSize
        )
    }

    private func moveAnnotation(
        at index: Int,
        by delta: CGPoint,
        constrainsToSelection: Bool = true
    ) {
        guard annotations.indices.contains(index) else { return }
        let appliedDelta: CGPoint
        if constrainsToSelection, let selectionRect {
            appliedDelta = AnnotationGeometry.clampedTranslation(
                for: AnnotationGeometry.visualBounds(of: annotations[index]),
                requested: delta,
                within: CGRect(origin: .zero, size: selectionRect.size)
            )
        } else {
            appliedDelta = delta
        }
        switch annotations[index] {
        case .rectangle(let rect, let color, let lineWidth, let filled):
            annotations[index] = .rectangle(rect: rect.offsetBy(dx: appliedDelta.x, dy: appliedDelta.y), color: color, lineWidth: lineWidth, filled: filled)
        case .ellipse(let rect, let color, let lineWidth, let filled):
            annotations[index] = .ellipse(rect: rect.offsetBy(dx: appliedDelta.x, dy: appliedDelta.y), color: color, lineWidth: lineWidth, filled: filled)
        case .arrow(let start, let end, let color, let lineWidth):
            annotations[index] = .arrow(
                start: CGPoint(x: start.x + appliedDelta.x, y: start.y + appliedDelta.y),
                end: CGPoint(x: end.x + appliedDelta.x, y: end.y + appliedDelta.y),
                color: color,
                lineWidth: lineWidth
            )
        case .freehand(let points, let color, let lineWidth):
            annotations[index] = .freehand(
                points: AnnotationPathGeometry.translated(points, by: appliedDelta),
                color: color,
                lineWidth: lineWidth
            )
        case .highlighter(let points, let color, let lineWidth):
            annotations[index] = .highlighter(
                points: AnnotationPathGeometry.translated(points, by: appliedDelta),
                color: color,
                lineWidth: lineWidth
            )
        case .numberMarker(let center, let number, let color, let markerSize, let appearance):
            annotations[index] = .numberMarker(
                center: CGPoint(x: center.x + appliedDelta.x, y: center.y + appliedDelta.y),
                number: number,
                color: color,
                markerSize: markerSize,
                appearance: appearance
            )
        case .text(let origin, let value, let color, let fontSize):
            annotations[index] = .text(origin: CGPoint(x: origin.x + appliedDelta.x, y: origin.y + appliedDelta.y), value: value, color: color, fontSize: fontSize)
        case .mosaic(let rect, let blockSize):
            annotations[index] = .mosaic(rect: rect.offsetBy(dx: appliedDelta.x, dy: appliedDelta.y), blockSize: blockSize)
        case .callout(let targetRect, let arrowStart, let arrowEnd, let textOrigin, let text, let color, let lineWidth, let fontSize):
            annotations[index] = .callout(
                targetRect: targetRect.offsetBy(dx: appliedDelta.x, dy: appliedDelta.y),
                arrowStart: CGPoint(x: arrowStart.x + appliedDelta.x, y: arrowStart.y + appliedDelta.y),
                arrowEnd: CGPoint(x: arrowEnd.x + appliedDelta.x, y: arrowEnd.y + appliedDelta.y),
                textOrigin: CGPoint(x: textOrigin.x + appliedDelta.x, y: textOrigin.y + appliedDelta.y),
                text: text,
                color: color,
                lineWidth: lineWidth,
                fontSize: fontSize
            )
        }
    }

    private func moveAllAnnotations(by delta: CGPoint) {
        guard delta.x != 0 || delta.y != 0 else { return }
        for index in annotations.indices {
            moveAnnotation(at: index, by: delta, constrainsToSelection: false)
        }
    }

    private func moveCalloutTarget(at index: Int, by delta: CGPoint) {
        guard annotations.indices.contains(index), let selectionRect else { return }
        guard case .callout(
            let targetRect,
            let arrowStart,
            let arrowEnd,
            let textOrigin,
            let text,
            let color,
            let lineWidth,
            let fontSize
        ) = annotations[index] else {
            return
        }
        let placement = AnnotationGeometry.movedCalloutTarget(
            targetRect: targetRect,
            arrowStart: arrowStart,
            arrowEnd: arrowEnd,
            requestedDelta: delta,
            within: CGRect(origin: .zero, size: selectionRect.size)
        )
        annotations[index] = .callout(
            targetRect: placement.targetRect,
            arrowStart: arrowStart,
            arrowEnd: placement.arrowEnd,
            textOrigin: textOrigin,
            text: text,
            color: color,
            lineWidth: lineWidth,
            fontSize: fontSize
        )
    }

    private func moveCalloutText(at index: Int, by delta: CGPoint) {
        guard annotations.indices.contains(index), let selectionRect else { return }
        guard case .callout(
            let targetRect,
            let arrowStart,
            let arrowEnd,
            let textOrigin,
            let text,
            let color,
            let lineWidth,
            let fontSize
        ) = annotations[index] else {
            return
        }
        let textSize = text.isEmpty
            ? calloutPlaceholderTextSize
            : AnnotationTextLayout.size(for: text, fontSize: fontSize)
        let placement = AnnotationGeometry.movedCalloutText(
            textFrame: CGRect(origin: textOrigin, size: textSize),
            arrowStart: arrowStart,
            requestedDelta: delta,
            within: CGRect(origin: .zero, size: selectionRect.size)
        )
        annotations[index] = .callout(
            targetRect: targetRect,
            arrowStart: placement.arrowStart,
            arrowEnd: arrowEnd,
            textOrigin: placement.textOrigin,
            text: text,
            color: color,
            lineWidth: lineWidth,
            fontSize: fontSize
        )
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
        case (.ellipse, .ellipse(let rect, _, _, _)):
            annotations[index] = .ellipse(rect: rect, color: effectiveColor(ellipseStyle), lineWidth: ellipseStyle.size, filled: ellipseStyle.filled)
        case (.arrow, .arrow(let start, let end, _, _)):
            annotations[index] = .arrow(start: start, end: end, color: effectiveColor(arrowStyle), lineWidth: arrowStyle.size)
        case (.pen, .freehand(let points, _, _)):
            annotations[index] = .freehand(points: points, color: effectiveColor(penStyle), lineWidth: penStyle.size)
        case (.highlighter, .highlighter(let points, _, _)):
            annotations[index] = .highlighter(points: points, color: effectiveColor(highlighterStyle), lineWidth: highlighterStyle.size)
        case (.numberMarker, .numberMarker(let center, let number, _, _, _)):
            annotations[index] = .numberMarker(
                center: center,
                number: number,
                color: effectiveColor(numberMarkerStyle),
                markerSize: numberMarkerStyle.size,
                appearance: numberMarkerAppearance
            )
        case (.text, .text(let origin, let value, _, _)):
            annotations[index] = .text(origin: origin, value: value, color: effectiveColor(textStyle), fontSize: textStyle.size)
        case (.mosaic, .mosaic(let rect, _)):
            annotations[index] = .mosaic(rect: rect, blockSize: mosaicBlockSize)
            requestMosaicPreviewCaptureIfNeeded()
        case (.callout, .callout(let targetRect, let arrowStart, let arrowEnd, let textOrigin, let text, _, _, _)):
            annotations[index] = .callout(
                targetRect: targetRect,
                arrowStart: arrowStart,
                arrowEnd: arrowEnd,
                textOrigin: textOrigin,
                text: text,
                color: effectiveColor(textStyle),
                lineWidth: max(2, arrowStyle.size),
                fontSize: textStyle.size
            )
        default:
            break
        }
    }

    private func resizeAnnotationRectangle(
        at index: Int,
        handle: AnnotationRectHandle,
        to point: CGPoint,
        preservesAspectRatio: Bool = false
    ) {
        guard annotations.indices.contains(index) else { return }
        let rect: CGRect
        switch annotations[index] {
        case .rectangle(let value, _, _, _), .ellipse(let value, _, _, _), .mosaic(let value, _), .callout(let value, _, _, _, _, _, _, _):
            rect = value
        default:
            return
        }
        if preservesAspectRatio, rect.height > 0 {
            let fixedCorner: CGPoint?
            switch handle {
            case .topLeft:
                fixedCorner = CGPoint(x: rect.maxX, y: rect.maxY)
            case .topRight:
                fixedCorner = CGPoint(x: rect.minX, y: rect.maxY)
            case .bottomLeft:
                fixedCorner = CGPoint(x: rect.maxX, y: rect.minY)
            case .bottomRight:
                fixedCorner = CGPoint(x: rect.minX, y: rect.minY)
            case .top, .right, .bottom, .left:
                fixedCorner = nil
            }
            if let fixedCorner {
                let nextRect = AnnotationConstraintGeometry.aspectConstrainedRect(
                    fixedCorner: fixedCorner,
                    movingCorner: point,
                    aspectRatio: rect.width / rect.height,
                    inside: CGRect(origin: .zero, size: selectionRect?.size ?? bounds.size)
                )
                replaceResizableAnnotation(at: index, with: nextRect)
                return
            }
        }

        var minX = rect.minX
        var maxX = rect.maxX
        var minY = rect.minY
        var maxY = rect.maxY
        switch handle {
        case .topLeft:
            minX = point.x
            minY = point.y
        case .top:
            minY = point.y
        case .topRight:
            maxX = point.x
            minY = point.y
        case .right:
            maxX = point.x
        case .bottomLeft:
            minX = point.x
            maxY = point.y
        case .bottomRight:
            maxX = point.x
            maxY = point.y
        case .bottom:
            maxY = point.y
        case .left:
            minX = point.x
        }
        let nextRect = CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
        replaceResizableAnnotation(at: index, with: nextRect)
    }

    private func replaceResizableAnnotation(at index: Int, with nextRect: CGRect) {
        switch annotations[index] {
        case .rectangle(_, let color, let lineWidth, let filled):
            annotations[index] = .rectangle(rect: nextRect, color: color, lineWidth: lineWidth, filled: filled)
        case .ellipse(_, let color, let lineWidth, let filled):
            annotations[index] = .ellipse(rect: nextRect, color: color, lineWidth: lineWidth, filled: filled)
        case .mosaic(_, let blockSize):
            annotations[index] = .mosaic(rect: nextRect, blockSize: blockSize)
        case .callout(let previousTargetRect, let arrowStart, let arrowEnd, let textOrigin, let text, let color, let lineWidth, let fontSize):
            annotations[index] = .callout(
                targetRect: nextRect,
                arrowStart: arrowStart,
                arrowEnd: AnnotationGeometry.calloutArrowEndAfterTargetChange(
                    previousTargetRect: previousTargetRect,
                    nextTargetRect: nextRect,
                    arrowStart: arrowStart,
                    currentArrowEnd: arrowEnd
                ),
                textOrigin: textOrigin,
                text: text,
                color: color,
                lineWidth: lineWidth,
                fontSize: fontSize
            )
        default:
            break
        }
    }

    private func moveArrowEndpoint(
        at index: Int,
        endpoint: ArrowEndpoint,
        to point: CGPoint,
        snapsAngle: Bool = false
    ) {
        guard annotations.indices.contains(index) else { return }
        let annotationBounds = CGRect(
            origin: .zero,
            size: selectionRect?.size ?? bounds.size
        )
        let clampedPoint = AnnotationGeometry.clampedPoint(point, to: annotationBounds)
        switch annotations[index] {
        case .arrow(let start, let end, let color, let lineWidth):
            switch endpoint {
            case .start:
                let next = snapsAngle
                    ? AnnotationConstraintGeometry.snappedLineEndpoint(from: end, to: clampedPoint)
                    : clampedPoint
                annotations[index] = .arrow(
                    start: AnnotationGeometry.clampedPoint(next, to: annotationBounds),
                    end: end,
                    color: color,
                    lineWidth: lineWidth
                )
            case .end:
                let next = snapsAngle
                    ? AnnotationConstraintGeometry.snappedLineEndpoint(from: start, to: clampedPoint)
                    : clampedPoint
                annotations[index] = .arrow(
                    start: start,
                    end: AnnotationGeometry.clampedPoint(next, to: annotationBounds),
                    color: color,
                    lineWidth: lineWidth
                )
            }
        case .callout(let targetRect, let arrowStart, let arrowEnd, let textOrigin, let text, let color, let lineWidth, let fontSize):
            switch endpoint {
            case .start:
                let nextPoint = snapsAngle
                    ? AnnotationConstraintGeometry.snappedLineEndpoint(from: arrowEnd, to: clampedPoint)
                    : clampedPoint
                let constrainedPoint = AnnotationGeometry.clampedPoint(nextPoint, to: annotationBounds)
                let textSize = text.isEmpty
                    ? calloutPlaceholderTextSize
                    : AnnotationTextLayout.size(for: text, fontSize: fontSize)
                let movingBounds = CGRect(origin: textOrigin, size: textSize)
                    .union(CGRect(x: arrowStart.x - 1, y: arrowStart.y - 1, width: 2, height: 2))
                let requestedDelta = CGPoint(x: constrainedPoint.x - arrowStart.x, y: constrainedPoint.y - arrowStart.y)
                let delta = AnnotationGeometry.clampedTranslation(
                    for: movingBounds,
                    requested: requestedDelta,
                    within: annotationBounds
                )
                annotations[index] = .callout(
                    targetRect: targetRect,
                    arrowStart: CGPoint(x: arrowStart.x + delta.x, y: arrowStart.y + delta.y),
                    arrowEnd: arrowEnd,
                    textOrigin: CGPoint(x: textOrigin.x + delta.x, y: textOrigin.y + delta.y),
                    text: text,
                    color: color,
                    lineWidth: lineWidth,
                    fontSize: fontSize
                )
            case .end:
                let nextPoint = snapsAngle
                    ? AnnotationConstraintGeometry.snappedLineEndpoint(from: arrowStart, to: clampedPoint)
                    : clampedPoint
                let placement = AnnotationGeometry.calloutArrowHeadPlacement(
                    proposedPoint: nextPoint,
                    targetRect: targetRect,
                    within: annotationBounds
                )
                annotations[index] = .callout(
                    targetRect: targetRect,
                    arrowStart: arrowStart,
                    arrowEnd: placement.point,
                    textOrigin: textOrigin,
                    text: text,
                    color: color,
                    lineWidth: lineWidth,
                    fontSize: fontSize
                )
            }
        default:
            return
        }
    }

    private func reattachCalloutArrowHead(for dragMode: DragMode) -> Bool {
        guard case .movingArrowEndpoint(let index, let endpoint) = dragMode, case .end = endpoint else {
            return false
        }
        guard annotations.indices.contains(index) else { return false }
        guard case .callout(
            let targetRect,
            let arrowStart,
            _,
            let textOrigin,
            let text,
            let color,
            let lineWidth,
            let fontSize
        ) = annotations[index] else {
            return false
        }
        annotations[index] = .callout(
            targetRect: targetRect,
            arrowStart: arrowStart,
            arrowEnd: AnnotationGeometry.nearestPointOnBorder(of: targetRect, to: arrowStart),
            textOrigin: textOrigin,
            text: text,
            color: color,
            lineWidth: lineWidth,
            fontSize: fontSize
        )
        return true
    }

    private func drawSelectedAnnotationHandles() {
        guard let index = selectedAnnotationIndex, annotations.indices.contains(index) else { return }
        NSColor.white.setFill()
        NSColor.controlAccentColor.setStroke()
        switch annotations[index] {
        case .rectangle(let rect, _, _, _), .ellipse(let rect, _, _, _), .mosaic(let rect, _):
            for point in annotationRectangleHandlePoints(rect: rect) {
                drawSmallHandle(at: point)
            }
        case .arrow(let start, let end, _, _):
            drawSmallHandle(at: start)
            drawSmallHandle(at: end)
        case .numberMarker(let center, _, _, _, _):
            drawSmallHandle(at: center)
        case .text(let origin, _, _, _):
            drawSmallHandle(at: origin)
        case .freehand(let points, _, let lineWidth), .highlighter(let points, _, let lineWidth):
            drawPathSelectionBounds(points: points, lineWidth: lineWidth)
        case .callout(let targetRect, let arrowStart, let arrowEnd, let textOrigin, let text, _, _, let fontSize):
            for point in annotationRectangleHandlePoints(rect: targetRect) {
                drawSmallHandle(at: point)
            }
            drawSmallHandle(at: arrowStart)
            drawSmallHandle(at: arrowEnd)
            if activeCalloutTextEditIndex != index {
                let textSize = text.isEmpty
                    ? calloutPlaceholderTextSize
                    : AnnotationTextLayout.size(for: text, fontSize: fontSize)
                let textFrame = CGRect(origin: textOrigin, size: textSize).insetBy(dx: -5, dy: -3)
                let path = NSBezierPath(roundedRect: textFrame, xRadius: 4, yRadius: 4)
                NSColor.controlAccentColor.withAlphaComponent(0.55).setStroke()
                path.lineWidth = 1
                path.setLineDash([3, 3], count: 2, phase: 0)
                path.stroke()
            }
        }
    }

    private func drawPathSelectionBounds(points: [CGPoint], lineWidth: CGFloat) {
        guard points.count > 1 else { return }
        let rect = AnnotationPathGeometry.bounds(points: points, lineWidth: lineWidth).insetBy(dx: -4, dy: -4)
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        path.lineWidth = 1
        path.setLineDash([4, 3], count: 2, phase: 0)
        path.stroke()
    }

    private func annotationRectangleHandleHit(at point: CGPoint, rect: CGRect) -> AnnotationRectHandle? {
        let handles: [(AnnotationRectHandle, CGPoint)] = [
            (.topLeft, CGPoint(x: rect.minX, y: rect.minY)),
            (.top, CGPoint(x: rect.midX, y: rect.minY)),
            (.topRight, CGPoint(x: rect.maxX, y: rect.minY)),
            (.right, CGPoint(x: rect.maxX, y: rect.midY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY)),
            (.bottom, CGPoint(x: rect.midX, y: rect.maxY)),
            (.bottomLeft, CGPoint(x: rect.minX, y: rect.maxY)),
            (.left, CGPoint(x: rect.minX, y: rect.midY))
        ]
        return handles.first { distance(point, $0.1) <= 14 }?.0
    }

    private func annotationRectangleHandlePoints(rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.midX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.midY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.midX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.midY)
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

    private func resized(
        _ rect: CGRect,
        handle: RectHandle,
        to point: CGPoint,
        preservesAspectRatio: Bool = false
    ) -> CGRect {
        if preservesAspectRatio, rect.height > 0 {
            let fixedCorner: CGPoint?
            switch handle {
            case .topLeft:
                fixedCorner = CGPoint(x: rect.maxX, y: rect.minY)
            case .topRight:
                fixedCorner = CGPoint(x: rect.minX, y: rect.minY)
            case .bottomRight:
                fixedCorner = CGPoint(x: rect.minX, y: rect.maxY)
            case .bottomLeft:
                fixedCorner = CGPoint(x: rect.maxX, y: rect.maxY)
            case .top, .right, .bottom, .left:
                fixedCorner = nil
            }
            if let fixedCorner {
                return AnnotationConstraintGeometry.aspectConstrainedRect(
                    fixedCorner: fixedCorner,
                    movingCorner: point,
                    aspectRatio: rect.width / rect.height,
                    inside: bounds
                )
            }
        }

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

    private func annotationDrawingRect(
        anchor: CGPoint,
        current: CGPoint,
        fromCenter: Bool,
        constrainedSquare: Bool
    ) -> CGRect {
        AnnotationConstraintGeometry.constrainedRect(
            anchor: anchor,
            current: current,
            constrainsToSquare: constrainedSquare,
            drawsFromCenter: fromCenter,
            inside: CGRect(origin: .zero, size: selectionRect?.size ?? bounds.size)
        )
    }

    private func dimensionText(for rect: CGRect) -> String {
        "\(Int(rect.width.rounded())) × \(Int(rect.height.rounded()))"
    }

    private func clampedAnnotationPoint(_ point: CGPoint) -> CGPoint {
        guard let selectionRect else { return point }
        return AnnotationGeometry.clampedPoint(
            point,
            to: CGRect(origin: .zero, size: selectionRect.size),
            margin: 0
        )
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

    private func appendPathPoint(
        _ point: CGPoint,
        to points: inout [CGPoint],
        minimumDistance: CGFloat = 1.25
    ) {
        guard let last = points.last else {
            points.append(point)
            return
        }
        if distance(last, point) >= minimumDistance {
            points.append(point)
        }
    }

}
