import AppKit
import XCTest
@testable import ShotMark

final class AnnotationPathGeometryTests: XCTestCase {
    func testSmoothedPathStartsAndEndsAtInputEndpoints() {
        let points = [
            CGPoint(x: 10, y: 20),
            CGPoint(x: 30, y: 40),
            CGPoint(x: 60, y: 25),
            CGPoint(x: 90, y: 50)
        ]

        let path = AnnotationPathGeometry.smoothPath(points: points)

        XCTAssertEqual(path.currentPoint, points.last)
        XCTAssertTrue(path.boundingBoxOfPath.insetBy(dx: -1, dy: -1).contains(points[0]))
        XCTAssertTrue(path.boundingBoxOfPath.insetBy(dx: -1, dy: -1).contains(points[3]))
    }

    func testPathHitTestingUsesStrokeInsteadOfBoundingBox() {
        let points = [
            CGPoint(x: 10, y: 10),
            CGPoint(x: 50, y: 50),
            CGPoint(x: 90, y: 10)
        ]

        XCTAssertTrue(
            AnnotationPathGeometry.contains(
                CGPoint(x: 50, y: 48),
                points: points,
                lineWidth: 4
            )
        )
        XCTAssertFalse(
            AnnotationPathGeometry.contains(
                CGPoint(x: 50, y: 10),
                points: points,
                lineWidth: 4,
                tolerance: 2
            )
        )
    }

    func testTranslatedPathPreservesShape() {
        let points = [CGPoint(x: 1, y: 2), CGPoint(x: 8, y: 12)]
        let translated = AnnotationPathGeometry.translated(
            points,
            by: CGPoint(x: 20, y: -4)
        )

        XCTAssertEqual(translated, [CGPoint(x: 21, y: -2), CGPoint(x: 28, y: 8)])
    }

    func testHighlighterOverlapDoesNotCompoundAlphaWithinOneStroke() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 100,
            pixelsHigh: 50,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        NSColor.clear.setFill()
        CGRect(x: 0, y: 0, width: 100, height: 50).fill()
        AnnotationDrawing.draw(
            [
                .highlighter(
                    points: [
                        CGPoint(x: 10, y: 25),
                        CGPoint(x: 90, y: 25),
                        CGPoint(x: 10, y: 25),
                        CGPoint(x: 90, y: 25)
                    ],
                    color: NSColor.systemYellow.withAlphaComponent(0.35),
                    lineWidth: 14
                )
            ],
            in: CGSize(width: 100, height: 50)
        )
        NSGraphicsContext.restoreGraphicsState()

        let first = try XCTUnwrap(bitmap.colorAt(x: 25, y: 25))
        let overlap = try XCTUnwrap(bitmap.colorAt(x: 50, y: 25))
        XCTAssertEqual(first.alphaComponent, overlap.alphaComponent, accuracy: 0.04)
        XCTAssertEqual(overlap.alphaComponent, 0.35, accuracy: 0.08)
    }

    func testSquareConstraintPreservesDragDirection() {
        XCTAssertEqual(
            AnnotationConstraintGeometry.squareEndpoint(
                from: CGPoint(x: 50, y: 50),
                to: CGPoint(x: 20, y: 70)
            ),
            CGPoint(x: 20, y: 80)
        )
        XCTAssertEqual(
            AnnotationConstraintGeometry.squareEndpoint(
                from: CGPoint(x: 10, y: 10),
                to: CGPoint(x: 30, y: -25)
            ),
            CGPoint(x: 45, y: -25)
        )
    }

    func testLineConstraintSnapsToNearestFortyFiveDegrees() {
        let horizontal = AnnotationConstraintGeometry.snappedLineEndpoint(
            from: .zero,
            to: CGPoint(x: 100, y: 12)
        )
        XCTAssertEqual(horizontal.y, 0, accuracy: 0.001)
        XCTAssertEqual(hypot(horizontal.x, horizontal.y), hypot(100, 12), accuracy: 0.001)

        let diagonal = AnnotationConstraintGeometry.snappedLineEndpoint(
            from: .zero,
            to: CGPoint(x: 80, y: 70)
        )
        XCTAssertEqual(diagonal.x, diagonal.y, accuracy: 0.001)
    }
}
