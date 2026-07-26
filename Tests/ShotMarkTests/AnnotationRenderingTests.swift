import AppKit
import XCTest
@testable import ShotMark

final class AnnotationRenderingTests: XCTestCase {
    func testAnnotationShowcaseRendersVisiblePixels() throws {
        let size = CGSize(width: 960, height: 600)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: .alphaFirst,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        bitmap.size = size
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.16, alpha: 1).setFill()
        CGRect(origin: .zero, size: size).fill()
        drawBackdrop(in: size)

        let target = CGRect(x: 350, y: 240, width: 210, height: 120)
        let callout = AnnotationGeometry.calloutLayout(
            for: target,
            in: CGRect(origin: .zero, size: size),
            textSize: CGSize(width: 180, height: 34)
        )
        let annotations: [Annotation] = [
            .rectangle(rect: CGRect(x: 65, y: 65, width: 220, height: 120), color: .systemRed, lineWidth: 4, filled: false),
            .arrow(start: CGPoint(x: 90, y: 260), end: CGPoint(x: 285, y: 350), color: .systemOrange, lineWidth: 5),
            .numberMarker(center: CGPoint(x: 130, y: 470), number: 3, color: .systemBlue, markerSize: 16),
            .text(origin: CGPoint(x: 180, y: 455), value: "重点信息\n支持多行评论", color: .white, fontSize: 20),
            .mosaic(rect: CGRect(x: 650, y: 70, width: 230, height: 100), blockSize: 12),
            .callout(
                targetRect: target,
                arrowStart: callout.arrowStart,
                arrowEnd: callout.arrowEnd,
                textOrigin: callout.textOrigin,
                text: "这里需要调整",
                color: .systemPink,
                lineWidth: 4,
                fontSize: 18
            )
        ]
        AnnotationDrawing.draw(annotations, in: size)
        graphics.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 10_000)

        if ProcessInfo.processInfo.environment["SHOTMARK_WRITE_UI_SNAPSHOTS"] == "1" {
            try png.write(to: URL(fileURLWithPath: "/tmp/shotmark-annotation-showcase.png"))
        }
    }

    private func drawBackdrop(in size: CGSize) {
        NSColor.white.withAlphaComponent(0.05).setStroke()
        let grid = NSBezierPath()
        for x in stride(from: CGFloat(0), through: size.width, by: 40) {
            grid.move(to: CGPoint(x: x, y: 0))
            grid.line(to: CGPoint(x: x, y: size.height))
        }
        for y in stride(from: CGFloat(0), through: size.height, by: 40) {
            grid.move(to: CGPoint(x: 0, y: y))
            grid.line(to: CGPoint(x: size.width, y: y))
        }
        grid.lineWidth = 1
        grid.stroke()
    }
}
