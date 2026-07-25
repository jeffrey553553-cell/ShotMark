import AppKit
import XCTest
@testable import ShotMark

final class VideoRecordingServiceTests: XCTestCase {
    func testNativeOutputUsesScreenBackingScaleAndEvenDimensions() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let selection = CaptureSelection(
            rectInScreen: CGRect(x: 20, y: 30, width: 501.5, height: 300.5),
            screen: screen
        )

        let result = VideoRecordingService.nativeOutputPixelSize(for: selection)
        let expected = selection.nativePixelSize

        XCTAssertEqual(result, expected)
        XCTAssertEqual(Int(result.width) % 2, 0)
        XCTAssertEqual(Int(result.height) % 2, 0)
    }

    func testNativeOutputDoesNotApplyResolutionCap() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let selection = CaptureSelection(
            rectInScreen: CGRect(x: 0, y: 0, width: 2_400, height: 1_400),
            screen: screen
        )

        let result = VideoRecordingService.nativeOutputPixelSize(for: selection)

        XCTAssertGreaterThanOrEqual(result.width, 2_400)
        XCTAssertGreaterThanOrEqual(result.height, 1_400)
    }
}
