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

    func latestSettledFrame(after sequenceNumber: Int?, maximumDifference: Double = 1.4) -> LongScreenshotFrame? {
        let candidates = frames.filter { frame in
            guard let sequenceNumber else { return true }
            return frame.sequenceNumber > sequenceNumber
        }
        guard candidates.count >= 2 else { return nil }
        let previous = candidates[candidates.count - 2]
        let latest = candidates[candidates.count - 1]
        guard Self.sampledDifference(previous.image, latest.image) <= maximumDifference else { return nil }
        return latest
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
