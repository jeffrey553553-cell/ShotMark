import AppKit
import CoreGraphics

enum DemoCaptureFactory {
    static func makeCapture() -> CaptureResult? {
        let pixelSize = CGSize(width: 1200, height: 760)
        let pointSize = CGSize(width: 800, height: 506)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(pixelSize.width),
            pixelsHigh: Int(pixelSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: .alphaFirst,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }
        rep.size = pointSize

        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        drawSample(in: CGRect(origin: .zero, size: pointSize))
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let image = rep.cgImage else { return nil }
        let screen = NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 80, y: 80, width: pointSize.width, height: pointSize.height)
        let origin = CGPoint(x: visible.midX - pointSize.width / 2, y: visible.midY - pointSize.height / 2)
        return CaptureResult(
            image: image,
            selectionRectInScreen: CGRect(origin: origin, size: pointSize),
            screenScale: pixelSize.width / pointSize.width,
            createdAt: Date()
        )
    }

    private static func drawSample(in rect: CGRect) {
        NSColor(calibratedRed: 0.94, green: 0.95, blue: 0.97, alpha: 1).setFill()
        rect.fill()

        let card = rect.insetBy(dx: 48, dy: 42)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: card, xRadius: 12, yRadius: 12).fill()

        NSColor(calibratedRed: 0.14, green: 0.18, blue: 0.24, alpha: 1).setFill()
        NSBezierPath(roundedRect: CGRect(x: card.minX, y: card.maxY - 72, width: card.width, height: 72), xRadius: 12, yRadius: 12).fill()

        draw("订单数据看板", at: CGPoint(x: card.minX + 28, y: card.maxY - 46), size: 24, weight: .bold, color: .white)
        draw("Revenue Overview", at: CGPoint(x: card.minX + 28, y: card.maxY - 112), size: 28, weight: .bold, color: .labelColor)
        draw("这里是一段用于测试 OCR 的中文内容。", at: CGPoint(x: card.minX + 28, y: card.maxY - 154), size: 18, weight: .regular, color: .secondaryLabelColor)
        draw("English text is also included for recognition.", at: CGPoint(x: card.minX + 28, y: card.maxY - 184), size: 18, weight: .regular, color: .secondaryLabelColor)

        let chart = CGRect(x: card.minX + 28, y: card.minY + 58, width: card.width - 56, height: 180)
        NSColor(calibratedRed: 0.89, green: 0.92, blue: 0.96, alpha: 1).setFill()
        NSBezierPath(roundedRect: chart, xRadius: 8, yRadius: 8).fill()

        NSColor.systemBlue.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 4
        path.move(to: CGPoint(x: chart.minX + 30, y: chart.minY + 44))
        path.curve(to: CGPoint(x: chart.minX + 260, y: chart.minY + 118), controlPoint1: CGPoint(x: chart.minX + 100, y: chart.minY + 150), controlPoint2: CGPoint(x: chart.minX + 180, y: chart.minY + 24))
        path.curve(to: CGPoint(x: chart.maxX - 40, y: chart.minY + 138), controlPoint1: CGPoint(x: chart.minX + 380, y: chart.minY + 210), controlPoint2: CGPoint(x: chart.minX + 520, y: chart.minY + 70))
        path.stroke()
    }

    private static func draw(_ text: String, at point: CGPoint, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
        text.draw(
            at: point,
            withAttributes: [
                .font: NSFont.systemFont(ofSize: size, weight: weight),
                .foregroundColor: color
            ]
        )
    }
}
