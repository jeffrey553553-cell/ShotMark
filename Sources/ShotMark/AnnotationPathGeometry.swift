import AppKit
import CoreGraphics

enum AnnotationPathGeometry {
    static func smoothPath(points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)

        guard points.count > 1 else { return path }
        if points.count == 2 {
            path.addLine(to: points[1])
            return path
        }

        let firstMidpoint = midpoint(points[0], points[1])
        path.addLine(to: firstMidpoint)
        for index in 1..<(points.count - 1) {
            path.addQuadCurve(
                to: midpoint(points[index], points[index + 1]),
                control: points[index]
            )
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    static func bounds(points: [CGPoint], lineWidth: CGFloat) -> CGRect {
        smoothPath(points: points)
            .boundingBoxOfPath
            .insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
    }

    static func contains(
        _ point: CGPoint,
        points: [CGPoint],
        lineWidth: CGFloat,
        tolerance: CGFloat = 6
    ) -> Bool {
        guard points.count > 1 else { return false }
        let hitPath = smoothPath(points: points).copy(
            strokingWithWidth: max(1, lineWidth) + tolerance * 2,
            lineCap: .round,
            lineJoin: .round,
            miterLimit: 0
        )
        return hitPath.contains(point)
    }

    static func translated(_ points: [CGPoint], by delta: CGPoint) -> [CGPoint] {
        points.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
    }

    private static func midpoint(_ first: CGPoint, _ second: CGPoint) -> CGPoint {
        CGPoint(x: (first.x + second.x) / 2, y: (first.y + second.y) / 2)
    }
}

enum AnnotationConstraintGeometry {
    static func constrainedRect(
        anchor: CGPoint,
        current: CGPoint,
        constrainsToSquare: Bool,
        drawsFromCenter: Bool,
        inside bounds: CGRect
    ) -> CGRect {
        let anchor = AnnotationGeometry.clampedPoint(anchor, to: bounds, margin: 0)
        let current = AnnotationGeometry.clampedPoint(current, to: bounds, margin: 0)

        if drawsFromCenter {
            let maximumX = max(0, min(anchor.x - bounds.minX, bounds.maxX - anchor.x))
            let maximumY = max(0, min(anchor.y - bounds.minY, bounds.maxY - anchor.y))
            var extentX = min(abs(current.x - anchor.x), maximumX)
            var extentY = min(abs(current.y - anchor.y), maximumY)
            if constrainsToSquare {
                let side = min(max(extentX, extentY), maximumX, maximumY)
                extentX = side
                extentY = side
            }
            return CGRect(
                x: anchor.x - extentX,
                y: anchor.y - extentY,
                width: extentX * 2,
                height: extentY * 2
            )
        }

        guard constrainsToSquare else {
            return normalizedRect(from: anchor, to: current)
        }

        let requestedSide = max(abs(current.x - anchor.x), abs(current.y - anchor.y))
        let horizontalLimit = current.x < anchor.x
            ? anchor.x - bounds.minX
            : bounds.maxX - anchor.x
        let verticalLimit = current.y < anchor.y
            ? anchor.y - bounds.minY
            : bounds.maxY - anchor.y
        let side = min(requestedSide, max(0, horizontalLimit), max(0, verticalLimit))
        let endpoint = CGPoint(
            x: anchor.x + side * (current.x < anchor.x ? -1 : 1),
            y: anchor.y + side * (current.y < anchor.y ? -1 : 1)
        )
        return normalizedRect(from: anchor, to: endpoint)
    }

    static func squareEndpoint(from start: CGPoint, to current: CGPoint) -> CGPoint {
        let deltaX = current.x - start.x
        let deltaY = current.y - start.y
        let side = max(abs(deltaX), abs(deltaY))
        return CGPoint(
            x: start.x + side * (deltaX < 0 ? -1 : 1),
            y: start.y + side * (deltaY < 0 ? -1 : 1)
        )
    }

    static func snappedLineEndpoint(
        from start: CGPoint,
        to current: CGPoint,
        angleStep: CGFloat = .pi / 4
    ) -> CGPoint {
        let deltaX = current.x - start.x
        let deltaY = current.y - start.y
        let length = hypot(deltaX, deltaY)
        guard length > 0, angleStep > 0 else { return current }
        let angle = atan2(deltaY, deltaX)
        let snappedAngle = (angle / angleStep).rounded() * angleStep
        return CGPoint(
            x: start.x + cos(snappedAngle) * length,
            y: start.y + sin(snappedAngle) * length
        )
    }

    static func lineMeasurement(from start: CGPoint, to end: CGPoint) -> (length: CGFloat, angleDegrees: CGFloat) {
        let deltaX = end.x - start.x
        let deltaY = end.y - start.y
        let rawAngle = atan2(deltaY, deltaX) * 180 / .pi
        let normalizedAngle = rawAngle > 180 ? rawAngle - 360 : (rawAngle <= -180 ? rawAngle + 360 : rawAngle)
        return (hypot(deltaX, deltaY), normalizedAngle)
    }

    static func aspectConstrainedRect(
        fixedCorner: CGPoint,
        movingCorner: CGPoint,
        aspectRatio: CGFloat,
        inside bounds: CGRect
    ) -> CGRect {
        guard aspectRatio > 0 else {
            return normalizedRect(
                from: fixedCorner,
                to: AnnotationGeometry.clampedPoint(movingCorner, to: bounds, margin: 0)
            )
        }

        let clampedMoving = AnnotationGeometry.clampedPoint(movingCorner, to: bounds, margin: 0)
        let horizontalSign: CGFloat = clampedMoving.x < fixedCorner.x ? -1 : 1
        let verticalSign: CGFloat = clampedMoving.y < fixedCorner.y ? -1 : 1
        let rawWidth = abs(clampedMoving.x - fixedCorner.x)
        let rawHeight = abs(clampedMoving.y - fixedCorner.y)

        var width: CGFloat
        var height: CGFloat
        if rawWidth / aspectRatio >= rawHeight {
            width = rawWidth
            height = width / aspectRatio
        } else {
            height = rawHeight
            width = height * aspectRatio
        }

        let maximumWidth = horizontalSign < 0
            ? fixedCorner.x - bounds.minX
            : bounds.maxX - fixedCorner.x
        let maximumHeight = verticalSign < 0
            ? fixedCorner.y - bounds.minY
            : bounds.maxY - fixedCorner.y
        let scale = min(
            1,
            maximumWidth / max(width, 0.001),
            maximumHeight / max(height, 0.001)
        )
        width *= max(0, scale)
        height *= max(0, scale)

        return normalizedRect(
            from: fixedCorner,
            to: CGPoint(
                x: fixedCorner.x + width * horizontalSign,
                y: fixedCorner.y + height * verticalSign
            )
        )
    }

    private static func normalizedRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }
}
