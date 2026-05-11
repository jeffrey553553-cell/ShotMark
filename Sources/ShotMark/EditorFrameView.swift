import AppKit

final class FloatingEditorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class EditorFrameView: NSView {
    private enum DragMode {
        case move
        case left
        case right
        case top
        case bottom
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight
    }

    private let canvasView: AnnotationCanvasView
    private let scrollView = NSScrollView()
    private let borderWidth: CGFloat = 4
    private let handleSize: CGFloat = 14
    private let minContentSize = CGSize(width: 180, height: 120)

    private var dragMode: DragMode?
    private var dragStartScreenPoint: CGPoint = .zero
    private var dragStartWindowFrame: CGRect = .zero

    init(canvasView: AnnotationCanvasView) {
        self.canvasView = canvasView
        super.init(frame: CGRect(origin: .zero, size: canvasView.frame.size))
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = canvasView
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        scrollView.frame = bounds.insetBy(dx: borderWidth, dy: borderWidth)
        canvasView.frame = CGRect(origin: .zero, size: canvasView.state.capture.imagePointSize)
        canvasView.bounds = CGRect(origin: .zero, size: canvasView.state.capture.imagePointSize)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if bounds.insetBy(dx: borderWidth, dy: borderWidth).contains(point) {
            return scrollView.hitTest(convert(point, to: scrollView))
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        dragMode = mode(for: convert(event.locationInWindow, from: nil))
        dragStartScreenPoint = window?.convertPoint(toScreen: event.locationInWindow) ?? .zero
        dragStartWindowFrame = window?.frame ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let dragMode else { return }
        let current = window.convertPoint(toScreen: event.locationInWindow)
        let delta = CGPoint(x: current.x - dragStartScreenPoint.x, y: current.y - dragStartScreenPoint.y)
        window.setFrame(frame(from: dragStartWindowFrame, delta: delta, mode: dragMode), display: true)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragMode = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawBorder()
        drawHandles()
    }

    private func mode(for point: CGPoint) -> DragMode {
        let left = point.x <= borderWidth + handleSize
        let right = point.x >= bounds.maxX - borderWidth - handleSize
        let top = point.y <= borderWidth + handleSize
        let bottom = point.y >= bounds.maxY - borderWidth - handleSize

        switch (left, right, top, bottom) {
        case (true, false, true, false): return .topLeft
        case (false, true, true, false): return .topRight
        case (true, false, false, true): return .bottomLeft
        case (false, true, false, true): return .bottomRight
        case (true, false, false, false): return .left
        case (false, true, false, false): return .right
        case (false, false, true, false): return .top
        case (false, false, false, true): return .bottom
        default: return .move
        }
    }

    private func frame(from start: CGRect, delta: CGPoint, mode: DragMode) -> CGRect {
        var frame = start
        let minWidth = minContentSize.width + borderWidth * 2
        let minHeight = minContentSize.height + borderWidth * 2

        func resizeLeft() {
            let newWidth = max(minWidth, start.width - delta.x)
            frame.origin.x = start.maxX - newWidth
            frame.size.width = newWidth
        }
        func resizeRight() {
            frame.size.width = max(minWidth, start.width + delta.x)
        }
        func resizeTop() {
            frame.size.height = max(minHeight, start.height + delta.y)
        }
        func resizeBottom() {
            let newHeight = max(minHeight, start.height - delta.y)
            frame.origin.y = start.maxY - newHeight
            frame.size.height = newHeight
        }

        switch mode {
        case .move:
            frame.origin.x = start.origin.x + delta.x
            frame.origin.y = start.origin.y + delta.y
        case .left:
            resizeLeft()
        case .right:
            resizeRight()
        case .top:
            resizeTop()
        case .bottom:
            resizeBottom()
        case .topLeft:
            resizeTop()
            resizeLeft()
        case .topRight:
            resizeTop()
            resizeRight()
        case .bottomLeft:
            resizeBottom()
            resizeLeft()
        case .bottomRight:
            resizeBottom()
            resizeRight()
        }

        return frame.integral
    }

    private func drawBorder() {
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: borderWidth / 2, dy: borderWidth / 2), xRadius: 5, yRadius: 5)
        path.lineWidth = borderWidth
        path.stroke()
    }

    private func drawHandles() {
        let points = [
            CGPoint(x: borderWidth, y: borderWidth),
            CGPoint(x: bounds.midX, y: borderWidth),
            CGPoint(x: bounds.maxX - borderWidth, y: borderWidth),
            CGPoint(x: bounds.maxX - borderWidth, y: bounds.midY),
            CGPoint(x: bounds.maxX - borderWidth, y: bounds.maxY - borderWidth),
            CGPoint(x: bounds.midX, y: bounds.maxY - borderWidth),
            CGPoint(x: borderWidth, y: bounds.maxY - borderWidth),
            CGPoint(x: borderWidth, y: bounds.midY)
        ]
        NSColor.white.setFill()
        NSColor.controlAccentColor.setStroke()
        for point in points {
            let rect = CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)
            let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
            path.fill()
            path.lineWidth = 1
            path.stroke()
        }
    }
}
