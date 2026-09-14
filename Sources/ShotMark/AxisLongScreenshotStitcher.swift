import CoreGraphics
import Foundation

enum LongScreenshotAxis: String, Codable, Equatable {
    case undetermined
    case vertical
    case horizontal

    var displayName: String {
        switch self {
        case .undetermined: "待识别"
        case .vertical: "纵向"
        case .horizontal: "横向"
        }
    }
}

struct LongScreenshotScrollMotion: Equatable {
    let axis: LongScreenshotAxis
    let delta: CGFloat
}

enum LongScreenshotScrollMotionResolver {
    static func resolve(
        horizontalDelta: CGFloat,
        verticalDelta: CGFloat,
        lockedAxis: LongScreenshotAxis
    ) -> LongScreenshotScrollMotion? {
        let horizontalMagnitude = abs(horizontalDelta)
        let verticalMagnitude = abs(verticalDelta)

        switch lockedAxis {
        case .horizontal:
            guard horizontalMagnitude >= 0.1 else { return nil }
            return LongScreenshotScrollMotion(axis: .horizontal, delta: horizontalDelta)
        case .vertical:
            guard verticalMagnitude >= 0.1 else { return nil }
            return LongScreenshotScrollMotion(axis: .vertical, delta: verticalDelta)
        case .undetermined:
            guard max(horizontalMagnitude, verticalMagnitude) >= 0.1 else { return nil }
            // Trackpads often emit a small perpendicular component. Require a
            // clear horizontal intent; ambiguous diagonal gestures stay on the
            // long-standing vertical path.
            if horizontalMagnitude > verticalMagnitude * 1.25 {
                return LongScreenshotScrollMotion(axis: .horizontal, delta: horizontalDelta)
            }
            return LongScreenshotScrollMotion(axis: .vertical, delta: verticalDelta)
        }
    }
}

final class LongScreenshotStitcher {
    private let verticalStitcher = VerticalLongScreenshotStitcher()
    private var initialImage: CGImage?
    private var initialMaximumExtent: Int?
    private(set) var axis: LongScreenshotAxis = .undetermined

    var retainedContentPixelBytes: Int { verticalStitcher.retainedContentPixelBytes }
    var retainedViewportAnchorCount: Int { verticalStitcher.retainedViewportAnchorCount }
    var acceptedFrameCount: Int { verticalStitcher.acceptedFrameCount }
    var maximumOutputHeight: Int { verticalStitcher.maximumOutputHeight }

    var outputWidth: Int {
        axis == .horizontal ? verticalStitcher.outputHeight : verticalStitcher.outputWidth
    }

    var outputHeight: Int {
        axis == .horizontal ? verticalStitcher.outputWidth : verticalStitcher.outputHeight
    }

    /// Length along the active stitching axis. Preview throttling and capacity
    /// decisions must grow with this value for both vertical and horizontal captures.
    var outputExtent: Int { verticalStitcher.outputHeight }

    func configureAxis(_ requestedAxis: LongScreenshotAxis) -> Bool {
        guard requestedAxis != .undetermined else { return false }
        if axis == requestedAxis || (axis == .undetermined && requestedAxis == .vertical) {
            axis = requestedAxis
            return true
        }
        guard axis == .undetermined,
              verticalStitcher.acceptedFrameCount <= 1,
              let initialImage,
              let transformed = Self.transform(initialImage, for: requestedAxis)
        else { return false }

        verticalStitcher.reset()
        axis = requestedAxis
        guard verticalStitcher.append(
            transformed,
            maxOutputHeight: initialMaximumExtent,
            renderMergedImage: false
        ) != nil else {
            axis = .undetermined
            return false
        }
        return true
    }

    func reset() {
        verticalStitcher.reset()
        initialImage = nil
        initialMaximumExtent = nil
        axis = .undetermined
    }

    func append(
        _ image: CGImage,
        expectedDeltaPixels: Int? = nil,
        expectedDirection: LongScreenshotStitchDirection? = nil,
        maxOutputHeight: Int? = nil,
        renderMergedImage: Bool = true
    ) -> LongScreenshotStitchUpdate? {
        if initialImage == nil {
            initialImage = image
            initialMaximumExtent = maxOutputHeight
        }
        let effectiveAxis = axis == .horizontal ? LongScreenshotAxis.horizontal : .vertical
        guard let transformed = Self.transform(image, for: effectiveAxis),
              let update = verticalStitcher.append(
                transformed,
                expectedDeltaPixels: expectedDeltaPixels,
                expectedDirection: expectedDirection,
                maxOutputHeight: maxOutputHeight,
                renderMergedImage: false
              ) else { return nil }

        let renderedImage = renderMergedImage ? mergedImage() : nil
        return LongScreenshotStitchUpdate(
            outcome: update.outcome,
            mergedImage: renderedImage,
            acceptedFrameCount: update.acceptedFrameCount,
            // This remains the stitched extent for capacity and cadence logic.
            // Public output dimensions are exposed by outputWidth/outputHeight.
            outputHeight: update.outputHeight,
            direction: update.direction,
            confidence: update.confidence,
            maximumOutputHeight: update.maximumOutputHeight
        )
    }

    func mergedImage() -> CGImage? {
        guard let image = verticalStitcher.mergedImage() else { return nil }
        return axis == .horizontal ? Self.rotateCounterclockwise(image) : image
    }

    private static func transform(_ image: CGImage, for axis: LongScreenshotAxis) -> CGImage? {
        axis == .horizontal ? rotateClockwise(image) : image
    }

    private static func rotateClockwise(_ image: CGImage) -> CGImage? {
        rotate(image, clockwise: true)
    }

    private static func rotateCounterclockwise(_ image: CGImage) -> CGImage? {
        rotate(image, clockwise: false)
    }

    private static func rotate(_ image: CGImage, clockwise: Bool) -> CGImage? {
        let destinationWidth = image.height
        let destinationHeight = image.width
        guard let context = CGContext(
            data: nil,
            width: destinationWidth,
            height: destinationHeight,
            bitsPerComponent: 8,
            bytesPerRow: destinationWidth * 4,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return nil }

        context.interpolationQuality = .none
        if clockwise {
            context.translateBy(x: CGFloat(destinationWidth), y: 0)
            context.rotate(by: .pi / 2)
        } else {
            context.translateBy(x: 0, y: CGFloat(destinationHeight))
            context.rotate(by: -.pi / 2)
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}
