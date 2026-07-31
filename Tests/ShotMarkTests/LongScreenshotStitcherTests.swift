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
        XCTAssertEqual(stitcher.outputHeight, 480)
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
        XCTAssertEqual(update.outputHeight, 320)
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
        XCTAssertEqual(appendedDown.outputHeight, 320)
        XCTAssertEqual(appendedDown.acceptedFrameCount, 2)

        let covered = try XCTUnwrap(stitcher.append(
            coveredOnReturn,
            expectedDeltaPixels: 60,
            expectedDirection: .upward
        ))
        guard case .ignoredCoveredContent = covered.outcome else {
            return XCTFail("Expected covered content to be ignored, got \(covered.outcome)")
        }
        XCTAssertEqual(covered.outputHeight, 320)
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
        XCTAssertEqual(prepended.outputHeight, 380)
        XCTAssertEqual(prepended.acceptedFrameCount, 3)
    }

    func testHistoricalViewportRecoversAfterLargeReverseJump() throws {
        let stitcher = LongScreenshotStitcher()
        for (index, offset) in [200, 280, 360, 440].enumerated() {
            _ = try XCTUnwrap(stitcher.append(
                makeFrame(contentOffset: offset),
                expectedDeltaPixels: index == 0 ? nil : 80,
                expectedDirection: index == 0 ? nil : .downward
            ))
        }

        let recovered = try XCTUnwrap(stitcher.append(
            makeFrame(contentOffset: 200),
            expectedDeltaPixels: 240,
            expectedDirection: .upward
        ))
        guard case .ignoredCoveredContent = recovered.outcome else {
            return XCTFail("Expected a historical viewport recovery, got \(recovered.outcome)")
        }

        let prepended = try XCTUnwrap(stitcher.append(
            makeFrame(contentOffset: 120),
            expectedDeltaPixels: 80,
            expectedDirection: .upward
        ))
        guard case .appended(let deltaY) = prepended.outcome else {
            return XCTFail("Expected new content above to be prepended, got \(prepended.outcome)")
        }
        XCTAssertEqual(deltaY, 80)
        XCTAssertEqual(prepended.outputHeight, 560)
    }

    func testBidirectionalMergedPixelsContainEveryContentRowExactlyOnce() throws {
        let stitcher = LongScreenshotStitcher()
        _ = try XCTUnwrap(stitcher.append(makeFrame(contentOffset: 200)))
        _ = try XCTUnwrap(stitcher.append(
            makeFrame(contentOffset: 280),
            expectedDeltaPixels: 80,
            expectedDirection: .downward
        ))
        _ = try XCTUnwrap(stitcher.append(
            makeFrame(contentOffset: 140),
            expectedDeltaPixels: 140,
            expectedDirection: .upward
        ))

        let merged = try XCTUnwrap(stitcher.mergedImage())
        let contentOnly = try XCTUnwrap(merged.cropping(to: CGRect(
            x: 0,
            y: 20,
            width: merged.width,
            height: merged.height - 40
        )))
        let sampledRows = try decodedGlobalRows(in: contentOnly, sampleX: 90, searchRange: 0...800)

        XCTAssertEqual(sampledRows, Array(140...479))
    }

    func testFixedHeaderAndFooterArePreservedExactlyOnce() throws {
        let stitcher = LongScreenshotStitcher()
        _ = try XCTUnwrap(stitcher.append(makeFrame(contentOffset: 200)))
        _ = try XCTUnwrap(stitcher.append(
            makeFrame(contentOffset: 280),
            expectedDeltaPixels: 80,
            expectedDirection: .downward
        ))

        let merged = try XCTUnwrap(stitcher.mergedImage())
        XCTAssertEqual(merged.height, 320)
        XCTAssertEqual(try pixel(in: merged, x: 90, y: 5), [24, 30, 42])
        XCTAssertEqual(try pixel(in: merged, x: 90, y: 19), [24, 30, 42])
        XCTAssertEqual(try pixel(in: merged, x: 90, y: 20), contentColorArray(globalY: 200, x: 90))
        XCTAssertEqual(try pixel(in: merged, x: 90, y: 299), contentColorArray(globalY: 479, x: 90))
        XCTAssertEqual(try pixel(in: merged, x: 90, y: 300), [38, 44, 52])
        XCTAssertEqual(try pixel(in: merged, x: 90, y: 319), [38, 44, 52])
    }

    func testLargeRetinaFixedBarsRemainSingleAndDoNotBreakAlignment() throws {
        let stitcher = LongScreenshotStitcher()
        _ = try XCTUnwrap(stitcher.append(makeFrame(
            contentOffset: 400,
            headerHeight: 220,
            contentHeight: 600,
            footerHeight: 80
        )))
        let update = try XCTUnwrap(stitcher.append(
            makeFrame(
                contentOffset: 560,
                headerHeight: 220,
                contentHeight: 600,
                footerHeight: 80
            ),
            expectedDeltaPixels: 160,
            expectedDirection: .downward
        ))

        guard case .appended(let deltaY) = update.outcome else {
            return XCTFail("Expected large fixed bars to align, got \(update.outcome)")
        }
        XCTAssertEqual(deltaY, 160)
        XCTAssertEqual(update.outputHeight, 1_060)
        let merged = try XCTUnwrap(update.mergedImage)
        XCTAssertEqual(try pixel(in: merged, x: 90, y: 219), [24, 30, 42])
        XCTAssertEqual(try pixel(in: merged, x: 90, y: 220), contentColorArray(globalY: 400, x: 90))
        XCTAssertEqual(try pixel(in: merged, x: 90, y: 980), [38, 44, 52])
    }

    func testAnimatedSidePanelDoesNotCorruptLaneConsensus() throws {
        let stitcher = LongScreenshotStitcher()
        _ = try XCTUnwrap(stitcher.append(makeFrame(contentOffset: 200)))
        let update = try XCTUnwrap(stitcher.append(
            makeFrame(contentOffset: 280, animatedXRange: 0..<48),
            expectedDeltaPixels: 80,
            expectedDirection: .downward
        ))

        guard case .appended(let deltaY) = update.outcome else {
            return XCTFail("Expected stable lanes to align around animated sidebar, got \(update.outcome)")
        }
        XCTAssertEqual(deltaY, 80)
    }

    func testTranslucentFixedHeaderIsDetectedAndPreservedOnce() throws {
        let stitcher = LongScreenshotStitcher()
        _ = try XCTUnwrap(stitcher.append(makeFrame(
            contentOffset: 200,
            headerHeight: 64,
            translucentHeader: true
        )))
        let update = try XCTUnwrap(stitcher.append(
            makeFrame(
                contentOffset: 280,
                headerHeight: 64,
                translucentHeader: true
            ),
            expectedDeltaPixels: 80,
            expectedDirection: .downward
        ))

        guard case .appended(let deltaY) = update.outcome else {
            return XCTFail("Expected translucent fixed header to align, got \(update.outcome)")
        }
        XCTAssertEqual(deltaY, 80)
        XCTAssertEqual(update.outputHeight, 364)
        let merged = try XCTUnwrap(update.mergedImage)
        XCTAssertNotEqual(try pixel(in: merged, x: 90, y: 63), contentColorArray(globalY: 263, x: 90))
        XCTAssertEqual(try pixel(in: merged, x: 90, y: 64), contentColorArray(globalY: 200, x: 90))
    }

    func testLocalizedAnimatedBandDoesNotDiscardOtherwiseAlignedFrame() throws {
        let stitcher = LongScreenshotStitcher()
        _ = try XCTUnwrap(stitcher.append(makeFrame(contentOffset: 200)))

        let animated = try makeFrame(contentOffset: 280, animatedBand: 92..<124)
        let update = try XCTUnwrap(stitcher.append(
            animated,
            expectedDeltaPixels: 80,
            expectedDirection: .downward
        ))

        guard case .appended(let deltaY) = update.outcome else {
            return XCTFail("Expected robust matching around animated content, got \(update.outcome)")
        }
        XCTAssertEqual(deltaY, 80)
    }

    private func makeFrame(
        contentOffset: Int,
        animatedBand: Range<Int>? = nil,
        animatedXRange: Range<Int>? = nil,
        headerHeight: Int = 20,
        contentHeight: Int = 200,
        footerHeight: Int = 20,
        translucentHeader: Bool = false
    ) throws -> CGImage {
        let width = 180
        let height = headerHeight + contentHeight + footerHeight
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 255, count: height * bytesPerRow)

        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                let color: (UInt8, UInt8, UInt8)
                if y < headerHeight {
                    if translucentHeader {
                        let underlying = contentColor(globalY: contentOffset + y, x: x)
                        color = (
                            UInt8((Int(underlying.0) + 24 * 7) / 8),
                            UInt8((Int(underlying.1) + 30 * 7) / 8),
                            UInt8((Int(underlying.2) + 42 * 7) / 8)
                        )
                    } else {
                        color = (24, 30, 42)
                    }
                } else if y >= headerHeight + contentHeight {
                    color = (38, 44, 52)
                } else {
                    let globalY = contentOffset + y - headerHeight
                    if animatedBand?.contains(y) == true || animatedXRange?.contains(x) == true {
                        color = (
                            UInt8((x * 29 + y * 3) % 240),
                            UInt8((x * 5 + y * 31) % 240),
                            UInt8((x * 17 + y * 13) % 240)
                        )
                    } else {
                        color = contentColor(globalY: globalY, x: x)
                    }
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

    private func contentColor(globalY: Int, x: Int) -> (UInt8, UInt8, UInt8) {
        (
            UInt8((globalY * 17 + x * 3) % 220 + 20),
            UInt8((globalY * 7 + x * 11) % 210 + 25),
            UInt8((globalY * 13 + x * 5) % 200 + 30)
        )
    }

    private func contentColorArray(globalY: Int, x: Int) -> [UInt8] {
        let color = contentColor(globalY: globalY, x: x)
        return [color.0, color.1, color.2]
    }

    private func pixel(in image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let data = try XCTUnwrap(image.dataProvider?.data)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
        let offset = y * image.bytesPerRow + x * 4
        return [bytes[offset], bytes[offset + 1], bytes[offset + 2]]
    }

    private func decodedGlobalRows(
        in image: CGImage,
        sampleX: Int,
        searchRange: ClosedRange<Int>
    ) throws -> [Int] {
        let data = try XCTUnwrap(image.dataProvider?.data)
        let bytes = CFDataGetBytePtr(data)
        let bytesPerRow = image.bytesPerRow
        return try (0..<image.height).map { row in
            let offset = row * bytesPerRow + sampleX * 4
            let sampled = (bytes?[offset], bytes?[offset + 1], bytes?[offset + 2])
            return try XCTUnwrap(searchRange.first { globalY in
                let expected = contentColor(globalY: globalY, x: sampleX)
                return sampled.0 == expected.0
                    && sampled.1 == expected.1
                    && sampled.2 == expected.2
            })
        }
    }
}
