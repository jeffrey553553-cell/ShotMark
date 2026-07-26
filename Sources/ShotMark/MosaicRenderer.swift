import AppKit
import CoreGraphics
import CoreImage

struct MosaicRenderParameters: Equatable {
    let blurRadiusPoints: CGFloat
    let saturation: CGFloat
    let brightness: CGFloat
    let contrast: CGFloat
    let tintAlpha: CGFloat
}

enum MosaicRenderer {
    private static let context = CIContext(options: [.useSoftwareRenderer: false])
    private static let supportedStrengthRange: ClosedRange<CGFloat> = 6...22

    static func parameters(for strength: CGFloat) -> MosaicRenderParameters {
        let clamped = min(max(strength, supportedStrengthRange.lowerBound), supportedStrengthRange.upperBound)
        let progress = (clamped - supportedStrengthRange.lowerBound)
            / (supportedStrengthRange.upperBound - supportedStrengthRange.lowerBound)
        return MosaicRenderParameters(
            blurRadiusPoints: 10 + progress * 18,
            saturation: 0.76 - progress * 0.28,
            brightness: -0.01 - progress * 0.03,
            contrast: 0.94 - progress * 0.10,
            tintAlpha: 0.10 + progress * 0.08
        )
    }

    static func drawFrostedMosaic(rect: CGRect, blockSize: CGFloat, sourceImage: CGImage, pointSize: CGSize) {
        let clipped = rect.intersection(CGRect(origin: .zero, size: pointSize))
        guard clipped.width > 1, clipped.height > 1 else { return }
        let parameters = parameters(for: blockSize)

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: clipped).addClip()
        drawBlurredSource(
            in: clipped,
            sourceImage: sourceImage,
            pointSize: pointSize,
            parameters: parameters
        )
        drawGlassOverlay(in: clipped, tintAlpha: parameters.tintAlpha)
        NSGraphicsContext.restoreGraphicsState()
    }

    static func drawGlassPlaceholder(rect: CGRect, blockSize: CGFloat) {
        let parameters = parameters(for: blockSize)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        drawGlassOverlay(in: rect, tintAlpha: parameters.tintAlpha)
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawBlurredSource(
        in rect: CGRect,
        sourceImage: CGImage,
        pointSize: CGSize,
        parameters: MosaicRenderParameters
    ) {
        let scaleX = CGFloat(sourceImage.width) / pointSize.width
        let scaleY = CGFloat(sourceImage.height) / pointSize.height
        let pixelScale = max(1, (scaleX + scaleY) / 2)
        let cropRect = CGRect(
            x: rect.minX * scaleX,
            y: (pointSize.height - rect.maxY) * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        ).integral

        guard let cropped = sourceImage.cropping(to: cropRect) else { return }

        let input = CIImage(cgImage: cropped).clampedToExtent()
        let blurred = input
            .applyingFilter(
                "CIGaussianBlur",
                parameters: [kCIInputRadiusKey: parameters.blurRadiusPoints * pixelScale]
            )
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: parameters.saturation,
                kCIInputBrightnessKey: parameters.brightness,
                kCIInputContrastKey: parameters.contrast
            ])
            .cropped(to: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))

        guard let blurredImage = context.createCGImage(blurred, from: blurred.extent) else { return }

        let previousInterpolation = NSGraphicsContext.current?.imageInterpolation
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: blurredImage, size: rect.size).draw(in: rect)
        NSGraphicsContext.current?.imageInterpolation = previousInterpolation ?? .default
    }

    private static func drawGlassOverlay(
        in rect: CGRect,
        tintAlpha: CGFloat
    ) {
        NSColor.black.withAlphaComponent(tintAlpha).setFill()
        rect.fill()

        let highlight = NSGradient(colors: [
            NSColor.white.withAlphaComponent(0.10),
            NSColor.white.withAlphaComponent(0.02),
            NSColor.black.withAlphaComponent(0.08)
        ])
        highlight?.draw(in: rect, angle: 90)
    }
}
