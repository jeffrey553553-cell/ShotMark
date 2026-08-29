import CoreGraphics
import XCTest
@testable import ShotMark

final class LongScreenshotFrameRingTests: XCTestCase {
    func testFrameMailboxCoalescesBacklogToLatestFrame() {
        let mailbox = LongScreenshotFrameMailbox()
        let first = makeFrame(sequenceNumber: 1, gray: 10)
        let second = makeFrame(sequenceNumber: 2, gray: 20)

        XCTAssertTrue(mailbox.enqueue(first))
        XCTAssertFalse(mailbox.enqueue(second))
        XCTAssertEqual(mailbox.takeLatest()?.sequenceNumber, 2)
        XCTAssertFalse(mailbox.completeDelivery())
    }

    func testFrameMailboxSchedulesLatestFrameThatArrivesDuringDelivery() {
        let mailbox = LongScreenshotFrameMailbox()
        let first = makeFrame(sequenceNumber: 1, gray: 10)
        let second = makeFrame(sequenceNumber: 2, gray: 20)

        XCTAssertTrue(mailbox.enqueue(first))
        XCTAssertEqual(mailbox.takeLatest()?.sequenceNumber, 1)
        XCTAssertFalse(mailbox.enqueue(second))
        XCTAssertTrue(mailbox.completeDelivery())
        XCTAssertEqual(mailbox.takeLatest()?.sequenceNumber, 2)
        XCTAssertFalse(mailbox.completeDelivery())
    }

    func testSettledFrameRequiresThreeSimilarNewFrames() throws {
        let ring = LongScreenshotFrameRing()
        ring.append(LongScreenshotFrame(sequenceNumber: 1, image: try image(gray: 20), capturedAt: Date()))
        ring.markCommitted(sequenceNumber: 1)
        ring.append(LongScreenshotFrame(sequenceNumber: 2, image: try image(gray: 180), capturedAt: Date()))
        XCTAssertNil(ring.latestSettledFrame(after: ring.lastCommittedSequenceNumber))

        ring.append(LongScreenshotFrame(sequenceNumber: 3, image: try image(gray: 181), capturedAt: Date()))
        XCTAssertNil(ring.latestSettledFrame(after: ring.lastCommittedSequenceNumber))

        ring.append(LongScreenshotFrame(sequenceNumber: 4, image: try image(gray: 181), capturedAt: Date()))
        XCTAssertEqual(ring.latestSettledFrame(after: ring.lastCommittedSequenceNumber)?.sequenceNumber, 4)
    }

    func testMovingFramesAreNotReportedAsSettled() throws {
        let ring = LongScreenshotFrameRing()
        ring.append(LongScreenshotFrame(sequenceNumber: 1, image: try image(gray: 10), capturedAt: Date()))
        ring.markCommitted(sequenceNumber: 1)
        ring.append(LongScreenshotFrame(sequenceNumber: 2, image: try image(gray: 80), capturedAt: Date()))
        ring.append(LongScreenshotFrame(sequenceNumber: 3, image: try image(gray: 160), capturedAt: Date()))

        XCTAssertNil(ring.latestSettledFrame(after: ring.lastCommittedSequenceNumber))
        XCTAssertEqual(ring.latestFrame(after: ring.lastCommittedSequenceNumber)?.sequenceNumber, 3)
    }

    func testSampledDifferenceSeparatesMotionFromStableFrames() throws {
        let stableA = try image(gray: 80)
        let stableB = try image(gray: 81)
        let moved = try image(gray: 150)

        XCTAssertLessThan(LongScreenshotFrameRing.sampledDifference(stableA, stableB), 1.8)
        XCTAssertGreaterThan(LongScreenshotFrameRing.sampledDifference(stableA, moved), 1.8)
    }

    func testSettledFramePrefersSharperCandidateInsteadOfBlindlyUsingLatest() throws {
        let ring = LongScreenshotFrameRing()
        ring.append(LongScreenshotFrame(sequenceNumber: 1, image: try stripedImage(contrast: 220), capturedAt: Date()))
        ring.markCommitted(sequenceNumber: 1)
        ring.append(LongScreenshotFrame(sequenceNumber: 2, image: try stripedImage(contrast: 220), capturedAt: Date()))
        ring.append(LongScreenshotFrame(sequenceNumber: 3, image: try stripedImage(contrast: 219), capturedAt: Date()))
        ring.append(LongScreenshotFrame(sequenceNumber: 4, image: try stripedImage(contrast: 218), capturedAt: Date()))

        let settled = ring.latestSettledFrame(
            after: ring.lastCommittedSequenceNumber,
            maximumDifference: 2
        )
        XCTAssertEqual(settled?.sequenceNumber, 4)
        let settledImage = try XCTUnwrap(settled?.image)
        XCTAssertEqual(
            LongScreenshotFrameRing.sampledSharpness(settledImage),
            LongScreenshotFrameRing.sampledSharpness(try stripedImage(contrast: 220)),
            accuracy: 0.001
        )
        XCTAssertGreaterThan(
            LongScreenshotFrameRing.sampledSharpness(try stripedImage(contrast: 220)),
            LongScreenshotFrameRing.sampledSharpness(try stripedImage(contrast: 80))
        )
    }

    func testScrollingPreviewUsesSharpestRecentImageAndAdvancesWatermark() throws {
        let ring = LongScreenshotFrameRing()
        ring.append(LongScreenshotFrame(sequenceNumber: 1, image: try stripedImage(contrast: 50), capturedAt: Date()))
        ring.markCommitted(sequenceNumber: 1)
        ring.append(LongScreenshotFrame(sequenceNumber: 2, image: try stripedImage(contrast: 220), capturedAt: Date()))
        ring.append(LongScreenshotFrame(sequenceNumber: 3, image: try stripedImage(contrast: 120), capturedAt: Date()))
        ring.append(LongScreenshotFrame(sequenceNumber: 4, image: try stripedImage(contrast: 80), capturedAt: Date()))

        let preview = try XCTUnwrap(ring.sharpestRecentFrame(after: ring.lastCommittedSequenceNumber))
        XCTAssertEqual(preview.sequenceNumber, 4)
        XCTAssertEqual(
            LongScreenshotFrameRing.sampledSharpness(preview.image),
            LongScreenshotFrameRing.sampledSharpness(try stripedImage(contrast: 220)),
            accuracy: 0.001
        )
    }

    private func makeFrame(sequenceNumber: Int, gray: UInt8) -> LongScreenshotFrame {
        LongScreenshotFrame(
            sequenceNumber: sequenceNumber,
            image: try! image(gray: gray),
            capturedAt: Date()
        )
    }

    private func image(gray: UInt8) throws -> CGImage {
        let width = 64
        let height = 48
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 255, count: height * bytesPerRow)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            pixels[index] = gray
            pixels[index + 1] = gray
            pixels[index + 2] = gray
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        return try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }

    private func stripedImage(contrast: UInt8) throws -> CGImage {
        let width = 64
        let height = 48
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 255, count: height * bytesPerRow)
        for y in 0..<height {
            for x in 0..<width {
                let value: UInt8 = (x / 4).isMultiple(of: 2) ? 20 : contrast
                let index = y * bytesPerRow + x * 4
                pixels[index] = value
                pixels[index + 1] = value
                pixels[index + 2] = value
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        return try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }
}
