import CoreGraphics
import AppKit
import XCTest
@testable import ShotMark

final class SelectionPrecisionSupportTests: XCTestCase {
    func testPixelStepUsesPhysicalPixelsOnRetina() {
        XCTAssertEqual(SelectionPrecisionGeometry.pixelStep(for: 1), 1)
        XCTAssertEqual(SelectionPrecisionGeometry.pixelStep(for: 2), 0.5)
        XCTAssertEqual(SelectionPrecisionGeometry.pixelStep(for: 0), 1)
    }

    func testMovingSelectionStopsAtEveryBoundary() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 80)
        let rect = CGRect(x: 2, y: 3, width: 30, height: 20)

        XCTAssertEqual(
            SelectionPrecisionGeometry.moved(rect, direction: .left, distance: 10, inside: bounds).minX,
            0
        )
        XCTAssertEqual(
            SelectionPrecisionGeometry.moved(rect, direction: .down, distance: 10, inside: bounds).minY,
            0
        )
        XCTAssertEqual(
            SelectionPrecisionGeometry.moved(rect, direction: .right, distance: 100, inside: bounds).maxX,
            bounds.maxX
        )
        XCTAssertEqual(
            SelectionPrecisionGeometry.moved(rect, direction: .up, distance: 100, inside: bounds).maxY,
            bounds.maxY
        )
    }

    func testResizingSelectionHonorsMinimumAndScreenBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 80)
        let rect = CGRect(x: 70, y: 55, width: 25, height: 20)

        let shrunken = SelectionPrecisionGeometry.resized(
            rect,
            direction: .left,
            distance: 100,
            minimumSize: 8,
            inside: bounds
        )
        XCTAssertEqual(shrunken.width, 8)

        let expandedRight = SelectionPrecisionGeometry.resized(
            rect,
            direction: .right,
            distance: 100,
            minimumSize: 8,
            inside: bounds
        )
        XCTAssertEqual(expandedRight.maxX, bounds.maxX)

        let expandedUp = SelectionPrecisionGeometry.resized(
            rect,
            direction: .up,
            distance: 100,
            minimumSize: 8,
            inside: bounds
        )
        XCTAssertEqual(expandedUp.maxY, bounds.maxY)
    }

    func testMagnifierFlipsInsideTopRightCorner() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let frame = SelectionMagnifierLayout.frame(
            cursor: CGPoint(x: 790, y: 590),
            inside: bounds
        )

        XCTAssertLessThan(frame.maxX, bounds.maxX)
        XCTAssertLessThan(frame.maxY, bounds.maxY)
        XCTAssertLessThan(frame.midX, 790)
        XCTAssertLessThan(frame.midY, 590)
    }

    func testMagnifierCropMapsRetinaCoordinatesAndStaysInsideImage() {
        let crop = SelectionMagnifierLayout.cropRect(
            cursor: CGPoint(x: 100, y: 50),
            viewBounds: CGRect(x: 0, y: 0, width: 200, height: 100),
            imageSize: CGSize(width: 400, height: 200),
            zoom: 8
        )

        XCTAssertEqual(crop.midX, 200, accuracy: 1)
        XCTAssertEqual(crop.midY, 99, accuracy: 1)
        XCTAssertGreaterThanOrEqual(crop.minX, 0)
        XCTAssertGreaterThanOrEqual(crop.minY, 0)
        XCTAssertLessThanOrEqual(crop.maxX, 400)
        XCTAssertLessThanOrEqual(crop.maxY, 200)
    }

    func testMagnifierZoomClampsToSupportedRange() {
        let magnifier = SelectionMagnifier()
        for _ in 0..<100 {
            magnifier.adjustZoom(scrollDelta: 1, hasPreciseDeltas: false)
        }
        XCTAssertEqual(magnifier.zoom, 16)

        for _ in 0..<100 {
            magnifier.adjustZoom(scrollDelta: -1, hasPreciseDeltas: false)
        }
        XCTAssertEqual(magnifier.zoom, 4)
    }

    func testMagnifierRendersIntoBitmapContext() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let source = try makeSolidImage(width: 800, height: 600, color: NSColor.systemBlue)
        let snapshot = ScreenSnapshot(
            image: source,
            screen: screen,
            screenScale: 1,
            createdAt: Date()
        )
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 800,
            pixelsHigh: 600,
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
        SelectionMagnifier().draw(
            at: CGPoint(x: 300, y: 240),
            in: CGRect(x: 0, y: 0, width: 800, height: 600),
            snapshot: snapshot,
            avoiding: []
        )
        NSGraphicsContext.restoreGraphicsState()

        let frame = SelectionMagnifierLayout.frame(
            cursor: CGPoint(x: 300, y: 240),
            inside: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
        let sampled = try XCTUnwrap(bitmap.colorAt(
            x: Int(frame.midX),
            y: Int(frame.midY)
        ))
        XCTAssertGreaterThan(sampled.alphaComponent, 0.8)

        if let outputPath = ProcessInfo.processInfo.environment["SHOTMARK_RENDER_TEST_OUTPUT"] {
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        }
    }

    private func makeSolidImage(width: Int, height: Int, color: NSColor) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }
}
