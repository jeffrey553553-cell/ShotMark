import XCTest
@testable import ShotMark

final class LongScreenshotAxisTests: XCTestCase {
    func testFirstStrongHorizontalGestureSelectsHorizontalAxis() {
        XCTAssertEqual(
            LongScreenshotScrollMotionResolver.resolve(
                horizontalDelta: -12,
                verticalDelta: 2,
                lockedAxis: .undetermined
            ),
            LongScreenshotScrollMotion(axis: .horizontal, delta: -12)
        )
    }

    func testAmbiguousDiagonalGestureKeepsVerticalDefault() {
        XCTAssertEqual(
            LongScreenshotScrollMotionResolver.resolve(
                horizontalDelta: 8,
                verticalDelta: 7,
                lockedAxis: .undetermined
            ),
            LongScreenshotScrollMotion(axis: .vertical, delta: 7)
        )
    }

    func testLockedAxisIgnoresPerpendicularMotion() {
        XCTAssertNil(LongScreenshotScrollMotionResolver.resolve(
            horizontalDelta: 0,
            verticalDelta: 18,
            lockedAxis: .horizontal
        ))
        XCTAssertNil(LongScreenshotScrollMotionResolver.resolve(
            horizontalDelta: 18,
            verticalDelta: 0,
            lockedAxis: .vertical
        ))
    }

    func testAxisCannotChangeAfterItHasBeenLocked() throws {
        let stitcher = LongScreenshotStitcher()
        _ = try XCTUnwrap(stitcher.append(makeFrame(contentOffset: 200)))
        XCTAssertTrue(stitcher.configureAxis(.vertical))

        XCTAssertFalse(stitcher.configureAxis(.horizontal))
        XCTAssertEqual(stitcher.axis, .vertical)
        XCTAssertEqual(stitcher.acceptedFrameCount, 1)
    }

    private func makeFrame(contentOffset: Int) -> CGImage {
        let width = 120
        let height = 100
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 255, count: bytesPerRow * height)
        for y in 0..<height {
            let value = UInt8((contentOffset + y) % 251)
            for x in 0..<width {
                let index = y * bytesPerRow + x * 4
                pixels[index] = value
                pixels[index + 1] = UInt8((x * 3) % 251)
                pixels[index + 2] = UInt8((contentOffset + y + x) % 251)
                pixels[index + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }
}
