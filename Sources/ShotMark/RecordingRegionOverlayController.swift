import AppKit

final class RecordingRegionOverlayController {
    private let selection: CaptureSelection
    private let startedAt: Date
    private let onStop: () -> Void
    private var windows: [NSWindow] = []
    private var stopWindow: NSWindow?
    private var timer: Timer?

    init(selection: CaptureSelection, startedAt: Date, onStop: @escaping () -> Void) {
        self.selection = selection
        self.startedAt = startedAt
        self.onStop = onStop
    }

    func show() {
        close()
        windows = NSScreen.screens.map { screen in
            let view = RecordingRegionOverlayView(screen: screen, selection: selection)
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
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.contentView = view
            window.orderFrontRegardless()
            return window
        }
        showStopWindow()
        startTimer()
    }

    func close() {
        timer?.invalidate()
        timer = nil
        stopWindow?.orderOut(nil)
        stopWindow = nil
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }

    private func showStopWindow() {
        let screen = selection.screen
        let size = CGSize(width: 134, height: 34)
        let visibleFrame = screen.visibleFrame
        let frame = CGRect(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.maxY - size.height - 10,
            width: size.width,
            height: size.height
        )
        let view = RecordingStopControlView(startedAt: startedAt)
        view.onStop = { [weak self] in self?.onStop() }

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
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentView = view
        window.orderFrontRegardless()
        stopWindow = window
    }

    private func startTimer() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            (self?.stopWindow?.contentView as? RecordingStopControlView)?.needsDisplay = true
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}

final class RecordingRegionOverlayView: NSView {
    private let targetScreen: NSScreen
    private let selection: CaptureSelection

    init(screen: NSScreen, selection: CaptureSelection) {
        targetScreen = screen
        self.selection = selection
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

        NSColor.systemRed.setStroke()
        let framePath = NSBezierPath(rect: rect)
        framePath.lineWidth = 2
        framePath.stroke()

        NSColor.systemRed.withAlphaComponent(0.22).setStroke()
        let glowPath = NSBezierPath(rect: rect.insetBy(dx: -4, dy: -4))
        glowPath.lineWidth = 4
        glowPath.stroke()

        let badgeText = "正在录制"
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
        NSColor.systemRed.withAlphaComponent(0.92).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 7, yRadius: 7).fill()
        badgeText.draw(at: CGPoint(x: badge.minX + 12, y: badge.midY - textSize.height / 2), withAttributes: attributes)
    }

    private func sameScreen(_ first: NSScreen, _ second: NSScreen) -> Bool {
        first.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            == second.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

final class RecordingStopControlView: NSView {
    var onStop: (() -> Void)?

    private let startedAt: Date

    init(startedAt: Date) {
        self.startedAt = startedAt
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        onStop?()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let pill = bounds.insetBy(dx: 1, dy: 1)
        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()

        let iconRect = CGRect(x: pill.minX + 13, y: pill.midY - 5, width: 10, height: 10)
        NSColor.systemRed.setFill()
        NSBezierPath(roundedRect: iconRect, xRadius: 2, yRadius: 2).fill()

        let elapsed = max(0, Int(Date().timeIntervalSince(startedAt)))
        let text = String(format: "停止 %02d:%02d", elapsed / 60, elapsed % 60)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(at: CGPoint(x: iconRect.maxX + 10, y: pill.midY - size.height / 2), withAttributes: attributes)
    }
}
