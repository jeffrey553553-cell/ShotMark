import AppKit
import CoreGraphics

enum SelectionArrowDirection {
    case left
    case right
    case down
    case up
}

enum SelectionPrecisionGeometry {
    static func pixelStep(for scale: CGFloat) -> CGFloat {
        1 / max(1, scale)
    }

    static func moved(
        _ rect: CGRect,
        direction: SelectionArrowDirection,
        distance: CGFloat,
        inside bounds: CGRect
    ) -> CGRect {
        let delta: CGPoint
        switch direction {
        case .left:
            delta = CGPoint(x: -distance, y: 0)
        case .right:
            delta = CGPoint(x: distance, y: 0)
        case .down:
            delta = CGPoint(x: 0, y: -distance)
        case .up:
            delta = CGPoint(x: 0, y: distance)
        }

        var result = rect.offsetBy(dx: delta.x, dy: delta.y)
        result.origin.x = min(max(result.minX, bounds.minX), bounds.maxX - result.width)
        result.origin.y = min(max(result.minY, bounds.minY), bounds.maxY - result.height)
        return result
    }

    static func resized(
        _ rect: CGRect,
        direction: SelectionArrowDirection,
        distance: CGFloat,
        minimumSize: CGFloat,
        inside bounds: CGRect
    ) -> CGRect {
        var result = rect
        switch direction {
        case .left:
            result.size.width = max(minimumSize, result.width - distance)
        case .right:
            result.size.width = min(bounds.maxX - result.minX, result.width + distance)
        case .down:
            result.size.height = max(minimumSize, result.height - distance)
        case .up:
            result.size.height = min(bounds.maxY - result.minY, result.height + distance)
        }
        return result
    }
}

enum SelectionMagnifierLayout {
    static let size = CGSize(width: 126, height: 150)
    static let gap: CGFloat = 18

    static func frame(
        cursor: CGPoint,
        inside bounds: CGRect,
        avoiding avoidedRects: [CGRect] = []
    ) -> CGRect {
        let origins = [
            CGPoint(x: cursor.x + gap, y: cursor.y + gap),
            CGPoint(x: cursor.x - gap - size.width, y: cursor.y + gap),
            CGPoint(x: cursor.x + gap, y: cursor.y - gap - size.height),
            CGPoint(x: cursor.x - gap - size.width, y: cursor.y - gap - size.height)
        ]
        let insetBounds = bounds.insetBy(dx: 6, dy: 6)
        let candidates = origins.map { origin -> CGRect in
            var frame = CGRect(origin: origin, size: size)
            frame.origin.x = min(max(frame.minX, insetBounds.minX), insetBounds.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, insetBounds.minY), insetBounds.maxY - frame.height)
            return frame
        }

        return candidates.min { lhs, rhs in
            collisionScore(lhs, cursor: cursor, avoidedRects: avoidedRects)
                < collisionScore(rhs, cursor: cursor, avoidedRects: avoidedRects)
        } ?? CGRect(origin: origins[0], size: size)
    }

    static func cropRect(
        cursor: CGPoint,
        viewBounds: CGRect,
        imageSize: CGSize,
        zoom: CGFloat
    ) -> CGRect {
        guard viewBounds.width > 0, viewBounds.height > 0, imageSize.width > 0, imageSize.height > 0 else {
            return .zero
        }

        let scaleX = imageSize.width / viewBounds.width
        let scaleY = imageSize.height / viewBounds.height
        let centerX = (cursor.x - viewBounds.minX) * scaleX
        let centerY = imageSize.height - 1 - (cursor.y - viewBounds.minY) * scaleY
        let pixelSpan = max(7, Int((116 / max(4, zoom)).rounded()))
        let width = min(CGFloat(pixelSpan), imageSize.width)
        let height = min(CGFloat(pixelSpan), imageSize.height)
        let x = min(max(0, centerX - width / 2), imageSize.width - width)
        let y = min(max(0, centerY - height / 2), imageSize.height - height)
        return CGRect(x: x.rounded(.down), y: y.rounded(.down), width: width, height: height)
    }

    private static func collisionScore(_ frame: CGRect, cursor: CGPoint, avoidedRects: [CGRect]) -> CGFloat {
        var score: CGFloat = frame.insetBy(dx: -8, dy: -8).contains(cursor) ? 100_000 : 0
        for avoided in avoidedRects {
            let intersection = frame.intersection(avoided)
            if !intersection.isNull {
                score += intersection.width * intersection.height
            }
        }
        return score
    }
}

final class SelectionMagnifier {
    private(set) var zoom: CGFloat = 8

    @discardableResult
    func adjustZoom(scrollDelta: CGFloat, hasPreciseDeltas: Bool) -> Bool {
        let multiplier: CGFloat = hasPreciseDeltas ? 0.22 : 1
        let next = min(16, max(4, zoom + (scrollDelta > 0 ? multiplier : -multiplier)))
        guard abs(next - zoom) > 0.001 else { return false }
        zoom = next
        return true
    }

    func draw(
        at cursor: CGPoint,
        in bounds: CGRect,
        snapshot: ScreenSnapshot,
        avoiding avoidedRects: [CGRect]
    ) {
        let outerFrame = SelectionMagnifierLayout.frame(
            cursor: cursor,
            inside: bounds,
            avoiding: avoidedRects
        )
        let cropRect = SelectionMagnifierLayout.cropRect(
            cursor: cursor,
            viewBounds: bounds,
            imageSize: CGSize(width: snapshot.image.width, height: snapshot.image.height),
            zoom: zoom
        ).integral
        guard cropRect.width > 0, cropRect.height > 0,
              let cropped = snapshot.image.cropping(to: cropRect) else {
            return
        }

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.42)
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = CGSize(width: 0, height: -5)
        shadow.set()

        let outerPath = NSBezierPath(roundedRect: outerFrame, xRadius: 11, yRadius: 11)
        NSColor(calibratedWhite: 0.075, alpha: 0.96).setFill()
        outerPath.fill()
        NSGraphicsContext.restoreGraphicsState()

        let imageFrame = CGRect(
            x: outerFrame.minX + 5,
            y: outerFrame.minY + 29,
            width: 116,
            height: 116
        )
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: imageFrame, xRadius: 7, yRadius: 7).addClip()
        NSGraphicsContext.current?.imageInterpolation = .none
        NSImage(cgImage: cropped, size: imageFrame.size).draw(
            in: imageFrame,
            from: .zero,
            operation: .copy,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
        NSGraphicsContext.restoreGraphicsState()

        let pixelWidth = imageFrame.width / cropRect.width
        let pixelHeight = imageFrame.height / cropRect.height
        let targetPixel = CGRect(
            x: imageFrame.midX - pixelWidth / 2,
            y: imageFrame.midY - pixelHeight / 2,
            width: pixelWidth,
            height: pixelHeight
        )
        let targetPath = NSBezierPath(rect: targetPixel.insetBy(dx: 0.5, dy: 0.5))
        targetPath.lineWidth = 1.2
        NSColor.systemRed.withAlphaComponent(0.95).setStroke()
        targetPath.stroke()

        let color = pixelColorHex(
            at: cursor,
            bounds: bounds,
            image: snapshot.image
        ) ?? "------"
        let scale = max(1, snapshot.screenScale)
        let pixelX = Int(((cursor.x - bounds.minX) * scale).rounded())
        let pixelY = Int(((bounds.maxY - cursor.y) * scale).rounded())
        let info = "\(Int(zoom.rounded()))x  \(pixelX),\(pixelY)  \(color)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 9.5, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.88)
        ]
        let infoSize = info.size(withAttributes: attributes)
        info.draw(
            at: CGPoint(
                x: outerFrame.midX - infoSize.width / 2,
                y: outerFrame.minY + 8
            ),
            withAttributes: attributes
        )

        let border = NSBezierPath(roundedRect: outerFrame.insetBy(dx: 0.5, dy: 0.5), xRadius: 11, yRadius: 11)
        border.lineWidth = 1
        NSColor.white.withAlphaComponent(0.18).setStroke()
        border.stroke()
    }

    private func pixelColorHex(at point: CGPoint, bounds: CGRect, image: CGImage) -> String? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scaleX = CGFloat(image.width) / bounds.width
        let scaleY = CGFloat(image.height) / bounds.height
        let x = max(0, min(image.width - 1, Int((point.x - bounds.minX) * scaleX)))
        let y = max(0, min(image.height - 1, image.height - 1 - Int((point.y - bounds.minY) * scaleY)))
        guard let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }

        var bytes = [UInt8](repeating: 0, count: 4)
        let drew = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let address = buffer.baseAddress,
                  let context = CGContext(
                    data: address,
                    width: 1,
                    height: 1,
                    bitsPerComponent: 8,
                    bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
                  ) else {
                return false
            }
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drew else { return nil }
        return String(format: "#%02X%02X%02X", bytes[0], bytes[1], bytes[2])
    }
}
