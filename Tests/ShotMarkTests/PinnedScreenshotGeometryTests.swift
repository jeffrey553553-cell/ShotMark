import XCTest
@testable import ShotMark

final class PinnedScreenshotGeometryTests: XCTestCase {
    private let visibleFrame = CGRect(x: 100, y: 80, width: 1_200, height: 800)

    func testInitialSizePreservesVeryWideAspectRatio() {
        let source = CGSize(width: 2_000, height: 80)
        let result = PinnedScreenshotGeometry.initialImageSize(
            pointSize: source,
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(result.width / result.height, source.width / source.height, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(
            result.width + PinnedScreenshotGeometry.shadowOutset * 2,
            visibleFrame.width * PinnedScreenshotGeometry.maximumScreenFraction + 0.001
        )
    }

    func testInitialSizePreservesVeryTallAspectRatio() {
        let source = CGSize(width: 60, height: 2_400)
        let result = PinnedScreenshotGeometry.initialImageSize(
            pointSize: source,
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(result.width / result.height, source.width / source.height, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(
            result.height + PinnedScreenshotGeometry.shadowOutset * 2,
            visibleFrame.height * PinnedScreenshotGeometry.maximumScreenFraction + 0.001
        )
    }

    func testSmallImageKeepsNativeSizeWithoutFakeUpscaling() {
        let source = CGSize(width: 24, height: 12)
        let result = PinnedScreenshotGeometry.initialImageSize(
            pointSize: source,
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(result.width, source.width, accuracy: 0.001)
        XCTAssertEqual(result.height, source.height, accuracy: 0.001)
        XCTAssertEqual(result.width / result.height, 2, accuracy: 0.001)
    }

    func testNarrowImageGetsInteractiveCanvasWithoutChangingImageRatio() {
        let imageSize = CGSize(width: 3, height: 120)
        let contentSize = PinnedScreenshotGeometry.contentSize(imageSize: imageSize)

        XCTAssertEqual(
            contentSize.width,
            PinnedScreenshotGeometry.minimumCanvasSize.width
                + PinnedScreenshotGeometry.shadowOutset * 2,
            accuracy: 0.001
        )
        XCTAssertEqual(
            contentSize.height,
            imageSize.height + PinnedScreenshotGeometry.shadowOutset * 2,
            accuracy: 0.001
        )
    }

    func testZoomIsClampedToSupportedRange() {
        XCTAssertEqual(
            PinnedScreenshotGeometry.clampedZoom(0.01),
            PinnedScreenshotGeometry.minimumZoom
        )
        XCTAssertEqual(
            PinnedScreenshotGeometry.clampedZoom(9),
            PinnedScreenshotGeometry.maximumZoom
        )
    }

    func testResizeKeepsAnchorStableWhenFrameFitsScreen() {
        let current = CGRect(x: 300, y: 250, width: 424, height: 224)
        let anchor = CGPoint(x: 406, y: 306)
        let oldRelative = CGPoint(
            x: (anchor.x - current.minX) / current.width,
            y: (anchor.y - current.minY) / current.height
        )
        let resized = PinnedScreenshotGeometry.resizedFrame(
            currentFrame: current,
            imageSize: CGSize(width: 600, height: 300),
            anchor: anchor,
            visibleFrame: visibleFrame
        )
        let newRelative = CGPoint(
            x: (anchor.x - resized.minX) / resized.width,
            y: (anchor.y - resized.minY) / resized.height
        )

        XCTAssertEqual(newRelative.x, oldRelative.x, accuracy: 0.001)
        XCTAssertEqual(newRelative.y, oldRelative.y, accuracy: 0.001)
    }

    func testInitialFrameIsClampedInsideVisibleScreen() {
        let frame = PinnedScreenshotGeometry.frame(
            for: CGSize(width: 500, height: 300),
            sourceRect: CGRect(x: 1_250, y: 760, width: 80, height: 80),
            visibleFrame: visibleFrame
        )
        let available = visibleFrame.insetBy(
            dx: PinnedScreenshotGeometry.screenMargin,
            dy: PinnedScreenshotGeometry.screenMargin
        )

        XCTAssertGreaterThanOrEqual(frame.minX, available.minX)
        XCTAssertGreaterThanOrEqual(frame.minY, available.minY)
        XCTAssertLessThanOrEqual(frame.maxX, available.maxX)
        XCTAssertLessThanOrEqual(frame.maxY, available.maxY)
    }
}
