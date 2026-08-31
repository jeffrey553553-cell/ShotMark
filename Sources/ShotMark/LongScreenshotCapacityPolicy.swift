import Foundation

enum LongScreenshotCapacityLevel: Equatable {
    case normal
    case warning
    case limit
}

struct LongScreenshotCapacityPolicy {
    static let absoluteMaximumHeight = 120_000
    static let maximumEstimatedImageBytes = 512 * 1_024 * 1_024
    static let warningFraction = 0.80

    static func maximumHeight(imageWidth: Int, minimumHeight: Int) -> Int {
        let safeWidth = max(1, imageWidth)
        let pixelBudgetHeight = maximumEstimatedImageBytes / (safeWidth * 4)
        return max(
            max(1, minimumHeight),
            min(absoluteMaximumHeight, max(1, pixelBudgetHeight))
        )
    }

    static func level(outputHeight: Int, maximumHeight: Int) -> LongScreenshotCapacityLevel {
        guard maximumHeight > 0 else { return .limit }
        if outputHeight >= maximumHeight { return .limit }
        if Double(outputHeight) / Double(maximumHeight) >= warningFraction { return .warning }
        return .normal
    }
}
