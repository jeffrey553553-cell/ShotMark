import AppKit
import CoreGraphics

enum AnnotationTextLayout {
    static func attributes(color: NSColor, fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: color
        ]
    }

    static func size(for value: String, fontSize: CGFloat) -> CGSize {
        let attributes = attributes(color: .systemRed, fontSize: fontSize)
        let rect = (value as NSString).boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        return CGSize(width: ceil(rect.width), height: ceil(rect.height))
    }
}

enum AnnotationDrawing {
    static func draw(_ annotations: [Annotation], in size: CGSize, ocrLines: [OCRLine] = []) {
        for line in ocrLines {
            drawOCRBox(line.boundingBox, imageSize: size)
        }

        for annotation in annotations {
            switch annotation {
            case .rectangle(let rect, let color, let lineWidth, let filled):
                drawRectangle(rect: rect, color: color, lineWidth: lineWidth, filled: filled)
            case .ellipse(let rect, let color, let lineWidth, let filled):
                drawEllipse(rect: rect, color: color, lineWidth: lineWidth, filled: filled)
            case .arrow(let start, let end, let color, let lineWidth):
                drawArrow(start: start, end: end, color: color, lineWidth: lineWidth)
            case .freehand(let points, let color, let lineWidth):
                drawFreehand(points: points, color: color, lineWidth: lineWidth)
            case .highlighter(let points, let color, let lineWidth):
                drawHighlighter(points: points, color: color, lineWidth: lineWidth)
            case .numberMarker(let center, let number, let color, let markerSize, let appearance):
                drawNumberMarker(
                    center: center,
                    number: number,
                    color: color,
                    markerSize: markerSize,
                    appearance: appearance
                )
            case .text(let origin, let value, let color, let fontSize):
                drawText(origin: origin, value: value, color: color, fontSize: fontSize)
            case .mosaic(let rect, let blockSize):
                MosaicRenderer.drawGlassPlaceholder(rect: rect, blockSize: blockSize)
            case .callout(let targetRect, let arrowStart, let arrowEnd, let textOrigin, let text, let color, let lineWidth, let fontSize):
                drawCalloutTarget(rect: targetRect, color: color, lineWidth: lineWidth)
                drawArrow(start: arrowStart, end: arrowEnd, color: color, lineWidth: lineWidth)
                drawText(origin: textOrigin, value: text, color: color, fontSize: fontSize)
            }
        }
    }

    private static func drawCalloutTarget(rect: CGRect, color: NSColor, lineWidth: CGFloat) {
        color.setStroke()
        let radius = min(6, max(3, min(rect.width, rect.height) * 0.08))
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        path.lineWidth = max(1.5, lineWidth * 0.78)
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    private static func drawRectangle(rect: CGRect, color: NSColor, lineWidth: CGFloat, filled: Bool) {
        if filled {
            color.setFill()
            NSBezierPath(rect: rect).fill()
        }
        color.setStroke()
        let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
        path.lineWidth = lineWidth
        path.stroke()
    }

    private static func drawEllipse(rect: CGRect, color: NSColor, lineWidth: CGFloat, filled: Bool) {
        if filled {
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
        }
        color.setStroke()
        let inset = min(max(0, lineWidth / 2), max(0, min(rect.width, rect.height) / 2 - 0.5))
        let path = NSBezierPath(ovalIn: rect.insetBy(dx: inset, dy: inset))
        path.lineWidth = lineWidth
        path.stroke()
    }

    private static func drawFreehand(points: [CGPoint], color: NSColor, lineWidth: CGFloat) {
        guard points.count > 1 else { return }
        color.setStroke()
        let path = NSBezierPath(cgPath: AnnotationPathGeometry.smoothPath(points: points))
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    private static func drawHighlighter(points: [CGPoint], color: NSColor, lineWidth: CGFloat) {
        guard points.count > 1 else { return }
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        let opacity = min(max(rgb.alphaComponent, 0), 1)
        let opaqueColor = rgb.withAlphaComponent(1)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.setAlpha(opacity)
        NSGraphicsContext.current?.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
        opaqueColor.setStroke()
        let path = NSBezierPath(cgPath: AnnotationPathGeometry.smoothPath(points: points))
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
        NSGraphicsContext.current?.cgContext.endTransparencyLayer()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawArrow(start: CGPoint, end: CGPoint, color: NSColor, lineWidth: CGFloat) {
        let distance = hypot(end.x - start.x, end.y - start.y)
        guard distance > 0.5 else { return }

        color.setFill()

        let angle = atan2(end.y - start.y, end.x - start.x)
        let perpendicular = angle + .pi / 2
        let direction = CGVector(dx: cos(angle), dy: sin(angle))
        let normal = CGVector(dx: cos(perpendicular), dy: sin(perpendicular))
        let headLength = min(max(18, lineWidth * 4.8), max(12, distance * 0.48))
        let headHalfWidth = min(max(8, lineWidth * 2.1), max(7, distance * 0.24))
        let tailHalfWidth = max(1.2, lineWidth * 0.36)
        let neckHalfWidth = max(tailHalfWidth + 1.5, lineWidth * 0.82)
        let neck = CGPoint(x: end.x - headLength * direction.dx, y: end.y - headLength * direction.dy)
        let tailInset = min(max(1.5, lineWidth * 0.5), distance * 0.16)
        let tail = CGPoint(x: start.x + tailInset * direction.dx, y: start.y + tailInset * direction.dy)

        let path = NSBezierPath()
        path.move(to: CGPoint(x: tail.x + tailHalfWidth * normal.dx, y: tail.y + tailHalfWidth * normal.dy))
        path.line(to: CGPoint(x: neck.x + neckHalfWidth * normal.dx, y: neck.y + neckHalfWidth * normal.dy))
        path.line(to: CGPoint(x: neck.x + headHalfWidth * normal.dx, y: neck.y + headHalfWidth * normal.dy))
        path.line(to: end)
        path.line(to: CGPoint(x: neck.x - headHalfWidth * normal.dx, y: neck.y - headHalfWidth * normal.dy))
        path.line(to: CGPoint(x: neck.x - neckHalfWidth * normal.dx, y: neck.y - neckHalfWidth * normal.dy))
        path.line(to: CGPoint(x: tail.x - tailHalfWidth * normal.dx, y: tail.y - tailHalfWidth * normal.dy))
        path.close()
        path.fill()
    }

    private static func drawNumberMarker(
        center: CGPoint,
        number: Int,
        color: NSColor,
        markerSize: CGFloat,
        appearance: NumberMarkerAppearance
    ) {
        let radius = max(8, markerSize)
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        let path = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
        let textColor: NSColor

        switch appearance {
        case .filled:
            color.setFill()
            path.fill()
            textColor = .white
        case .outlined:
            color.withAlphaComponent(0.08).setFill()
            path.fill()
            color.setStroke()
            path.lineWidth = max(2, radius * 0.14)
            path.stroke()
            textColor = color
        case .light:
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.24)
            shadow.shadowBlurRadius = max(2, radius * 0.22)
            shadow.shadowOffset = CGSize(width: 0, height: -1)
            shadow.set()
            NSColor.white.withAlphaComponent(0.94).setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
            color.withAlphaComponent(0.72).setStroke()
            path.lineWidth = max(1.25, radius * 0.08)
            path.stroke()
            textColor = color
        }

        let text = "\(number)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: max(10, radius * 1.08), weight: .bold),
            .foregroundColor: textColor
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), withAttributes: attributes)
    }

    private static func drawText(origin: CGPoint, value: String, color: NSColor, fontSize: CGFloat) {
        let attributes = AnnotationTextLayout.attributes(color: color, fontSize: fontSize)
        let size = AnnotationTextLayout.size(for: value, fontSize: fontSize)
        (value as NSString).draw(with: CGRect(origin: origin, size: size), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
    }

    private static func drawOCRBox(_ normalizedBox: CGRect, imageSize: CGSize) {
        let rect = CGRect(
            x: normalizedBox.minX * imageSize.width,
            y: (1 - normalizedBox.maxY) * imageSize.height,
            width: normalizedBox.width * imageSize.width,
            height: normalizedBox.height * imageSize.height
        )
        NSColor.systemYellow.withAlphaComponent(0.18).setFill()
        NSBezierPath(rect: rect).fill()
        NSColor.systemYellow.setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 1.5
        path.stroke()
    }
}
