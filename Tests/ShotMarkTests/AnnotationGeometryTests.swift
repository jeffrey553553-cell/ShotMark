import AppKit
import XCTest
@testable import ShotMark

final class AnnotationGeometryTests: XCTestCase {
    func testNearestPointForInteriorDragAlwaysSnapsToRectangleBorder() {
        let rect = CGRect(x: 100, y: 80, width: 200, height: 120)
        let point = AnnotationGeometry.nearestPointOnBorder(
            of: rect,
            to: CGPoint(x: 140, y: 130)
        )

        XCTAssertEqual(point.x, rect.minX, accuracy: 0.001)
        XCTAssertEqual(point.y, 130, accuracy: 0.001)
        XCTAssertTrue(isOnBorder(point, of: rect))
    }

    func testCalloutLayoutKeepsTextVisibleAndArrowAttached() {
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 620)
        let target = CGRect(x: 330, y: 240, width: 180, height: 100)
        let textSize = CGSize(width: 180, height: 42)
        let layout = AnnotationGeometry.calloutLayout(
            for: target,
            in: bounds,
            textSize: textSize
        )
        let textFrame = CGRect(origin: layout.textOrigin, size: textSize)

        XCTAssertTrue(bounds.insetBy(dx: 8, dy: 8).contains(textFrame))
        XCTAssertFalse(textFrame.intersects(target))
        XCTAssertTrue(isOnBorder(layout.arrowEnd, of: target))
        XCTAssertGreaterThan(abs(layout.arrowEnd.x - layout.arrowStart.x), 20)
        XCTAssertGreaterThan(abs(layout.arrowEnd.y - layout.arrowStart.y), 20)
        XCTAssertGreaterThan(
            hypot(
                layout.arrowEnd.x - layout.arrowStart.x,
                layout.arrowEnd.y - layout.arrowStart.y
            ),
            30
        )
    }

    func testCalloutNearCornerChoosesAnotherAvailableSide() {
        let bounds = CGRect(x: 0, y: 0, width: 720, height: 480)
        let target = CGRect(x: 580, y: 370, width: 110, height: 80)
        let textSize = CGSize(width: 180, height: 42)
        let layout = AnnotationGeometry.calloutLayout(
            for: target,
            in: bounds,
            textSize: textSize
        )
        let textFrame = CGRect(origin: layout.textOrigin, size: textSize)

        XCTAssertTrue(bounds.insetBy(dx: 8, dy: 8).contains(textFrame))
        XCTAssertFalse(textFrame.intersects(target))
        XCTAssertTrue(isOnBorder(layout.arrowEnd, of: target))
    }

    func testTranslationStopsAnnotationAtCanvasEdge() {
        let visualBounds = CGRect(x: 60, y: 60, width: 30, height: 30)
        let delta = AnnotationGeometry.clampedTranslation(
            for: visualBounds,
            requested: CGPoint(x: 50, y: 50),
            within: CGRect(x: 0, y: 0, width: 100, height: 100)
        )

        XCTAssertEqual(delta.x, 8, accuracy: 0.001)
        XCTAssertEqual(delta.y, 8, accuracy: 0.001)
        let translated = visualBounds.offsetBy(dx: delta.x, dy: delta.y)
        XCTAssertTrue(CGRect(x: 2, y: 2, width: 96, height: 96).contains(translated))
    }

    func testTextEditorExpandsLeftWhenItReachesSelectionEdge() {
        let frame = AnnotationGeometry.fittedHorizontalEditorFrame(
            preferredMinX: 470,
            desiredWidth: 220,
            minimumWidth: 96,
            in: CGRect(x: 100, y: 80, width: 500, height: 300)
        )

        XCTAssertEqual(frame.width, 220, accuracy: 0.001)
        XCTAssertEqual(frame.minX, 378, accuracy: 0.001)
        XCTAssertEqual(frame.minX + frame.width, 598, accuracy: 0.001)
    }

    func testTextEditorNeverExceedsNarrowSelection() {
        let frame = AnnotationGeometry.fittedHorizontalEditorFrame(
            preferredMinX: 135,
            desiredWidth: 260,
            minimumWidth: 96,
            in: CGRect(x: 100, y: 40, width: 80, height: 200)
        )

        XCTAssertEqual(frame.minX, 102, accuracy: 0.001)
        XCTAssertEqual(frame.width, 76, accuracy: 0.001)
    }

    func testCalloutVisualBoundsIncludeTargetArrowAndMultilineText() {
        let annotation = Annotation.callout(
            targetRect: CGRect(x: 30, y: 40, width: 120, height: 80),
            arrowStart: CGPoint(x: 230, y: 180),
            arrowEnd: CGPoint(x: 150, y: 120),
            textOrigin: CGPoint(x: 250, y: 170),
            text: "第一行\nSecond line",
            color: .systemRed,
            lineWidth: 4,
            fontSize: 18
        )
        let bounds = AnnotationGeometry.visualBounds(of: annotation)

        XCTAssertLessThanOrEqual(bounds.minX, 30)
        XCTAssertLessThanOrEqual(bounds.minY, 40)
        XCTAssertGreaterThan(bounds.maxX, 250)
        XCTAssertGreaterThan(bounds.maxY, 190)
    }

    private func isOnBorder(_ point: CGPoint, of rect: CGRect) -> Bool {
        let onVertical = abs(point.x - rect.minX) < 0.001 || abs(point.x - rect.maxX) < 0.001
        let onHorizontal = abs(point.y - rect.minY) < 0.001 || abs(point.y - rect.maxY) < 0.001
        return rect.insetBy(dx: -0.001, dy: -0.001).contains(point)
            && (onVertical || onHorizontal)
    }
}
