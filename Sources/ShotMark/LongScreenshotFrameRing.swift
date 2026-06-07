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

    init(capacity: Int = 8) {
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

    func markCommitted(sequenceNumber: Int?) {
        guard let sequenceNumber else { return }
        lastCommittedSequenceNumber = max(lastCommittedSequenceNumber ?? sequenceNumber, sequenceNumber)
    }

    func reset() {
        frames.removeAll()
        lastCommittedSequenceNumber = nil
    }
}
