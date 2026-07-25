import CoreGraphics
import XCTest
@testable import ShotMark

final class LongScreenshotStitcherTests: XCTestCase {
    func testContinuousDownwardCaptureAppendsOnlyNewRows() throws {
        let stitcher = LongScreenshotStitcher()
        let offsets = [200, 280, 360, 440]

        for (index, offset) in offsets.enumerated() {
            let update = try XCTUnwrap(stitcher.append(
                makeFrame(contentOffset: offset),
                expectedDeltaPixels: index == 0 ? nil : 80,
                expectedDirection: index == 0 ? nil : .downward
            ))
            if index > 0 {
                guard case .appended(let deltaY) = update.outcome else {
                    return XCTFail("Expected frame \(index) to append, got \(update.outcome)")
                }
                XCTAssertEqual(deltaY, 80)
            }
        }

        XCTAssertEqual(stitcher.acceptedFrameCount, 4)
        XCTAssertEqual(stitcher.outputHeight, 440)
    }

    func testVisionRecoveryHandlesMisleadingScrollDistance() throws {
        let stitcher = LongScreenshotStitcher()
        _ = try XCTUnwrap(stitcher.append(makeFrame(contentOffset: 200)))

        let update = try XCTUnwrap(stitcher.append(
            makeFrame(contentOffset: 280),
            expectedDeltaPixels: 18,
            expectedDirection: .downward
        ))

        guard case .appended(let deltaY) = update.outcome else {
            return XCTFail("Expected Vision-assisted recovery, got \(update.outcome)")
        }
        XCTAssertEqual(deltaY, 80)
        XCTAssertEqual(update.outputHeight, 280)
    }

    func testIdenticalFrameDoesNotGrowOutput() throws {
        let stitcher = LongScreenshotStitcher()
        let frame = try makeFrame(contentOffset: 200)
        _ = try XCTUnwrap(stitcher.append(frame))
        let duplicate = try XCTUnwrap(stitcher.append(
            frame,
            expectedDeltaPixels: 60,
            expectedDirection: .downward
        ))

        guard case .ignoredNoMovement = duplicate.outcome else {
            return XCTFail("Expected duplicate frame to be ignored, got \(duplicate.outcome)")
        }
        XCTAssertEqual(duplicate.acceptedFrameCount, 1)
        XCTAssertEqual(duplicate.outputHeight, 240)
    }

    func testReverseScrollingDoesNotDuplicateCoveredContent() throws {
        let stitcher = LongScreenshotStitcher()

        let initial = try makeFrame(contentOffset: 200)
        let downward = try makeFrame(contentOffset: 280)
        let coveredOnReturn = try makeFrame(contentOffset: 220)
        let newContentAbove = try makeFrame(contentOffset: 140)

        let initialized = try XCTUnwrap(stitcher.append(initial))
        XCTAssertEqual(initialized.outputHeight, 240)

        let appendedDown = try XCTUnwrap(stitcher.append(
            downward,
            expectedDeltaPixels: 80,
            expectedDirection: .downward
        ))
        XCTAssertEqual(appendedDown.outputHeight, 280)
        XCTAssertEqual(appendedDown.acceptedFrameCount, 2)

        let covered = try XCTUnwrap(stitcher.append(
            coveredOnReturn,
            expectedDeltaPixels: 60,
            expectedDirection: .upward
        ))
        guard case .ignoredCoveredContent = covered.outcome else {
            return XCTFail("Expected covered content to be ignored, got \(covered.outcome)")
        }
        XCTAssertEqual(covered.outputHeight, 280)
        XCTAssertEqual(covered.acceptedFrameCount, 2)

        let prepended = try XCTUnwrap(stitcher.append(
            newContentAbove,
            expectedDeltaPixels: 80,
            expectedDirection: .upward
        ))
        guard case .appended(let deltaY) = prepended.outcome else {
            return XCTFail("Expected new upper content to be prepended, got \(prepended.outcome)")
        }
        XCTAssertEqual(deltaY, 60)
        XCTAssertEqual(prepended.outputHeight, 340)
        XCTAssertEqual(prepended.acceptedFrameCount, 3)
    }

    private func makeFrame(contentOffset: Int) throws -> CGImage {
        let width = 180
        let headerHeight = 20
        let contentHeight = 200
        let footerHeight = 20
        let height = headerHeight + contentHeight + footerHeight
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 255, count: height * bytesPerRow)

        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                let color: (UInt8, UInt8, UInt8)
                if y < headerHeight {
                    color = (24, 30, 42)
                } else if y >= headerHeight + contentHeight {
                    color = (38, 44, 52)
                } else {
                    let globalY = contentOffset + y - headerHeight
                    color = (
                        UInt8((globalY * 17 + x * 3) % 220 + 20),
                        UInt8((globalY * 7 + x * 11) % 210 + 25),
                        UInt8((globalY * 13 + x * 5) % 200 + 30)
                    )
                }
                pixels[offset] = color.0
                pixels[offset + 1] = color.1
                pixels[offset + 2] = color.2
                pixels[offset + 3] = 255
            }
        }

        let data = Data(pixels) as CFData
        let provider = try XCTUnwrap(CGDataProvider(data: data))
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        return try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }
}
