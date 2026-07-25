import AppKit

final class RecordingRegionOverlayController {
    private let selection: CaptureSelection
    private let onStop: () -> Void
    private let onTogglePause: () -> Void
    private var state: RecordingUIState
    private var windows: [NSWindow] = []
    private var controlWindow: NSWindow?
    private var timer: Timer?

    init(
        selection: CaptureSelection,
        initialState: RecordingUIState,
        onStop: @escaping () -> Void,
        onTogglePause: @escaping () -> Void
    ) {
        self.selection = selection
        state = initialState
        self.onStop = onStop
        self.onTogglePause = onTogglePause
    }

    func show() {
        close()
        windows = NSScreen.screens.map { screen in
            let view = RecordingRegionOverlayView(
                screen: screen,
                selection: selection,
                state: state
            )
            let window = NSPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.sharingType = .none
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.contentView = view
            window.orderFrontRegardless()
            return window
        }
        showControlWindow()
        startTimer()
    }

    func update(state: RecordingUIState) {
        self.state = state
        for window in windows {
            guard let view = window.contentView as? RecordingRegionOverlayView else { continue }
            view.state = state
        }
        if let control = controlWindow?.contentView as? RecordingControlView {
            control.state = state
        }
    }

    func close() {
        timer?.invalidate()
        timer = nil
        controlWindow?.orderOut(nil)
        controlWindow = nil
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }

    private func showControlWindow() {
        let screen = selection.screen
        let size = CGSize(width: 184, height: 38)
        let visibleFrame = screen.visibleFrame
        let frame = CGRect(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.maxY - size.height - 10,
            width: size.width,
            height: size.height
        )
        let view = RecordingControlView(state: state)
        view.onStop = { [weak self] in self?.onStop() }
        view.onTogglePause = { [weak self] in self?.onTogglePause() }

        let window = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 3)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.sharingType = .none
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentView = view
        window.orderFrontRegardless()
        controlWindow = window
    }

    private func startTimer() {
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            (self?.controlWindow?.contentView as? RecordingControlView)?.needsDisplay = true
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}

final class RecordingRegionOverlayView: NSView {
    var state: RecordingUIState {
        didSet { needsDisplay = true }
    }

    private let targetScreen: NSScreen
    private let selection: CaptureSelection

    init(screen: NSScreen, selection: CaptureSelection, state: RecordingUIState) {
        targetScreen = screen
        self.selection = selection
        self.state = state
        super.init(frame: CGRect(origin: .zero, size: screen.frame.size))
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard sameScreen(targetScreen, selection.screen) else {
            NSColor.black.withAlphaComponent(0.18).setFill()
            bounds.fill()
            return
        }

        let recordingRect = selection.rectInScreen
            .offsetBy(dx: -targetScreen.frame.minX, dy: -targetScreen.frame.minY)
            .intersection(bounds)

        let dimPath = NSBezierPath(rect: bounds)
        dimPath.append(NSBezierPath(rect: recordingRect))
        dimPath.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.32).setFill()
        dimPath.fill()

        drawRecordingFrame(recordingRect)
    }

    private func drawRecordingFrame(_ rect: CGRect) {
        guard rect.width > 1, rect.height > 1 else { return }

        let color = state.overlayColor
        color.setStroke()
        let framePath = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
        framePath.lineWidth = 2
        framePath.stroke()

        color.withAlphaComponent(0.2).setStroke()
        let glowPath = NSBezierPath(rect: rect.insetBy(dx: -3, dy: -3))
        glowPath.lineWidth = 4
        glowPath.stroke()

        let badgeText = state.overlayStatusText
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let textSize = badgeText.size(withAttributes: attributes)
        let badge = CGRect(
            x: rect.minX,
            y: min(bounds.maxY - textSize.height - 18, rect.maxY + 8),
            width: textSize.width + 24,
            height: textSize.height + 10
        )
        color.withAlphaComponent(0.94).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 7, yRadius: 7).fill()
        badgeText.draw(
            at: CGPoint(x: badge.minX + 12, y: badge.midY - textSize.height / 2),
            withAttributes: attributes
        )
    }

    private func sameScreen(_ first: NSScreen, _ second: NSScreen) -> Bool {
        first.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            == second.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

final class RecordingControlView: NSView {
    var onStop: (() -> Void)?
    var onTogglePause: (() -> Void)?
    var state: RecordingUIState {
        didSet { needsDisplay = true }
    }

    private enum HoveredAction {
        case pause
        case stop
    }

    private var hoveredAction: HoveredAction? {
        didSet {
            if oldValue != hoveredAction {
                needsDisplay = true
            }
        }
    }
    private var trackingAreaReference: NSTrackingArea?

    init(state: RecordingUIState) {
        self.state = state
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setAccessibilityLabel("录制控制")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let tracking = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)
        trackingAreaReference = tracking
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hoveredAction = action(at: point)
    }

    override func mouseExited(with event: NSEvent) {
        hoveredAction = nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch action(at: point) {
        case .pause:
            guard state.canTogglePause else { return }
            onTogglePause?()
        case .stop:
            onStop?()
        case nil:
            break
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let pill = bounds.insetBy(dx: 1, dy: 1)
        NSColor.black.withAlphaComponent(0.82).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 10, yRadius: 10).fill()
        NSColor.white.withAlphaComponent(0.13).setStroke()
        let border = NSBezierPath(
            roundedRect: pill.insetBy(dx: 0.5, dy: 0.5),
            xRadius: 9.5,
            yRadius: 9.5
        )
        border.lineWidth = 1
        border.stroke()

        drawHoverBackground()
        drawPauseAction()
        NSColor.white.withAlphaComponent(0.12).setFill()
        CGRect(x: pauseButtonFrame.maxX + 5, y: pill.minY + 7, width: 1, height: pill.height - 14).fill()
        drawStopAction()
    }

    private var pauseButtonFrame: CGRect {
        CGRect(x: 5, y: 4, width: 34, height: bounds.height - 8)
    }

    private var stopButtonFrame: CGRect {
        CGRect(x: 46, y: 4, width: bounds.width - 51, height: bounds.height - 8)
    }

    private func action(at point: CGPoint) -> HoveredAction? {
        if pauseButtonFrame.contains(point) {
            return .pause
        }
        if stopButtonFrame.contains(point) {
            return .stop
        }
        return nil
    }

    private func drawHoverBackground() {
        let frame: CGRect?
        switch hoveredAction {
        case .pause:
            frame = pauseButtonFrame
        case .stop:
            frame = stopButtonFrame
        case nil:
            frame = nil
        }
        guard let frame else { return }
        NSColor.white.withAlphaComponent(0.1).setFill()
        NSBezierPath(roundedRect: frame, xRadius: 7, yRadius: 7).fill()
    }

    private func drawPauseAction() {
        let color = state.canTogglePause
            ? NSColor.white.withAlphaComponent(0.92)
            : NSColor.white.withAlphaComponent(0.34)
        color.setFill()

        if state.isPaused {
            let path = NSBezierPath()
            path.move(to: CGPoint(x: pauseButtonFrame.midX - 4, y: pauseButtonFrame.midY - 6))
            path.line(to: CGPoint(x: pauseButtonFrame.midX + 6, y: pauseButtonFrame.midY))
            path.line(to: CGPoint(x: pauseButtonFrame.midX - 4, y: pauseButtonFrame.midY + 6))
            path.close()
            path.fill()
        } else {
            CGRect(
                x: pauseButtonFrame.midX - 5,
                y: pauseButtonFrame.midY - 6,
                width: 3.5,
                height: 12
            ).fill()
            CGRect(
                x: pauseButtonFrame.midX + 1.5,
                y: pauseButtonFrame.midY - 6,
                width: 3.5,
                height: 12
            ).fill()
        }
    }

    private func drawStopAction() {
        let iconRect = CGRect(
            x: stopButtonFrame.minX + 10,
            y: stopButtonFrame.midY - 5,
            width: 10,
            height: 10
        )
        NSColor.systemRed.setFill()
        NSBezierPath(roundedRect: iconRect, xRadius: 2, yRadius: 2).fill()

        let elapsed = max(0, Int(state.elapsed()))
        let text = String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: CGPoint(x: iconRect.maxX + 10, y: stopButtonFrame.midY - size.height / 2),
            withAttributes: attributes
        )

        let status = state.controlStatusText
        let statusAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: state.overlayColor.withAlphaComponent(0.95)
        ]
        let statusSize = status.size(withAttributes: statusAttributes)
        status.draw(
            at: CGPoint(
                x: stopButtonFrame.maxX - statusSize.width - 9,
                y: stopButtonFrame.midY - statusSize.height / 2
            ),
            withAttributes: statusAttributes
        )
    }
}

private extension RecordingUIState {
    var canTogglePause: Bool {
        switch self {
        case .recording, .paused:
            return true
        case .idle, .starting, .pausing, .resuming, .stopping:
            return false
        }
    }

    var overlayColor: NSColor {
        switch self {
        case .paused, .pausing:
            return .systemOrange
        case .resuming:
            return .systemYellow
        case .idle, .starting, .recording, .stopping:
            return .systemRed
        }
    }

    var overlayStatusText: String {
        switch self {
        case .paused:
            return "录制已暂停"
        case .pausing:
            return "正在暂停"
        case .resuming:
            return "正在继续"
        case .idle, .starting, .recording, .stopping:
            return "正在录制"
        }
    }

    var controlStatusText: String {
        switch self {
        case .paused:
            return "已暂停"
        case .pausing:
            return "暂停中"
        case .resuming:
            return "继续中"
        case .idle, .starting, .recording, .stopping:
            return "录制中"
        }
    }
}
