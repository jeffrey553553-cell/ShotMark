import AppKit

final class PinnedScreenshotWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    private let pinnedView: PinnedScreenshotView

    init(image: NSImage, pointSize: CGSize, sourceRect: CGRect, screen: NSScreen?) {
        let displaySize = Self.displaySize(for: pointSize, on: screen)
        pinnedView = PinnedScreenshotView(image: image)

        let contentSize = CGSize(
            width: displaySize.width + PinnedScreenshotView.shadowOutset * 2,
            height: displaySize.height + PinnedScreenshotView.shadowOutset * 2
        )
        let window = FloatingEditorPanel(
            contentRect: CGRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentView = pinnedView
        window.isReleasedWhenClosed = false

        super.init(window: window)

        window.delegate = self
        pinnedView.onClose = { [weak self] in
            self?.window?.close()
        }
        window.setFrame(Self.windowFrame(contentSize: contentSize, sourceRect: sourceRect, screen: screen), display: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        showWindow(nil)
        window?.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    private static func displaySize(for pointSize: CGSize, on screen: NSScreen?) -> CGSize {
        let visibleFrame = (screen ?? NSScreen.main)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let maxSize = CGSize(width: visibleFrame.width * 0.82, height: visibleFrame.height * 0.82)
        let widthScale = pointSize.width > 0 ? maxSize.width / pointSize.width : 1
        let heightScale = pointSize.height > 0 ? maxSize.height / pointSize.height : 1
        let scale = min(1, widthScale, heightScale)
        return CGSize(
            width: max(80, pointSize.width * scale),
            height: max(60, pointSize.height * scale)
        )
    }

    private static func windowFrame(contentSize: CGSize, sourceRect: CGRect, screen: NSScreen?) -> CGRect {
        let visibleFrame = (screen ?? NSScreen.main)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        var origin = CGPoint(
            x: sourceRect.minX - PinnedScreenshotView.shadowOutset,
            y: sourceRect.minY - PinnedScreenshotView.shadowOutset
        )
        origin.x = min(max(origin.x, visibleFrame.minX + 8), visibleFrame.maxX - contentSize.width - 8)
        origin.y = min(max(origin.y, visibleFrame.minY + 8), visibleFrame.maxY - contentSize.height - 8)
        return CGRect(origin: origin, size: contentSize)
    }
}

final class PinnedScreenshotView: NSView {
    static let shadowOutset: CGFloat = 12

    var onClose: (() -> Void)?

    private let image: NSImage
    private let closeButtonSize: CGFloat = 24

    init(image: NSImage) {
        self.image = image
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if closeButtonFrame.insetBy(dx: -6, dy: -6).contains(point) {
            onClose?()
            return
        }
        window?.performDrag(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let imageFrame = imageFrame
        let imagePath = NSBezierPath(roundedRect: imageFrame, xRadius: 6, yRadius: 6)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.38)
        shadow.shadowBlurRadius = 24
        shadow.shadowOffset = CGSize(width: 0, height: -7)
        shadow.set()
        NSColor.black.withAlphaComponent(0.18).setFill()
        imagePath.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        imagePath.addClip()
        image.draw(in: imageFrame, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.withAlphaComponent(0.28).setStroke()
        imagePath.lineWidth = 1
        imagePath.stroke()

        drawCloseButton()
    }

    private var imageFrame: CGRect {
        bounds.insetBy(dx: Self.shadowOutset, dy: Self.shadowOutset)
    }

    private var closeButtonFrame: CGRect {
        let frame = imageFrame
        return CGRect(
            x: frame.maxX - closeButtonSize - 8,
            y: frame.maxY - closeButtonSize - 8,
            width: closeButtonSize,
            height: closeButtonSize
        )
    }

    private func drawCloseButton() {
        let rect = closeButtonFrame
        NSColor.black.withAlphaComponent(0.62).setFill()
        NSBezierPath(ovalIn: rect).fill()
        NSColor.white.withAlphaComponent(0.92).setStroke()

        let path = NSBezierPath()
        path.lineWidth = 1.8
        path.lineCapStyle = .round
        path.move(to: CGPoint(x: rect.minX + 8, y: rect.minY + 8))
        path.line(to: CGPoint(x: rect.maxX - 8, y: rect.maxY - 8))
        path.move(to: CGPoint(x: rect.maxX - 8, y: rect.minY + 8))
        path.line(to: CGPoint(x: rect.minX + 8, y: rect.maxY - 8))
        path.stroke()
    }
}
