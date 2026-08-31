import XCTest
@testable import ShotMark

final class LongScreenshotCapacityPolicyTests: XCTestCase {
    func testMaximumHeightShrinksForWideRetinaCaptures() {
        let narrow = LongScreenshotCapacityPolicy.maximumHeight(imageWidth: 1_440, minimumHeight: 900)
        let wide = LongScreenshotCapacityPolicy.maximumHeight(imageWidth: 5_120, minimumHeight: 2_880)

        XCTAssertEqual(narrow, 93_206)
        XCTAssertEqual(wide, 26_214)
        XCTAssertGreaterThan(narrow, wide)
    }

    func testMaximumHeightNeverDropsBelowInitialViewport() {
        XCTAssertEqual(
            LongScreenshotCapacityPolicy.maximumHeight(imageWidth: 100_000, minimumHeight: 3_000),
            3_000
        )
    }

    func testCapacityLevelsWarnBeforeStopping() {
        XCTAssertEqual(LongScreenshotCapacityPolicy.level(outputHeight: 7_999, maximumHeight: 10_000), .normal)
        XCTAssertEqual(LongScreenshotCapacityPolicy.level(outputHeight: 8_000, maximumHeight: 10_000), .warning)
        XCTAssertEqual(LongScreenshotCapacityPolicy.level(outputHeight: 10_000, maximumHeight: 10_000), .limit)
    }
}
