import XCTest
@testable import ShotMark

final class MosaicRendererTests: XCTestCase {
    func testStrengthProducesContinuousIncreasingObscuration() {
        let subtle = MosaicRenderer.parameters(for: 6)
        let standard = MosaicRenderer.parameters(for: 12)
        let strong = MosaicRenderer.parameters(for: 22)

        XCTAssertLessThan(subtle.blurRadiusPoints, standard.blurRadiusPoints)
        XCTAssertLessThan(standard.blurRadiusPoints, strong.blurRadiusPoints)
        XCTAssertLessThan(subtle.tintAlpha, standard.tintAlpha)
        XCTAssertLessThan(standard.tintAlpha, strong.tintAlpha)
        XCTAssertGreaterThan(subtle.saturation, standard.saturation)
        XCTAssertGreaterThan(standard.saturation, strong.saturation)
    }

    func testStrengthIsClampedToSupportedRange() {
        XCTAssertEqual(MosaicRenderer.parameters(for: -100), MosaicRenderer.parameters(for: 6))
        XCTAssertEqual(MosaicRenderer.parameters(for: 100), MosaicRenderer.parameters(for: 22))
    }

    func testDefaultStrengthKeepsTintSubtle() {
        let parameters = MosaicRenderer.parameters(for: 12)

        XCTAssertGreaterThanOrEqual(parameters.blurRadiusPoints, 16)
        XCTAssertLessThan(parameters.tintAlpha, 0.15)
    }
}
