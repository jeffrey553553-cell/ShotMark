import XCTest
@testable import ShotMark

final class LongScreenshotCropGeometryTests: XCTestCase {
    func testScrollWheelDirectionMapsToScreenshotExpansion() {
        XCTAssertEqual(LongScreenshotScrollDirectionResolver.direction(forSign: -1), .downward)
        XCTAssertEqual(LongScreenshotScrollDirectionResolver.direction(forSign: 1), .upward)
        XCTAssertNil(LongScreenshotScrollDirectionResolver.direction(forSign: 0))
    }

    func testCropRectAppliesTopAndBottomWithoutChangingWidth() {
        XCTAssertEqual(
            LongScreenshotCropGeometry.cropRect(
                imageWidth: 1200,
                imageHeight: 4000,
                topPixels: 160,
                bottomPixels: 240
            ),
            CGRect(x: 0, y: 160, width: 1200, height: 3600)
        )
    }

    func testCropRectAlwaysLeavesAtLeastOnePixel() {
        XCTAssertEqual(
            LongScreenshotCropGeometry.cropRect(
                imageWidth: 800,
                imageHeight: 100,
                topPixels: 500,
                bottomPixels: 500
            ),
            CGRect(x: 0, y: 99, width: 800, height: 1)
        )
    }

    func testAppendingDownwardOnlyResetsBottomCrop() {
        XCTAssertEqual(
            LongScreenshotCropContinuationPolicy.adjustedInsets(
                LongScreenshotCropInsets(top: 80, bottom: 120),
                afterAppending: .downward
            ),
            LongScreenshotCropInsets(top: 80, bottom: 0)
        )
    }

    func testAppendingUpwardOnlyResetsTopCrop() {
        XCTAssertEqual(
            LongScreenshotCropContinuationPolicy.adjustedInsets(
                LongScreenshotCropInsets(top: 80, bottom: 120),
                afterAppending: .upward
            ),
            LongScreenshotCropInsets(top: 0, bottom: 120)
        )
    }

    func testUnresolvedAppendKeepsBothCropInsets() {
        XCTAssertEqual(
            LongScreenshotCropContinuationPolicy.adjustedInsets(
                LongScreenshotCropInsets(top: 80, bottom: 120),
                afterAppending: .unresolved
            ),
            LongScreenshotCropInsets(top: 80, bottom: 120)
        )
    }
}
