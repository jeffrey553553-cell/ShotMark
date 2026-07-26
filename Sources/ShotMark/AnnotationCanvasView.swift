import AppKit

final class AnnotationCanvasView: NSView, NSTextFieldDelegate {
    let state: EditorState

    var onStateChanged: (() -> Void)?
    var onFinishEditing: (() -> Void)?
    var onCopyRequested: (() -> Void)?
    var onSaveRequested: (() -> Void)?
    var onToolShortcut: ((AnnotationTool) -> Void)?

    private enum RectHandle {
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight
    }

    private enum ArrowEndpoint {
        case start
        case end
    }

    private enum CanvasDrag {
        case drawingRectangle(start: CGPoint, current: CGPoint)
        case drawingEllipse(start: CGPoint, current: CGPoint)
        case drawingArrow(start: CGPoint, current: CGPoint)
        case drawingFreehand(points: [CGPoint])
        case drawingHighlighter(points: [CGPoint])
        case drawingCallout(start: CGPoint, current: CGPoint)
        case drawingMosaic(start: CGPoint, current: CGPoint)
        case movingAnnotation(index: Int, lastPoint: CGPoint)
        case resizingRectangle(index: Int, handle: RectHandle)
        case movingArrowEndpoint(index: Int, endpoint: ArrowEndpoint)
    }

    private var activeDrag: CanvasDrag?
    private var activeTextField: NSTextField?
    private var activeTextOrigin: CGPoint?

    init(state: EditorState) {
        self.state = state
        super.init(frame: CGRect(origin: .zero, size: state.capture.imagePointSize))
        bounds = CGRect(origin: .zero, size: state.capture.imagePointSize)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if activeTextField != nil {
            super.keyDown(with: event)
            return
        }

        let command = event.modifierFlags.contains(.command)
        if event.keyCode == 53 {
            onFinishEditing?()
            return
        }
        if event.keyCode == 49 {
            onSaveRequested?()
            return
        }
        if !command, event.charactersIgnoringModifiers == "1" {
            onToolShortcut?(.callout)
            return
        }
        if !command, event.charactersIgnoringModifiers == "2" {
            onToolShortcut?(.rectangle)
            return
        }
        if !command, event.charactersIgnoringModifiers?.lowercased() == "e" {
            onToolShortcut?(.ellipse)
            return
        }
        if !command, event.charactersIgnoringModifiers == "3" {
            onToolShortcut?(.arrow)
            return
        }
        if !command, event.charactersIgnoringModifiers?.lowercased() == "p" {
            onToolShortcut?(.pen)
            return
        }
        if !command, event.charactersIgnoringModifiers?.lowercased() == "h" {
            onToolShortcut?(.highlighter)
            return
        }
        if !command, event.charactersIgnoringModifiers == "4" {
            onToolShortcut?(.numberMarker)
            return
        }
        if !command, event.charactersIgnoringModifiers?.lowercased() == "t" {
            onToolShortcut?(.text)
            return
        }
        if !command, event.charactersIgnoringModifiers == "6" {
            onToolShortcut?(.mosaic)
            return
        }
        if command && event.charactersIgnoringModifiers?.lowercased() == "c" {
            onCopyRequested?()
            return
        }
        if command && event.charactersIgnoringModifiers?.lowercased() == "z" {
            state.undo()
            needsDisplay = true
            onStateChanged?()
            return
        }
        if command && event.charactersIgnoringModifiers?.lowercased() == "y" {
            state.redo()
            needsDisplay = true
            onStateChanged?()
            return
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        commitActiveText()

        if let drag = hitTestExistingAnnotation(at: point) {
            activeDrag = drag
            return
        }

        guard let selectedTool = state.selectedTool else {
            window?.performDrag(with: event)
            return
        }

        switch selectedTool {
        case .rectangle:
            activeDrag = .drawingRectangle(start: point, current: point)
        case .ellipse:
            activeDrag = .drawingEllipse(start: point, current: point)
        case .arrow:
            activeDrag = .drawingArrow(start: point, current: point)
        case .pen:
            activeDrag = .drawingFreehand(points: [point])
        case .highlighter:
            activeDrag = .drawingHighlighter(points: [point])
        case .callout:
            activeDrag = .drawingCallout(start: point, current: point)
        case .mosaic:
            activeDrag = .drawingMosaic(start: point, current: point)
        case .numberMarker:
            state.add(.numberMarker(center: point, number: state.nextMarkerNumber, color: .systemRed, markerSize: 13))
            state.nextMarkerNumber += 1
            needsDisplay = true
            onStateChanged?()
        case .text:
            beginTextEntry(at: point)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let drawingPoint = AnnotationGeometry.clampedPoint(point, to: bounds, margin: 0)
        switch activeDrag {
        case .drawingRectangle(let start, _):
            let current = event.modifierFlags.contains(.shift)
                ? AnnotationGeometry.clampedPoint(
                    AnnotationConstraintGeometry.squareEndpoint(from: start, to: drawingPoint),
                    to: bounds,
                    margin: 0
                )
                : drawingPoint
            activeDrag = .drawingRectangle(start: start, current: current)
        case .drawingEllipse(let start, _):
            let current = event.modifierFlags.contains(.shift)
                ? AnnotationGeometry.clampedPoint(
                    AnnotationConstraintGeometry.squareEndpoint(from: start, to: drawingPoint),
                    to: bounds,
                    margin: 0
                )
                : drawingPoint
            activeDrag = .drawingEllipse(start: start, current: current)
        case .drawingArrow(let start, _):
            let current = event.modifierFlags.contains(.shift)
                ? AnnotationGeometry.clampedPoint(
                    AnnotationConstraintGeometry.snappedLineEndpoint(from: start, to: drawingPoint),
                    to: bounds,
                    margin: 0
                )
                : drawingPoint
            activeDrag = .drawingArrow(start: start, current: current)
        case .drawingFreehand(var points):
            appendPathPoint(drawingPoint, to: &points)
            activeDrag = .drawingFreehand(points: points)
        case .drawingHighlighter(var points):
            appendPathPoint(drawingPoint, to: &points)
            activeDrag = .drawingHighlighter(points: points)
        case .drawingCallout(let start, _):
            activeDrag = .drawingCallout(start: start, current: drawingPoint)
        case .drawingMosaic(let start, _):
            activeDrag = .drawingMosaic(start: start, current: drawingPoint)
        case .movingAnnotation(let index, let lastPoint):
            moveAnnotation(at: index, by: CGPoint(x: point.x - lastPoint.x, y: point.y - lastPoint.y))
            activeDrag = .movingAnnotation(index: index, lastPoint: point)
            onStateChanged?()
        case .resizingRectangle(let index, let handle):
            resizeRectangle(at: index, handle: handle, to: point)
            onStateChanged?()
        case .movingArrowEndpoint(let index, let endpoint):
            moveArrowEndpoint(at: index, endpoint: endpoint, to: point)
            onStateChanged?()
        case nil:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let end = AnnotationGeometry.clampedPoint(
            convert(event.locationInWindow, from: nil),
            to: bounds,
            margin: 0
        )
        switch activeDrag {
        case .drawingRectangle(let start, let current):
            let rect = normalizedRect(from: start, to: current)
            if rect.width > 4, rect.height > 4 {
                state.add(.rectangle(rect: rect, color: .systemRed, lineWidth: 3, filled: false))
            }
        case .drawingEllipse(let start, let current):
            let rect = normalizedRect(from: start, to: current)
            if rect.width > 4, rect.height > 4 {
                state.add(.ellipse(rect: rect, color: .systemRed, lineWidth: 3, filled: false))
            }
        case .drawingArrow(let start, let current):
            if hypot(current.x - start.x, current.y - start.y) > 4 {
                state.add(.arrow(start: start, end: current, color: .systemRed, lineWidth: 4))
            }
        case .drawingFreehand(var points):
            appendPathPoint(end, to: &points, minimumDistance: 0.01)
            if points.count > 1 {
                state.add(.freehand(points: points, color: .systemRed, lineWidth: 3))
            }
        case .drawingHighlighter(var points):
            appendPathPoint(end, to: &points, minimumDistance: 0.01)
            if points.count > 1 {
                state.add(.highlighter(points: points, color: .systemYellow.withAlphaComponent(0.35), lineWidth: 16))
            }
        case .drawingCallout(let start, _):
            let rect = normalizedRect(from: start, to: end)
            if rect.width > 8, rect.height > 8 {
                let layout = AnnotationGeometry.calloutLayout(
                    for: rect,
                    in: bounds,
                    textSize: CGSize(width: 150, height: 30)
                )
                state.add(.callout(
                    targetRect: rect,
                    arrowStart: layout.arrowStart,
                    arrowEnd: layout.arrowEnd,
                    textOrigin: layout.textOrigin,
                    text: "",
                    color: .systemRed,
                    lineWidth: 4,
                    fontSize: 18
                ))
            }
        case .drawingMosaic(let start, _):
            let rect = normalizedRect(from: start, to: end)
            if rect.width > 4, rect.height > 4 {
                state.add(.mosaic(rect: rect, blockSize: 12))
            }
        case .movingAnnotation, .resizingRectangle, .movingArrowEndpoint, nil:
            break
        }
        activeDrag = nil
        needsDisplay = true
        onStateChanged?()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        bounds.fill()

        let image = NSImage(cgImage: state.capture.image, size: state.capture.imagePointSize)
        image.draw(in: bounds)
        drawMosaicAnnotations(state.annotations)
        AnnotationDrawing.draw(state.annotations.filter { !$0.isMosaic }, in: state.capture.imagePointSize, ocrLines: state.ocrLines)
        drawSelectedAnnotationHandles()

        switch activeDrag {
        case .drawingRectangle(let start, let current):
            AnnotationDrawing.draw([.rectangle(rect: normalizedRect(from: start, to: current), color: .systemRed, lineWidth: 3, filled: false)], in: state.capture.imagePointSize)
        case .drawingEllipse(let start, let current):
            AnnotationDrawing.draw([.ellipse(rect: normalizedRect(from: start, to: current), color: .systemRed, lineWidth: 3, filled: false)], in: state.capture.imagePointSize)
        case .drawingArrow(let start, let current):
            AnnotationDrawing.draw([.arrow(start: start, end: current, color: .systemRed, lineWidth: 4)], in: state.capture.imagePointSize)
        case .drawingFreehand(let points):
            AnnotationDrawing.draw([.freehand(points: points, color: .systemRed, lineWidth: 3)], in: state.capture.imagePointSize)
        case .drawingHighlighter(let points):
            AnnotationDrawing.draw([.highlighter(points: points, color: .systemYellow.withAlphaComponent(0.35), lineWidth: 16)], in: state.capture.imagePointSize)
        case .drawingCallout(let start, let current):
            AnnotationDrawing.draw([.rectangle(rect: normalizedRect(from: start, to: current), color: .systemRed, lineWidth: 3, filled: false)], in: state.capture.imagePointSize)
        case .drawingMosaic(let start, let current):
            MosaicRenderer.drawFrostedMosaic(
                rect: normalizedRect(from: start, to: current),
                blockSize: 12,
                sourceImage: state.capture.image,
                pointSize: state.capture.imagePointSize
            )
        case .movingAnnotation, .resizingRectangle, .movingArrowEndpoint, nil:
            break
        }
    }

    private func drawMosaicAnnotations(_ annotations: [Annotation]) {
        for annotation in annotations {
            guard case .mosaic(let rect, let blockSize) = annotation else { continue }
            MosaicRenderer.drawFrostedMosaic(
                rect: rect,
                blockSize: blockSize,
                sourceImage: state.capture.image,
                pointSize: state.capture.imagePointSize
            )
        }
    }

    private func hitTestExistingAnnotation(at point: CGPoint) -> CanvasDrag? {
        if let selectedIndex = state.selectedAnnotationIndex, state.annotations.indices.contains(selectedIndex) {
            switch state.annotations[selectedIndex] {
            case .rectangle(let rect, _, _, _), .ellipse(let rect, _, _, _), .mosaic(let rect, _):
                if let handle = rectangleHandleHit(at: point, rect: rect) {
                    return .resizingRectangle(index: selectedIndex, handle: handle)
                }
            case .arrow(let start, let end, _, _):
                if distance(point, start) <= 10 {
                    return .movingArrowEndpoint(index: selectedIndex, endpoint: .start)
                }
                if distance(point, end) <= 10 {
                    return .movingArrowEndpoint(index: selectedIndex, endpoint: .end)
                }
            case .callout(let targetRect, let arrowStart, let arrowEnd, _, _, _, _, _):
                if let handle = rectangleHandleHit(at: point, rect: targetRect) {
                    return .resizingRectangle(index: selectedIndex, handle: handle)
                }
                if distance(point, arrowStart) <= 10 {
                    return .movingArrowEndpoint(index: selectedIndex, endpoint: .start)
                }
                if distance(point, arrowEnd) <= 10 {
                    return .movingArrowEndpoint(index: selectedIndex, endpoint: .end)
                }
            case .freehand, .highlighter, .numberMarker, .text:
                break
            }
        }

        for index in state.annotations.indices.reversed() {
            if annotation(at: index, contains: point) {
                state.selectedAnnotationIndex = index
                needsDisplay = true
                return .movingAnnotation(index: index, lastPoint: point)
            }
        }
        state.selectedAnnotationIndex = nil
        return nil
    }

    private func annotation(at index: Int, contains point: CGPoint) -> Bool {
        switch state.annotations[index] {
        case .rectangle(let rect, _, _, _), .mosaic(let rect, _):
            return rectangleBorderContains(point, rect: rect)
        case .ellipse(let rect, _, let lineWidth, let filled):
            return ellipseContains(point, rect: rect, lineWidth: lineWidth, filled: filled)
        case .arrow(let start, let end, _, _):
            return distanceFromPoint(point, toLineFrom: start, to: end) <= 7
                || distance(point, start) <= 10
                || distance(point, end) <= 10
        case .freehand(let points, _, let lineWidth), .highlighter(let points, _, let lineWidth):
            return AnnotationPathGeometry.contains(point, points: points, lineWidth: lineWidth)
        case .numberMarker(let center, _, _, let markerSize):
            return distance(point, center) <= max(16, markerSize + 4)
        case .text(let origin, let value, _, let fontSize):
            let size = value.size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .semibold)])
            return CGRect(origin: origin, size: size).insetBy(dx: -6, dy: -6).contains(point)
        case .callout(let targetRect, let arrowStart, let arrowEnd, let textOrigin, let text, _, _, let fontSize):
            let size = text.isEmpty
                ? CGSize(width: 150, height: 30)
                : AnnotationTextLayout.size(for: text, fontSize: fontSize)
            return rectangleBorderContains(point, rect: targetRect)
                || distanceFromPoint(point, toLineFrom: arrowStart, to: arrowEnd) <= 7
                || CGRect(origin: textOrigin, size: size).insetBy(dx: -8, dy: -8).contains(point)
        }
    }

    private func rectangleBorderContains(_ point: CGPoint, rect: CGRect) -> Bool {
        let tolerance: CGFloat = 7
        let outer = rect.insetBy(dx: -tolerance, dy: -tolerance)
        guard outer.contains(point) else { return false }

        let inner = rect.insetBy(dx: tolerance, dy: tolerance)
        if inner.width <= 0 || inner.height <= 0 {
            return true
        }
        return !inner.contains(point)
    }

    private func ellipseContains(
        _ point: CGPoint,
        rect: CGRect,
        lineWidth: CGFloat,
        filled: Bool
    ) -> Bool {
        let radiusX = rect.width / 2
        let radiusY = rect.height / 2
        guard radiusX > 0, radiusY > 0 else { return false }
        let normalizedX = (point.x - rect.midX) / radiusX
        let normalizedY = (point.y - rect.midY) / radiusY
        let normalizedDistance = normalizedX * normalizedX + normalizedY * normalizedY
        let tolerance = (7 + lineWidth / 2) / max(1, min(radiusX, radiusY))
        _ = filled
        return abs(normalizedDistance - 1) <= tolerance
    }

    private func moveAnnotation(at index: Int, by delta: CGPoint) {
        guard state.annotations.indices.contains(index) else { return }
        let appliedDelta = AnnotationGeometry.clampedTranslation(
            for: AnnotationGeometry.visualBounds(of: state.annotations[index]),
            requested: delta,
            within: bounds
        )
        switch state.annotations[index] {
        case .rectangle(let rect, let color, let lineWidth, let filled):
            state.annotations[index] = .rectangle(rect: rect.offsetBy(dx: appliedDelta.x, dy: appliedDelta.y), color: color, lineWidth: lineWidth, filled: filled)
        case .ellipse(let rect, let color, let lineWidth, let filled):
            state.annotations[index] = .ellipse(rect: rect.offsetBy(dx: appliedDelta.x, dy: appliedDelta.y), color: color, lineWidth: lineWidth, filled: filled)
        case .arrow(let start, let end, let color, let lineWidth):
            state.annotations[index] = .arrow(
                start: CGPoint(x: start.x + appliedDelta.x, y: start.y + appliedDelta.y),
                end: CGPoint(x: end.x + appliedDelta.x, y: end.y + appliedDelta.y),
                color: color,
                lineWidth: lineWidth
            )
        case .freehand(let points, let color, let lineWidth):
            state.annotations[index] = .freehand(
                points: AnnotationPathGeometry.translated(points, by: appliedDelta),
                color: color,
                lineWidth: lineWidth
            )
        case .highlighter(let points, let color, let lineWidth):
            state.annotations[index] = .highlighter(
                points: AnnotationPathGeometry.translated(points, by: appliedDelta),
                color: color,
                lineWidth: lineWidth
            )
        case .numberMarker(let center, let number, let color, let markerSize):
            state.annotations[index] = .numberMarker(
                center: CGPoint(x: center.x + appliedDelta.x, y: center.y + appliedDelta.y),
                number: number,
                color: color,
                markerSize: markerSize
            )
        case .text(let origin, let value, let color, let fontSize):
            state.annotations[index] = .text(origin: CGPoint(x: origin.x + appliedDelta.x, y: origin.y + appliedDelta.y), value: value, color: color, fontSize: fontSize)
        case .mosaic(let rect, let blockSize):
            state.annotations[index] = .mosaic(rect: rect.offsetBy(dx: appliedDelta.x, dy: appliedDelta.y), blockSize: blockSize)
        case .callout(let targetRect, let arrowStart, let arrowEnd, let textOrigin, let text, let color, let lineWidth, let fontSize):
            state.annotations[index] = .callout(
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

    private func resizeRectangle(at index: Int, handle: RectHandle, to point: CGPoint) {
        guard state.annotations.indices.contains(index) else { return }
        let rect: CGRect
        switch state.annotations[index] {
        case .rectangle(let value, _, _, _), .ellipse(let value, _, _, _), .mosaic(let value, _), .callout(let value, _, _, _, _, _, _, _):
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
        switch state.annotations[index] {
        case .rectangle(_, let color, let lineWidth, let filled):
            state.annotations[index] = .rectangle(rect: nextRect, color: color, lineWidth: lineWidth, filled: filled)
        case .ellipse(_, let color, let lineWidth, let filled):
            state.annotations[index] = .ellipse(rect: nextRect, color: color, lineWidth: lineWidth, filled: filled)
        case .mosaic(_, let blockSize):
            state.annotations[index] = .mosaic(rect: nextRect, blockSize: blockSize)
        case .callout(_, let arrowStart, _, let textOrigin, let text, let color, let lineWidth, let fontSize):
            state.annotations[index] = .callout(
                targetRect: nextRect,
                arrowStart: arrowStart,
                arrowEnd: AnnotationGeometry.nearestPointOnBorder(of: nextRect, to: arrowStart),
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

    private func moveArrowEndpoint(at index: Int, endpoint: ArrowEndpoint, to point: CGPoint) {
        guard state.annotations.indices.contains(index) else { return }
        let clampedPoint = AnnotationGeometry.clampedPoint(point, to: bounds)
        switch state.annotations[index] {
        case .arrow(let start, let end, let color, let lineWidth):
            switch endpoint {
            case .start:
                state.annotations[index] = .arrow(start: clampedPoint, end: end, color: color, lineWidth: lineWidth)
            case .end:
                state.annotations[index] = .arrow(start: start, end: clampedPoint, color: color, lineWidth: lineWidth)
            }
        case .callout(let targetRect, let arrowStart, let arrowEnd, let textOrigin, let text, let color, let lineWidth, let fontSize):
            switch endpoint {
            case .start:
                let textSize = text.isEmpty
                    ? CGSize(width: 150, height: 30)
                    : AnnotationTextLayout.size(for: text, fontSize: fontSize)
                let movingBounds = CGRect(origin: textOrigin, size: textSize)
                    .union(CGRect(x: arrowStart.x - 1, y: arrowStart.y - 1, width: 2, height: 2))
                let requestedDelta = CGPoint(x: clampedPoint.x - arrowStart.x, y: clampedPoint.y - arrowStart.y)
                let delta = AnnotationGeometry.clampedTranslation(
                    for: movingBounds,
                    requested: requestedDelta,
                    within: bounds
                )
                state.annotations[index] = .callout(
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
                state.annotations[index] = .callout(targetRect: targetRect, arrowStart: arrowStart, arrowEnd: AnnotationGeometry.nearestPointOnBorder(of: targetRect, to: clampedPoint), textOrigin: textOrigin, text: text, color: color, lineWidth: lineWidth, fontSize: fontSize)
            }
        default:
            break
        }
    }

    private func drawSelectedAnnotationHandles() {
        guard let index = state.selectedAnnotationIndex, state.annotations.indices.contains(index) else { return }
        NSColor.white.setFill()
        NSColor.controlAccentColor.setStroke()

        switch state.annotations[index] {
        case .rectangle(let rect, _, _, _), .ellipse(let rect, _, _, _), .mosaic(let rect, _):
            for point in rectangleHandlePoints(rect: rect) {
                drawHandle(at: point)
            }
        case .arrow(let start, let end, _, _):
            drawHandle(at: start)
            drawHandle(at: end)
        case .numberMarker(let center, _, _, _):
            drawHandle(at: center)
        case .text(let origin, _, _, _):
            drawHandle(at: origin)
        case .freehand(let points, _, let lineWidth), .highlighter(let points, _, let lineWidth):
            drawPathSelectionBounds(points: points, lineWidth: lineWidth)
        case .callout(let targetRect, let arrowStart, let arrowEnd, let textOrigin, _, _, _, _):
            for point in rectangleHandlePoints(rect: targetRect) {
                drawHandle(at: point)
            }
            drawHandle(at: arrowStart)
            drawHandle(at: arrowEnd)
            drawHandle(at: textOrigin)
        }
    }

    private func rectangleHandleHit(at point: CGPoint, rect: CGRect) -> RectHandle? {
        let handles: [(RectHandle, CGPoint)] = [
            (.topLeft, CGPoint(x: rect.minX, y: rect.minY)),
            (.topRight, CGPoint(x: rect.maxX, y: rect.minY)),
            (.bottomLeft, CGPoint(x: rect.minX, y: rect.maxY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY))
        ]
        return handles.first { distance(point, $0.1) <= 10 }?.0
    }

    private func rectangleHandlePoints(rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.maxY)
        ]
    }

    private func drawHandle(at point: CGPoint) {
        let rect = CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)
        let path = NSBezierPath(ovalIn: rect)
        path.fill()
        path.lineWidth = 1.5
        path.stroke()
    }

    private func drawPathSelectionBounds(points: [CGPoint], lineWidth: CGFloat) {
        guard points.count > 1 else { return }
        let rect = AnnotationPathGeometry.bounds(points: points, lineWidth: lineWidth).insetBy(dx: -4, dy: -4)
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        path.lineWidth = 1
        path.setLineDash([4, 3], count: 2, phase: 0)
        path.stroke()
    }

    private func normalizedRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
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

    private func distanceFromPoint(_ point: CGPoint, toLineFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let lengthSquared = pow(end.x - start.x, 2) + pow(end.y - start.y, 2)
        guard lengthSquared > 0 else { return distance(point, start) }
        let t = max(0, min(1, ((point.x - start.x) * (end.x - start.x) + (point.y - start.y) * (end.y - start.y)) / lengthSquared))
        let projection = CGPoint(x: start.x + t * (end.x - start.x), y: start.y + t * (end.y - start.y))
        return distance(point, projection)
    }

    private func beginTextEntry(at point: CGPoint) {
        commitActiveText()

        let horizontal = AnnotationGeometry.fittedHorizontalEditorFrame(
            preferredMinX: point.x,
            desiredWidth: 260,
            minimumWidth: 80,
            in: bounds
        )
        let field = NSTextField(frame: CGRect(x: horizontal.minX, y: point.y - 2, width: horizontal.width, height: 30))
        field.delegate = self
        field.font = .systemFont(ofSize: 18, weight: .semibold)
        field.textColor = .systemRed
        field.backgroundColor = NSColor.white.withAlphaComponent(0.82)
        field.isBordered = false
        field.focusRingType = .none
        field.placeholderString = "输入文字"
        field.target = self
        field.action = #selector(textFieldAction(_:))
        addSubview(field)

        activeTextField = field
        activeTextOrigin = CGPoint(x: horizontal.minX, y: point.y)
        window?.makeFirstResponder(field)
    }

    private func commitActiveText() {
        guard let field = activeTextField else { return }
        let origin = activeTextOrigin ?? field.frame.origin
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.removeFromSuperview()
        activeTextField = nil
        activeTextOrigin = nil

        if !value.isEmpty {
            state.add(.text(origin: origin, value: value, color: .systemRed, fontSize: 18))
            needsDisplay = true
            onStateChanged?()
        }
    }

    @objc private func textFieldAction(_ sender: NSTextField) {
        commitActiveText()
        window?.makeFirstResponder(self)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitActiveText()
    }
}
