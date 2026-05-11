import AppKit

final class ToastWindowController: NSWindowController {
    static func show(message: String) {
        let toast = ToastWindowController(message: message)
        toast.showWindow(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.55) {
            toast.close()
        }
    }

    init(message: String) {
        let font = NSFont.systemFont(ofSize: 13.5, weight: .semibold)
        let textWidth = message.size(withAttributes: [.font: font]).width
        let width = min(max(textWidth + 68, 176), 360)
        let content = ToastContentView(
            frame: CGRect(x: 0, y: 0, width: width, height: 46),
            message: message,
            font: font
        )

        let window = NSPanel(
            contentRect: content.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = content

        if let screen = NSScreen.main {
            window.setFrameOrigin(CGPoint(
                x: screen.visibleFrame.midX - window.frame.width / 2,
                y: screen.visibleFrame.minY + 82
            ))
        }

        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class ToastContentView: NSView {
    private let message: String
    private let font: NSFont

    init(frame frameRect: NSRect, message: String, font: NSFont) {
        self.message = message
        self.font = font
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setAccessibilityLabel(message)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = CGSize(width: 0, height: -6)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
        shadow.set()
        NSColor(calibratedWhite: 0.06, alpha: 0.88).setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.withAlphaComponent(0.12).setStroke()
        let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: rect.height / 2, yRadius: rect.height / 2)
        border.lineWidth = 1
        border.stroke()

        drawCheckmark()
        drawMessage()
    }

    private func drawCheckmark() {
        let circle = CGRect(x: 18, y: bounds.midY - 8, width: 16, height: 16)
        NSColor.systemGreen.withAlphaComponent(0.95).setFill()
        NSBezierPath(ovalIn: circle).fill()

        NSColor.white.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.8
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: CGPoint(x: circle.minX + 4.2, y: circle.midY - 0.5))
        path.line(to: CGPoint(x: circle.minX + 7.1, y: circle.midY - 3.2))
        path.line(to: CGPoint(x: circle.maxX - 3.8, y: circle.midY + 3.4))
        path.stroke()
    }

    private func drawMessage() {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(0.96)
        ]
        let textRect = CGRect(x: 44, y: 0, width: bounds.width - 58, height: bounds.height)
        let size = message.size(withAttributes: attributes)
        let origin = CGPoint(
            x: textRect.minX,
            y: textRect.midY - size.height / 2
        )
        message.draw(at: origin, withAttributes: attributes)
    }
}
