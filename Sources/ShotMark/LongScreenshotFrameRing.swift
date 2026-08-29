import CoreGraphics
import Foundation

struct LongScreenshotFrame {
    let sequenceNumber: Int
    let image: CGImage
    let capturedAt: Date
}

final class LongScreenshotFrameRing {
    private let capacity: Int
    private(set) var frames: [LongScreenshotFrame] = []
    private(set) var lastCommittedSequenceNumber: Int?

    init(capacity: Int = 30) {
        self.capacity = max(1, capacity)
    }

    var latest: LongScreenshotFrame? {
        frames.last
    }

    @discardableResult
    func append(_ frame: LongScreenshotFrame) -> LongScreenshotFrame {
        frames.append(frame)
        if frames.count > capacity {
            frames.removeFirst(frames.count - capacity)
        }
        return frame
    }

    func latestFrame(after sequenceNumber: Int?) -> LongScreenshotFrame? {
        guard let sequenceNumber else { return latest }
        return frames.last { $0.sequenceNumber > sequenceNumber }
    }

    func sharpestRecentFrame(after sequenceNumber: Int?, maximumCount: Int = 4) -> LongScreenshotFrame? {
        let candidates = frames.filter { frame in
            guard let sequenceNumber else { return true }
            return frame.sequenceNumber > sequenceNumber
        }
        guard let newest = candidates.last else { return nil }
        let recent = candidates.suffix(max(1, maximumCount))
        let sharpest = recent.reduce(newest) { best, candidate in
            Self.sampledSharpness(candidate.image) >= Self.sampledSharpness(best.image)
                ? candidate
                : best
        }
        return LongScreenshotFrame(
            sequenceNumber: newest.sequenceNumber,
            image: sharpest.image,
            capturedAt: newest.capturedAt
        )
    }

    func latestSettledFrame(
        after sequenceNumber: Int?,
        requiredConsecutiveFrames: Int = 3,
        maximumDifference: Double = 1.4
    ) -> LongScreenshotFrame? {
        let candidates = frames.filter { frame in
            guard let sequenceNumber else { return true }
            return frame.sequenceNumber > sequenceNumber
        }
        let requiredCount = max(2, requiredConsecutiveFrames)
        guard candidates.count >= requiredCount else { return nil }
        let stableCandidates = Array(candidates.suffix(requiredCount))
        for index in 1..<stableCandidates.count {
            guard Self.sampledDifference(
                stableCandidates[index - 1].image,
                stableCandidates[index].image
            ) <= maximumDifference else { return nil }
        }

        let sharpest = stableCandidates.reduce(stableCandidates[0]) { best, candidate in
            Self.sampledSharpness(candidate.image) >= Self.sampledSharpness(best.image)
                ? candidate
                : best
        }
        let newest = stableCandidates[stableCandidates.count - 1]
        return LongScreenshotFrame(
            sequenceNumber: newest.sequenceNumber,
            image: sharpest.image,
            capturedAt: newest.capturedAt
        )
    }

    static func sampledDifference(_ lhs: CGImage, _ rhs: CGImage) -> Double {
        guard lhs.width == rhs.width, lhs.height == rhs.height else { return 255 }
        let sampleWidth = 64
        let sampleHeight = 40
        guard let lhsPixels = sampledPixels(lhs, width: sampleWidth, height: sampleHeight),
              let rhsPixels = sampledPixels(rhs, width: sampleWidth, height: sampleHeight) else {
            return 255
        }

        let xRange = (sampleWidth / 8)..<(sampleWidth - sampleWidth / 8)
        let yRange = (sampleHeight / 10)..<(sampleHeight - sampleHeight / 10)
        var total = 0.0
        var sampleCount = 0
        for y in yRange {
            for x in xRange {
                let index = (y * sampleWidth + x) * 4
                total += Double(abs(Int(lhsPixels[index]) - Int(rhsPixels[index])))
                total += Double(abs(Int(lhsPixels[index + 1]) - Int(rhsPixels[index + 1])))
                total += Double(abs(Int(lhsPixels[index + 2]) - Int(rhsPixels[index + 2])))
                sampleCount += 1
            }
        }
        return sampleCount > 0 ? total / Double(sampleCount * 3) : 255
    }

    static func sampledSharpness(_ image: CGImage) -> Double {
        let width = 64
        let height = 40
        guard let pixels = sampledPixels(image, width: width, height: height) else { return 0 }
        var total = 0.0
        var count = 0
        for y in 2..<(height - 2) {
            for x in 2..<(width - 2) {
                let center = (y * width + x) * 4
                let left = (y * width + x - 1) * 4
                let right = (y * width + x + 1) * 4
                let above = ((y - 1) * width + x) * 4
                let below = ((y + 1) * width + x) * 4
                for channel in 0..<3 {
                    total += Double(abs(Int(pixels[right + channel]) - Int(pixels[left + channel])))
                    total += Double(abs(Int(pixels[below + channel]) - Int(pixels[above + channel])))
                    total += Double(abs(
                        Int(pixels[left + channel]) + Int(pixels[right + channel])
                            + Int(pixels[above + channel]) + Int(pixels[below + channel])
                            - Int(pixels[center + channel]) * 4
                    ))
                    count += 3
                }
            }
        }
        return count > 0 ? total / Double(count) : 0
    }

    func markCommitted(sequenceNumber: Int?) {
        guard let sequenceNumber else { return }
        lastCommittedSequenceNumber = max(lastCommittedSequenceNumber ?? sequenceNumber, sequenceNumber)
    }

    func reset() {
        frames.removeAll()
        lastCommittedSequenceNumber = nil
    }

    private static func sampledPixels(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let address = buffer.baseAddress,
                  let context = CGContext(
                    data: address,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
                  ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drew ? pixels : nil
    }
}
