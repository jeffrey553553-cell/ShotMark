import XCTest
@testable import ShotMark

final class CaptureDelayPresetTests: XCTestCase {
    func testCommercialTimerPresetsAreShortAndPredictable() {
        XCTAssertEqual(CaptureDelayPreset.allCases.map(\.rawValue), [3, 5, 10])
        XCTAssertEqual(CaptureDelayPreset.allCases.map(\.title), ["3 秒", "5 秒", "10 秒"])
    }
}
