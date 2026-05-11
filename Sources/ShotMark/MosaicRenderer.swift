import AppKit
import CoreGraphics
import CoreImage

enum MosaicRenderer {
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    static func drawFrostedMosaic(rect: CGRect, blockSize: CGFloat, sourceImage: CGImage, pointSize: CGSize) {
        let clipped = rect.intersection(CGRect(origin: .zero, size: pointSize))
        guard clipped.width > 1, clipped.height > 1 else { return }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: clipped).addClip()
        drawBlurredSource(in: clipped, sourceImage: sourceImage, pointSize: pointSize, radius: max(20, blockSize * 3.0))
        drawGlassOverlay(in: clipped, tintAlpha: 0.24)
        NSGraphicsContext.restoreGraphicsState()
    }

    static func drawGlassPlaceholder(rect: CGRect, blockSize _: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        drawGlassOverlay(in: rect, tintAlpha: 0.30)
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawBlurredSource(in rect: CGRect, sourceImage: CGImage, pointSize: CGSize, radius: CGFloat) {
        let scaleX = CGFloat(sourceImage.width) / pointSize.width
        let scaleY = CGFloat(sourceImage.height) / pointSize.height
        let cropRect = CGRect(
            x: rect.minX * scaleX,
            y: (pointSize.height - rect.maxY) * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        ).integral

        guard let cropped = sourceImage.cropping(to: cropRect) else { return }

        let input = CIImage(cgImage: cropped).clampedToExtent()
        let blurred = input
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0.58,
                kCIInputBrightnessKey: -0.03,
                kCIInputContrastKey: 0.86
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
