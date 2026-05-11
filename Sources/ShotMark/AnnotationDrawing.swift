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
            case .arrow(let start, let end, let color, let lineWidth):
                drawArrow(start: start, end: end, color: color, lineWidth: lineWidth)
            case .numberMarker(let center, let number, let color, let markerSize):
                drawNumberMarker(center: center, number: number, color: color, markerSize: markerSize)
            case .text(let origin, let value, let color, let fontSize):
                drawText(origin: origin, value: value, color: color, fontSize: fontSize)
            case .mosaic(let rect, let blockSize):
                MosaicRenderer.drawGlassPlaceholder(rect: rect, blockSize: blockSize)
            }
        }
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

    private static func drawArrow(start: CGPoint, end: CGPoint, color: NSColor, lineWidth: CGFloat) {
        let distance = hypot(end.x - start.x, end.y - start.y)
        guard distance > 0.5 else { return }

        color.setStroke()
        color.setFill()

        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength = min(max(14, lineWidth * 3.2), max(10, distance * 0.45))
        let headHalfWidth = max(6, lineWidth * 1.45)
        let baseCenter = CGPoint(
            x: end.x - headLength * cos(angle),
            y: end.y - headLength * sin(angle)
        )

        let path = NSBezierPath()
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: start)
        path.line(to: baseCenter)
        path.stroke()

        let perpendicular = angle + .pi / 2
        let left = CGPoint(
            x: baseCenter.x + headHalfWidth * cos(perpendicular),
            y: baseCenter.y + headHalfWidth * sin(perpendicular)
        )
        let right = CGPoint(
            x: baseCenter.x - headHalfWidth * cos(perpendicular),
            y: baseCenter.y - headHalfWidth * sin(perpendicular)
        )

        let head = NSBezierPath()
        head.move(to: end)
        head.line(to: left)
        head.line(to: right)
        head.close()
        head.fill()
    }

    private static func drawNumberMarker(center: CGPoint, number: Int, color: NSColor, markerSize: CGFloat) {
        let radius = max(8, markerSize)
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        color.setFill()
        NSBezierPath(ovalIn: rect).fill()

        let text = "\(number)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: max(10, radius * 1.08), weight: .bold),
            .foregroundColor: NSColor.white
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
