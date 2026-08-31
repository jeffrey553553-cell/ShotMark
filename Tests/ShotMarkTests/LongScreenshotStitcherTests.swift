import CoreGraphics
import ImageIO
import XCTest
@testable import ShotMark

final class LongScreenshotStitcherTests: XCTestCase {
    private struct BrowserBenchmarkManifest: Decodable {
        struct Frame: Decodable {
            let file: String
            let offset: Int
        }

        struct Marker: Decodable {
            let index: Int
            let color: [Int]
        }

        let scenario: String
        let scale: Int
        let documentHeight: Int
        let markerX: Int
        let floatingOverlayProbeX: Int?
        let markers: [Marker]
        let frames: [Frame]
    }

    func testRenderedBrowserBenchmarkCorpusWhenAvailable() throws {
        guard let rootPath = ProcessInfo.processInfo.environment["SHOTMARK_LONGSHOT_BENCHMARK_DIR"] else {
            throw XCTSkip("Rendered browser benchmark corpus is unavailable")
        }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let directories = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(directories.isEmpty)

        let requestedScenario = ProcessInfo.processInfo.environment["SHOTMARK_LONGSHOT_BENCHMARK_SCENARIO"]
        for directory in directories where requestedScenario == nil || directory.lastPathComponent == requestedScenario {
            let manifestURL = directory.appendingPathComponent("manifest.json")
            guard FileManager.default.fileExists(atPath: manifestURL.path) else { continue }
            let manifestData = try Data(contentsOf: manifestURL)
            let manifest = try JSONDecoder().decode(BrowserBenchmarkManifest.self, from: manifestData)
            let stitcher = LongScreenshotStitcher()
            var previousOffset: Int?
            var alignmentFailures = 0
            let maximumFrames = ProcessInfo.processInfo.environment["SHOTMARK_LONGSHOT_BENCHMARK_MAX_FRAMES"].flatMap(Int.init)

            for frame in manifest.frames.prefix(maximumFrames ?? manifest.frames.count) {
                let image = try loadImage(at: directory.appendingPathComponent(frame.file))
                let difference = previousOffset.map { frame.offset - $0 }
                let update = try XCTUnwrap(stitcher.append(
                    image,
                    expectedDeltaPixels: difference.map { abs($0) * manifest.scale },
                    expectedDirection: difference.flatMap {
                        guard $0 != 0 else { return nil }
                        return $0 > 0 ? .downward : .upward
                    },
                    renderMergedImage: false
                ), manifest.scenario)
                if case .ignoredAlignmentFailed = update.outcome {
                    alignmentFailures += 1
                }
                if ProcessInfo.processInfo.environment["SHOTMARK_LONGSHOT_BENCHMARK_DIAGNOSTICS"] == "1" {
                    print("BROWSER_BENCHMARK \(manifest.scenario) offset=\(frame.offset) outcome=\(update.outcome) height=\(update.outputHeight)")
                }
                previousOffset = frame.offset
            }

            if maximumFrames != nil {
                continue
            }

            XCTAssertEqual(alignmentFailures, 0, "\(manifest.scenario) had alignment failures")
            XCTAssertLessThanOrEqual(stitcher.retainedViewportAnchorCount, 64, manifest.scenario)
            let merged = try XCTUnwrap(stitcher.mergedImage(), manifest.scenario)
            let expectedHeight = manifest.documentHeight * manifest.scale
            XCTAssertLessThanOrEqual(
                abs(merged.height - expectedHeight),
                max(4, manifest.scale * 2),
                "\(manifest.scenario) output height \(merged.height), expected \(expectedHeight)"
            )
            try assertMarkersAppearOnceAndInOrder(
                manifest.markers,
                markerX: manifest.markerX * manifest.scale,
                in: merged,
                scenario: manifest.scenario
            )
            if let probeX = manifest.floatingOverlayProbeX {
                try assertFloatingOverlayAppearsOnce(
                    atX: probeX * manifest.scale,
                    in: merged,
                    scenario: manifest.scenario
                )
            }
            try writePNG(merged, to: directory.appendingPathComponent("merged.png"))
        }
    }

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
        XCTAssertEqual(stitcher.retainedContentPixelBytes, 440 * 180 * 4)
        XCTAssertLessThan(stitcher.retainedContentPixelBytes, 4 * 240 * 180 * 4)
    }

    func testCapacityLimitKeepsCurrentImageExportableAndStopsFurtherGrowth() throws {
        let stitcher = LongScreenshotStitcher()
        _ = try XCTUnwrap(stitcher.append(
            makeFrame(contentOffset: 200),
            maxOutputHeight: 600,
            renderMergedImage: false
        ))
        var finalAppend: LongScreenshotStitchUpdate?
        for offset in [280, 360, 440, 520, 600] {
            finalAppend = try XCTUnwrap(stitcher.append(
                makeFrame(contentOffset: offset),
                expectedDeltaPixels: 80,
                expectedDirection: .downward,
                renderMergedImage: false
            ))
            if finalAppend?.capacityLevel == .limit { break }
        }

        XCTAssertEqual(finalAppend?.outputHeight, 600)
        XCTAssertEqual(finalAppend?.capacityLevel, .limit)
        XCTAssertNotNil(stitcher.mergedImage())

        let stopped = try XCTUnwrap(stitcher.append(
            makeFrame(contentOffset: 680),
            expectedDeltaPixels: 80,
            expectedDirection: .downward,
            renderMergedImage: false
        ))
        guard case .reachedMaximumHeight = stopped.outcome else {
            return XCTFail("Expected an explicit capacity outcome, got \(stopped.outcome)")
        }
        XCTAssertEqual(stopped.outputHeight, 600)
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

    func testExactBroadMatchBeatsPlausibleFocusedMatch() throws {
        let stitcher = LongScreenshotStitcher()
        _ = try XCTUnwrap(stitcher.append(makeFrame(contentOffset: 200, contentHeight: 400)))

        let update = try XCTUnwrap(stitcher.append(
            makeFrame(contentOffset: 360, contentHeight: 400),
            expectedDeltaPixels: 80,
            expectedDirection: .downward
        ))

        guard case .appended(let deltaY) = update.outcome else {
            return XCTFail("Expected broad pixel search to recover, got \(update.outcome)")
        }
        XCTAssertEqual(deltaY, 160)
        XCTAssertEqual(update.outputHeight, 600)
    }

    func testLowGlobalDifferenceDoesNotHideReliableScrollingMotion() throws {
        let stitcher = LongScreenshotStitcher()
        _ = try XCTUnwrap(stitcher.append(makeFrame(
            contentOffset: 200,
            contentHeight: 440,
            width: 900,
            contentXRange: 320..<580
        )))

        let update = try XCTUnwrap(stitcher.append(
            makeFrame(
                contentOffset: 312,
                contentHeight: 440,
                width: 900,
                contentXRange: 320..<580
            ),
            expectedDeltaPixels: 112,
            expectedDirection: .downward
        ))

        guard case .appended(let deltaY) = update.outcome else {
            return XCTFail("Expected sparse scrolling content to append, got \(update.outcome)")
        }
        XCTAssertEqual(deltaY, 112)
    }

    func testHintedFastScrollCanUseShortExactOverlapAroundLargeFixedBars() throws {
        let stitcher = LongScreenshotStitcher()
        _ = try XCTUnwrap(stitcher.append(makeFrame(
            contentOffset: 200,
            headerHeight: 80,
            contentHeight: 300,
            footerHeight: 60
        )))

        let update = try XCTUnwrap(stitcher.append(
            makeFrame(
                contentOffset: 420,
                headerHeight: 80,
                contentHeight: 300,
                footerHeight: 60
            ),
            expectedDeltaPixels: 220,
            expectedDirection: .downward
        ))

        guard case .appended(let deltaY) = update.outcome else {
            return XCTFail("Expected a short exact overlap to append, got \(update.outcome)")
        }
        XCTAssertEqual(deltaY, 220)
    }

    func testSmallBoundaryScrollIsNotAveragedWithPreviousLargeCadence() throws {
        let stitcher = LongScreenshotStitcher()
        _ = try XCTUnwrap(stitcher.append(makeFrame(contentOffset: 200, contentHeight: 400)))
        _ = try XCTUnwrap(stitcher.append(
            makeFrame(contentOffset: 436, contentHeight: 400),
            expectedDeltaPixels: 236,
            expectedDirection: .downward
        ))

        let update = try XCTUnwrap(stitcher.append(
            makeFrame(contentOffset: 463, contentHeight: 400),
            expectedDeltaPixels: 27,
            expectedDirection: .downward
        ))

        guard case .appended(let deltaY) = update.outcome else {
            return XCTFail("Expected final boundary rows to append, got \(update.outcome)")
        }
        XCTAssertEqual(deltaY, 27)
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

    func testDirectionIsInferredWithoutScrollWheelHints() throws {
        let stitcher = LongScreenshotStitcher()
        _ = try XCTUnwrap(stitcher.append(makeFrame(contentOffset: 200)))

        let downward = try XCTUnwrap(stitcher.append(makeFrame(contentOffset: 280)))
        guard case .appended(let downwardDelta) = downward.outcome else {
            return XCTFail("Expected inferred downward append, got \(downward.outcome)")
        }
        XCTAssertEqual(downwardDelta, 80)

        let covered = try XCTUnwrap(stitcher.append(makeFrame(contentOffset: 200)))
        guard case .ignoredCoveredContent = covered.outcome else {
            return XCTFail("Expected inferred reverse traversal, got \(covered.outcome)")
        }

        let upward = try XCTUnwrap(stitcher.append(makeFrame(contentOffset: 120)))
        guard case .appended(let upwardDelta) = upward.outcome else {
            return XCTFail("Expected inferred upward append, got \(upward.outcome)")
        }
        XCTAssertEqual(upwardDelta, 80)
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

    func testWideStaticPageGuttersAreNotDetectedAsFixedBars() throws {
        let stitcher = LongScreenshotStitcher()
        _ = try XCTUnwrap(stitcher.append(makeFrame(
            contentOffset: 200,
            width: 600,
            contentXRange: 180..<420
        )))
        let update = try XCTUnwrap(stitcher.append(
            makeFrame(
                contentOffset: 280,
                width: 600,
                contentXRange: 180..<420
            ),
            expectedDeltaPixels: 80,
            expectedDirection: .downward
        ))

        guard case .appended(let deltaY) = update.outcome else {
            return XCTFail("Expected centered document to append, got \(update.outcome)")
        }
        XCTAssertEqual(deltaY, 80)
        XCTAssertEqual(update.outputHeight, 320)

        let merged = try XCTUnwrap(update.mergedImage)
        let contentOnly = try XCTUnwrap(merged.cropping(to: CGRect(
            x: 0,
            y: 20,
            width: merged.width,
            height: merged.height - 40
        )))
        XCTAssertEqual(
            try decodedGlobalRows(in: contentOnly, sampleX: 300, searchRange: 0...800),
            Array(200...479)
        )

        let duplicate = try XCTUnwrap(stitcher.append(makeFrame(
            contentOffset: 280,
            width: 600,
            contentXRange: 180..<420
        )))
        guard case .ignoredNoMovement = duplicate.outcome else {
            return XCTFail("Expected a stable wide-page frame to be ignored, got \(duplicate.outcome)")
        }
        XCTAssertEqual(duplicate.outputHeight, 320)
    }

    private func loadImage(at url: URL) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), url.path)
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), url.path)
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL,
            "public.png" as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination), url.path)
    }

    private func assertMarkersAppearOnceAndInOrder(
        _ markers: [BrowserBenchmarkManifest.Marker],
        markerX: Int,
        in image: CGImage,
        scenario: String
    ) throws {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let x = min(max(0, markerX), width - 1)
        let minimumRun = 4
        var runs: [(index: Int, length: Int)] = []
        var activeIndex: Int?
        var activeLength = 0

        func finishRun() {
            if let activeIndex, activeLength >= minimumRun {
                runs.append((activeIndex, activeLength))
            }
            activeIndex = nil
            activeLength = 0
        }

        for y in 0..<height {
            let offset = y * bytesPerRow + x * 4
            let rgb = [Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2])]
            let matched = markers.first { marker in
                marker.color.count == 3
                    && zip(marker.color, rgb).reduce(0) { $0 + abs($1.0 - $1.1) } <= 3
            }?.index
            if matched == activeIndex, matched != nil {
                activeLength += 1
            } else {
                finishRun()
                activeIndex = matched
                activeLength = matched == nil ? 0 : 1
            }
        }
        finishRun()

        let sequence = runs.map(\.index)
        let expected = markers.map(\.index)
        XCTAssertEqual(sequence, expected, "\(scenario) marker sequence was \(sequence)")
        for marker in expected {
            XCTAssertEqual(sequence.filter { $0 == marker }.count, 1, "\(scenario) repeated or lost marker \(marker)")
        }
    }

    private func assertFloatingOverlayAppearsOnce(atX x: Int, in image: CGImage, scenario: String) throws {
        let data = try XCTUnwrap(image.dataProvider?.data)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
        let sampleX = min(max(0, x), image.width - 1)
        var runs: [ClosedRange<Int>] = []
        var activeLength = 0
        var activeStart = 0
        var currentRow = 0

        func finishRun() {
            if activeLength >= 8 {
                runs.append(activeStart...(currentRow - 1))
            }
            activeLength = 0
        }

        for row in 0..<image.height {
            currentRow = row
            let offset = row * image.bytesPerRow + sampleX * 4
            let red = Int(bytes[offset])
            let green = Int(bytes[offset + 1])
            let blue = Int(bytes[offset + 2])
            let isOverlayColor = (red > 110 && red > green + 35 && red > blue + 15)
                || (blue > 115 && blue > green + 25 && blue > red + 10)
            if isOverlayColor {
                if activeLength == 0 {
                    activeStart = row
                }
                activeLength += 1
            } else {
                finishRun()
            }
        }
        currentRow = image.height
        finishRun()
        var clusters: [ClosedRange<Int>] = []
        for run in runs {
            if let last = clusters.last, run.lowerBound - last.upperBound <= 48 {
                clusters[clusters.count - 1] = last.lowerBound...run.upperBound
            } else {
                clusters.append(run)
            }
        }
        XCTAssertEqual(clusters.count, 1, "\(scenario) fixed floating overlay clusters were \(clusters)")
    }

    private func makeFrame(
        contentOffset: Int,
        animatedBand: Range<Int>? = nil,
        animatedXRange: Range<Int>? = nil,
        headerHeight: Int = 20,
        contentHeight: Int = 200,
        footerHeight: Int = 20,
        translucentHeader: Bool = false,
        width: Int = 180,
        contentXRange: Range<Int>? = nil
    ) throws -> CGImage {
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
                    if let contentXRange, !contentXRange.contains(x) {
                        color = (247, 247, 247)
                    } else if animatedBand?.contains(y) == true || animatedXRange?.contains(x) == true {
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
