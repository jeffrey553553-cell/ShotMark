import AppKit
import XCTest
@testable import ShotMark

final class PinnedScreenshotUITests: XCTestCase {
    override func setUpWithError() throws {
        _ = NSApplication.shared
    }

    func testPinnedWindowRendersImageAndHoverControls() throws {
        let image = makeSampleImage()
        let pngData = try XCTUnwrap(
            image.tiffRepresentation
                .flatMap(NSBitmapImageRep.init(data:))
                .flatMap { $0.representation(using: .png, properties: [:]) }
        )
        let screen = try XCTUnwrap(NSScreen.main)
        let controller = PinnedScreenshotWindowController(
            image: image,
            pngData: pngData,
            pointSize: image.size,
            sourceRect: CGRect(x: screen.frame.midX, y: screen.frame.midY, width: 320, height: 180),
            screen: screen,
            createdAt: Date()
        )
        controller.show()
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))

        let window = try XCTUnwrap(controller.window)
        let view = try XCTUnwrap(window.contentView as? PinnedScreenshotView)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: CGPoint(x: view.bounds.midX, y: view.bounds.midY),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ))
        view.mouseEntered(with: event)

        let rendered = try XCTUnwrap(render(view: view))
        XCTAssertGreaterThan(rendered.size.width, image.size.width)
        XCTAssertGreaterThan(rendered.size.height, image.size.height)
        XCTAssertTrue(hasVisibleVariation(rendered))
        writeSnapshotIfRequested(rendered)
        controller.close()
    }

    private func makeSampleImage() -> NSImage {
        let image = NSImage(size: CGSize(width: 640, height: 360))
        image.lockFocus()
        NSColor(calibratedRed: 0.07, green: 0.10, blue: 0.17, alpha: 1).setFill()
        CGRect(origin: .zero, size: image.size).fill()
        NSColor(calibratedRed: 0.15, green: 0.62, blue: 0.95, alpha: 1).setFill()
        NSBezierPath(
            roundedRect: CGRect(x: 42, y: 46, width: 270, height: 250),
            xRadius: 20,
            yRadius: 20
        ).fill()
        NSColor.white.withAlphaComponent(0.94).setFill()
        NSBezierPath(ovalIn: CGRect(x: 410, y: 116, width: 120, height: 120)).fill()
        image.unlockFocus()
        return image
    }

    private func render(view: NSView) -> NSImage? {
        view.layoutSubtreeIfNeeded()
        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return nil
        }
        view.cacheDisplay(in: view.bounds, to: representation)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(representation)
        return image
    }

    private func hasVisibleVariation(_ image: NSImage) -> Bool {
        guard let representation = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first else {
            return false
        }
        var colors = Set<String>()
        let xStep = max(1, representation.pixelsWide / 12)
        let yStep = max(1, representation.pixelsHigh / 8)
        for y in stride(from: 0, to: representation.pixelsHigh, by: yStep) {
            for x in stride(from: 0, to: representation.pixelsWide, by: xStep) {
                guard let color = representation.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                colors.insert(String(
                    format: "%.2f-%.2f-%.2f-%.2f",
                    color.redComponent,
                    color.greenComponent,
                    color.blueComponent,
                    color.alphaComponent
                ))
            }
        }
        return colors.count >= 4
    }

    private func writeSnapshotIfRequested(_ image: NSImage) {
        guard ProcessInfo.processInfo.environment["SHOTMARK_WRITE_UI_SNAPSHOTS"] == "1",
              let representation = image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)),
              let data = representation.representation(using: .png, properties: [:]) else {
            return
        }
        try? data.write(to: URL(fileURLWithPath: "/tmp/shotmark-pinned-window.png"))
    }
}
