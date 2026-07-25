import AVFoundation
import CoreVideo
import XCTest
@testable import ShotMark

final class VideoSegmentMergerTests: XCTestCase {
    func testTwoRealH264SegmentsMergeIntoOnePlayableTimeline() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShotMarkSegmentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = directory.appendingPathComponent("first.mp4")
        let second = directory.appendingPathComponent("second.mp4")
        let output = directory.appendingPathComponent("merged.mp4")
        try await makeVideoSegment(url: first, pixel: 0xFFFF4A3D)
        try await makeVideoSegment(url: second, pixel: 0xFF3D8BFF)

        try await VideoSegmentMerger.merge(segmentURLs: [first, second], outputURL: output)

        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertGreaterThan(duration.seconds, 0.9)
        XCTAssertLessThan(duration.seconds, 1.5)
    }

    func testMissingAndEmptySegmentsDoNotDiscardValidRecording() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShotMarkSegmentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let valid = directory.appendingPathComponent("valid.mp4")
        let empty = directory.appendingPathComponent("empty.mp4")
        let missing = directory.appendingPathComponent("missing.mp4")
        let output = directory.appendingPathComponent("merged.mp4")
        try Data().write(to: empty)
        try await makeVideoSegment(url: valid, pixel: 0xFF5BD36A)

        try await VideoSegmentMerger.merge(
            segmentURLs: [missing, empty, valid],
            outputURL: output
        )

        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertGreaterThan(duration.seconds, 0.4)
        XCTAssertEqual(videoTracks.count, 1)
    }

    private func makeVideoSegment(url: URL, pixel: UInt32) async throws {
        let width = 160
        let height = 90
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height
            ]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<6 {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            guard let pool = adaptor.pixelBufferPool else {
                XCTFail("Pixel buffer pool was not created")
                return
            }
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer), kCVReturnSuccess)
            guard let buffer else {
                XCTFail("Pixel buffer allocation failed")
                return
            }
            fill(buffer: buffer, pixel: pixel)
            XCTAssertTrue(adaptor.append(
                buffer,
                withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10)
            ))
        }

        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }
        if writer.status != .completed {
            throw writer.error ?? VideoSegmentMergerError.exportFailed
        }
    }

    private func fill(buffer: CVPixelBuffer, pixel: UInt32) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else { return }
        let count = CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer)
        baseAddress.assumingMemoryBound(to: UInt32.self).initialize(
            repeating: pixel,
            count: count / MemoryLayout<UInt32>.size
        )
    }
}
