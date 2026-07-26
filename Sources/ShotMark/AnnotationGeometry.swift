import AppKit

struct CalloutLayout: Equatable {
    let arrowStart: CGPoint
    let arrowEnd: CGPoint
    let textOrigin: CGPoint
}

struct CalloutTargetPlacement: Equatable {
    let targetRect: CGRect
    let arrowEnd: CGPoint
}

struct CalloutTextPlacement: Equatable {
    let arrowStart: CGPoint
    let textOrigin: CGPoint
}

enum CalloutHitRegion: Equatable {
    case targetBorder
    case arrow
    case text
}

enum AnnotationGeometry {
    static let canvasMargin: CGFloat = 2

    static func clampedPoint(_ point: CGPoint, to bounds: CGRect, margin: CGFloat = canvasMargin) -> CGPoint {
        let available = bounds.insetBy(dx: margin, dy: margin)
        guard available.width >= 0, available.height >= 0 else {
            return CGPoint(x: bounds.midX, y: bounds.midY)
        }
        return CGPoint(
            x: min(max(point.x, available.minX), available.maxX),
            y: min(max(point.y, available.minY), available.maxY)
        )
    }

    static func fittedHorizontalEditorFrame(
        preferredMinX: CGFloat,
        desiredWidth: CGFloat,
        minimumWidth: CGFloat,
        in bounds: CGRect,
        margin: CGFloat = canvasMargin
    ) -> (minX: CGFloat, width: CGFloat) {
        let available = bounds.insetBy(dx: margin, dy: 0)
        let width = min(
            max(1, available.width),
            max(minimumWidth, desiredWidth)
        )
        let minX = min(
            max(preferredMinX, available.minX),
            max(available.minX, available.maxX - width)
        )
        return (minX, width)
    }

    static func nearestPointOnBorder(of rect: CGRect, to point: CGPoint) -> CGPoint {
        guard rect.width > 0, rect.height > 0 else { return rect.origin }
        let clamped = CGPoint(
            x: min(max(point.x, rect.minX), rect.maxX),
            y: min(max(point.y, rect.minY), rect.maxY)
        )
        guard rect.contains(point) else { return clamped }

        let candidates: [(distance: CGFloat, point: CGPoint)] = [
            (abs(point.x - rect.minX), CGPoint(x: rect.minX, y: point.y)),
            (abs(point.x - rect.maxX), CGPoint(x: rect.maxX, y: point.y)),
            (abs(point.y - rect.minY), CGPoint(x: point.x, y: rect.minY)),
            (abs(point.y - rect.maxY), CGPoint(x: point.x, y: rect.maxY))
        ]
        return candidates.min { $0.distance < $1.distance }?.point ?? clamped
    }

    static func calloutLayout(
        for targetRect: CGRect,
        in bounds: CGRect,
        textSize: CGSize,
        margin: CGFloat = 8
    ) -> CalloutLayout {
        let safeBounds = bounds.insetBy(dx: margin, dy: margin)
        let fittedTextSize = CGSize(
            width: min(max(1, textSize.width), max(1, safeBounds.width)),
            height: min(max(1, textSize.height), max(1, safeBounds.height))
        )
        let placementGap: CGFloat = 84
        let candidates = [
            CGPoint(x: targetRect.maxX + placementGap, y: targetRect.maxY + placementGap),
            CGPoint(x: targetRect.minX - placementGap - fittedTextSize.width, y: targetRect.maxY + placementGap),
            CGPoint(x: targetRect.maxX + placementGap, y: targetRect.minY - placementGap - fittedTextSize.height),
            CGPoint(x: targetRect.minX - placementGap - fittedTextSize.width, y: targetRect.minY - placementGap - fittedTextSize.height),
            CGPoint(x: targetRect.maxX + placementGap, y: targetRect.midY - fittedTextSize.height / 2),
            CGPoint(x: targetRect.minX - placementGap - fittedTextSize.width, y: targetRect.midY - fittedTextSize.height / 2),
            CGPoint(x: targetRect.midX - fittedTextSize.width / 2, y: targetRect.maxY + placementGap),
            CGPoint(x: targetRect.midX - fittedTextSize.width / 2, y: targetRect.minY - placementGap - fittedTextSize.height)
        ]

        let ranked = candidates.enumerated().map { index, origin -> (CGFloat, CGPoint) in
            let clampedOrigin = clampOrigin(origin, size: fittedTextSize, to: safeBounds)
            let clampedFrame = CGRect(origin: clampedOrigin, size: fittedTextSize)
            let displacement = hypot(clampedOrigin.x - origin.x, clampedOrigin.y - origin.y)
            let overlap = intersectionArea(clampedFrame, targetRect)
            let distance = hypot(clampedFrame.midX - targetRect.midX, clampedFrame.midY - targetRect.midY)
            let straightPlacementPenalty: CGFloat = index < 4 ? 0 : 320
            let score = displacement * 1_000
                + overlap * 10_000
                + straightPlacementPenalty
                + distance
                + CGFloat(index) * 0.01
            return (score, clampedOrigin)
        }
        let textOrigin = ranked.min { $0.0 < $1.0 }?.1
            ?? clampOrigin(candidates[0], size: fittedTextSize, to: safeBounds)
        let connector = calloutConnector(
            targetRect: targetRect,
            textFrame: CGRect(origin: textOrigin, size: fittedTextSize),
            in: bounds
        )
        return CalloutLayout(
            arrowStart: connector.arrowStart,
            arrowEnd: connector.arrowEnd,
            textOrigin: textOrigin
        )
    }

    static func calloutConnector(
        targetRect: CGRect,
        textFrame: CGRect,
        in bounds: CGRect,
        textClearance: CGFloat = 24
    ) -> (arrowStart: CGPoint, arrowEnd: CGPoint) {
        let targetCenter = CGPoint(x: targetRect.midX, y: targetRect.midY)
        let textEdge = nearestPointOnBorder(of: textFrame, to: targetCenter)
        let direction = CGVector(
            dx: targetCenter.x - textEdge.x,
            dy: targetCenter.y - textEdge.y
        )
        let length = max(1, hypot(direction.dx, direction.dy))
        let arrowStart = clampedPoint(
            CGPoint(
                x: textEdge.x + direction.dx / length * textClearance,
                y: textEdge.y + direction.dy / length * textClearance
            ),
            to: bounds
        )
        return (
            arrowStart,
            nearestPointOnBorder(of: targetRect, to: arrowStart)
        )
    }

    static func calloutHitRegion(
        at point: CGPoint,
        targetRect: CGRect,
        arrowStart: CGPoint,
        arrowEnd: CGPoint,
        textFrame: CGRect,
        lineWidth: CGFloat
    ) -> CalloutHitRegion? {
        if textFrame.insetBy(dx: -10, dy: -8).contains(point) {
            return .text
        }
        if rectangleBorderContains(point, rect: targetRect, lineWidth: lineWidth) {
            return .targetBorder
        }
        if arrowContains(point, start: arrowStart, end: arrowEnd, lineWidth: lineWidth) {
            return .arrow
        }
        return nil
    }

    static func movedCalloutTarget(
        targetRect: CGRect,
        arrowStart: CGPoint,
        requestedDelta: CGPoint,
        within bounds: CGRect
    ) -> CalloutTargetPlacement {
        let appliedDelta = clampedTranslation(
            for: targetRect,
            requested: requestedDelta,
            within: bounds
        )
        let nextTarget = targetRect.offsetBy(dx: appliedDelta.x, dy: appliedDelta.y)
        return CalloutTargetPlacement(
            targetRect: nextTarget,
            arrowEnd: nearestPointOnBorder(of: nextTarget, to: arrowStart)
        )
    }

    static func movedCalloutText(
        textFrame: CGRect,
        arrowStart: CGPoint,
        requestedDelta: CGPoint,
        within bounds: CGRect
    ) -> CalloutTextPlacement {
        let movingBounds = textFrame
            .union(CGRect(x: arrowStart.x - 1, y: arrowStart.y - 1, width: 2, height: 2))
        let appliedDelta = clampedTranslation(
            for: movingBounds,
            requested: requestedDelta,
            within: bounds
        )
        return CalloutTextPlacement(
            arrowStart: CGPoint(
                x: arrowStart.x + appliedDelta.x,
                y: arrowStart.y + appliedDelta.y
            ),
            textOrigin: CGPoint(
                x: textFrame.minX + appliedDelta.x,
                y: textFrame.minY + appliedDelta.y
            )
        )
    }

    static func visualBounds(
        of annotation: Annotation,
        emptyCalloutTextSize: CGSize = CGSize(width: 150, height: 30)
    ) -> CGRect {
        switch annotation {
        case .rectangle(let rect, _, let lineWidth, _),
             .ellipse(let rect, _, let lineWidth, _):
            return rect.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
        case .arrow(let start, let end, _, let lineWidth):
            return CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            ).insetBy(dx: -max(10, lineWidth * 2.2), dy: -max(10, lineWidth * 2.2))
        case .freehand(let points, _, let lineWidth),
             .highlighter(let points, _, let lineWidth):
            return AnnotationPathGeometry.bounds(points: points, lineWidth: lineWidth)
        case .numberMarker(let center, _, _, let markerSize, _):
            let radius = max(8, markerSize)
            return CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        case .text(let origin, let value, _, let fontSize):
            return CGRect(origin: origin, size: AnnotationTextLayout.size(for: value, fontSize: fontSize))
        case .mosaic(let rect, _):
            return rect
        case .callout(let targetRect, let arrowStart, let arrowEnd, let textOrigin, let text, _, let lineWidth, let fontSize):
            let textSize = text.isEmpty
                ? emptyCalloutTextSize
                : AnnotationTextLayout.size(for: text, fontSize: fontSize)
            let arrowBounds = CGRect(
                x: min(arrowStart.x, arrowEnd.x),
                y: min(arrowStart.y, arrowEnd.y),
                width: abs(arrowEnd.x - arrowStart.x),
                height: abs(arrowEnd.y - arrowStart.y)
            ).insetBy(dx: -max(10, lineWidth * 2.2), dy: -max(10, lineWidth * 2.2))
            return targetRect
                .union(arrowBounds)
                .union(CGRect(origin: textOrigin, size: textSize))
        }
    }

    static func contains(
        _ point: CGPoint,
        annotation: Annotation,
        emptyCalloutTextSize: CGSize = CGSize(width: 150, height: 30)
    ) -> Bool {
        switch annotation {
        case .rectangle(let rect, _, let lineWidth, _):
            return rectangleBorderContains(point, rect: rect, lineWidth: lineWidth)
        case .ellipse(let rect, _, let lineWidth, _):
            return ellipseBorderContains(point, rect: rect, lineWidth: lineWidth)
        case .arrow(let start, let end, _, let lineWidth):
            return arrowContains(point, start: start, end: end, lineWidth: lineWidth)
        case .freehand(let points, _, let lineWidth),
             .highlighter(let points, _, let lineWidth):
            return AnnotationPathGeometry.contains(point, points: points, lineWidth: lineWidth)
        case .numberMarker(let center, _, _, let markerSize, _):
            return hypot(point.x - center.x, point.y - center.y) <= max(16, markerSize + 4)
        case .text(let origin, let value, _, let fontSize):
            let size = AnnotationTextLayout.size(for: value.isEmpty ? " " : value, fontSize: fontSize)
            return CGRect(origin: origin, size: size).insetBy(dx: -6, dy: -6).contains(point)
        case .mosaic(let rect, _):
            return rectangleBorderContains(point, rect: rect, lineWidth: 2)
        case .callout(
            let targetRect,
            let arrowStart,
            let arrowEnd,
            let textOrigin,
            let text,
            _,
            let lineWidth,
            let fontSize
        ):
            let textSize = text.isEmpty
                ? emptyCalloutTextSize
                : AnnotationTextLayout.size(for: text, fontSize: fontSize)
            return calloutHitRegion(
                at: point,
                targetRect: targetRect,
                arrowStart: arrowStart,
                arrowEnd: arrowEnd,
                textFrame: CGRect(origin: textOrigin, size: textSize),
                lineWidth: lineWidth
            ) != nil
        }
    }

    static func clampedTranslation(
        for visualBounds: CGRect,
        requested delta: CGPoint,
        within bounds: CGRect,
        margin: CGFloat = canvasMargin
    ) -> CGPoint {
        guard !visualBounds.isNull, !visualBounds.isInfinite else { return delta }
        let available = bounds.insetBy(dx: margin, dy: margin)
        var translated = visualBounds.offsetBy(dx: delta.x, dy: delta.y)
        var result = delta

        if translated.width <= available.width {
            if translated.minX < available.minX {
                result.x += available.minX - translated.minX
            } else if translated.maxX > available.maxX {
                result.x -= translated.maxX - available.maxX
            }
        }
        translated = visualBounds.offsetBy(dx: result.x, dy: result.y)
        if translated.height <= available.height {
            if translated.minY < available.minY {
                result.y += available.minY - translated.minY
            } else if translated.maxY > available.maxY {
                result.y -= translated.maxY - available.maxY
            }
        }
        return result
    }

    private static func rectangleBorderContains(
        _ point: CGPoint,
        rect: CGRect,
        lineWidth: CGFloat
    ) -> Bool {
        let tolerance = max(7, lineWidth / 2 + 4)
        let outer = rect.insetBy(dx: -tolerance, dy: -tolerance)
        guard outer.contains(point) else { return false }
        let inner = rect.insetBy(dx: tolerance, dy: tolerance)
        return inner.width <= 0 || inner.height <= 0 || !inner.contains(point)
    }

    private static func ellipseBorderContains(
        _ point: CGPoint,
        rect: CGRect,
        lineWidth: CGFloat
    ) -> Bool {
        let radiusX = rect.width / 2
        let radiusY = rect.height / 2
        guard radiusX > 0, radiusY > 0 else { return false }
        let normalizedX = (point.x - rect.midX) / radiusX
        let normalizedY = (point.y - rect.midY) / radiusY
        let normalizedDistance = normalizedX * normalizedX + normalizedY * normalizedY
        let tolerance = (max(7, lineWidth / 2 + 4)) / max(1, min(radiusX, radiusY))
        return abs(normalizedDistance - 1) <= tolerance
    }

    private static func arrowContains(
        _ point: CGPoint,
        start: CGPoint,
        end: CGPoint,
        lineWidth: CGFloat
    ) -> Bool {
        let shaftTolerance = max(7, lineWidth / 2 + 4)
        let headTolerance = max(10, lineWidth * 2.25)
        return distanceFromPoint(point, toLineFrom: start, to: end) <= shaftTolerance
            || hypot(point.x - start.x, point.y - start.y) <= max(10, lineWidth)
            || hypot(point.x - end.x, point.y - end.y) <= headTolerance
    }

    private static func distanceFromPoint(_ point: CGPoint, toLineFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let lengthSquared = pow(end.x - start.x, 2) + pow(end.y - start.y, 2)
        guard lengthSquared > 0 else {
            return hypot(point.x - start.x, point.y - start.y)
        }
        let projection = max(
            0,
            min(
                1,
                ((point.x - start.x) * (end.x - start.x)
                    + (point.y - start.y) * (end.y - start.y)) / lengthSquared
            )
        )
        let projectedPoint = CGPoint(
            x: start.x + projection * (end.x - start.x),
            y: start.y + projection * (end.y - start.y)
        )
        return hypot(point.x - projectedPoint.x, point.y - projectedPoint.y)
    }

    private static func clampOrigin(_ origin: CGPoint, size: CGSize, to bounds: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(origin.x, bounds.minX), max(bounds.minX, bounds.maxX - size.width)),
            y: min(max(origin.y, bounds.minY), max(bounds.minY, bounds.maxY - size.height))
        )
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }
}
