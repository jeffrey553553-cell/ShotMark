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
}
