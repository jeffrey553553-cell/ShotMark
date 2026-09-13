import AppKit
import XCTest
@testable import ShotMark

@MainActor
final class LongScreenshotPreviewUITests: XCTestCase {
    override func setUpWithError() throws {
        _ = NSApplication.shared
    }

    func testCropHandleDragUpdatesCropAndResetRestoresFullImage() throws {
        let view = LongScreenshotPreviewView(frame: CGRect(x: 0, y: 0, width: 152, height: 300))
        view.image = try makeSampleImage(width: 200, height: 800)
        var updates: [LongScreenshotCropInsets] = []
        view.onCropChange = { top, bottom in
            updates.append(LongScreenshotCropInsets(top: top, bottom: bottom))
        }

        view.mouseDown(with: try mouseEvent(type: .leftMouseDown, at: CGPoint(x: 76, y: 267)))
        view.mouseDragged(with: try mouseEvent(type: .leftMouseDragged, at: CGPoint(x: 76, y: 239)))
        view.mouseUp(with: try mouseEvent(type: .leftMouseUp, at: CGPoint(x: 76, y: 239)))

        XCTAssertGreaterThan(view.cropTopPixels, 0)
        XCTAssertEqual(view.cropBottomPixels, 0)
        XCTAssertEqual(updates.last?.top, view.cropTopPixels)

        view.mouseDown(with: try mouseEvent(type: .leftMouseDown, at: CGPoint(x: 132, y: 282)))

        XCTAssertEqual(view.cropTopPixels, 0)
        XCTAssertEqual(view.cropBottomPixels, 0)
        XCTAssertEqual(updates.last, LongScreenshotCropInsets(top: 0, bottom: 0))
    }

    func testPreviewRendersUncroppedAndCroppedStates() throws {
        let previousAppearance = NSApplication.shared.appearance
        defer { NSApplication.shared.appearance = previousAppearance }

        for (appearance, name) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
            NSApplication.shared.appearance = NSAppearance(named: appearance)
            let view = LongScreenshotPreviewView(frame: CGRect(x: 0, y: 0, width: 152, height: 300))
            view.image = try makeSampleImage(width: 200, height: 800)
            view.status = "继续缓慢滚动"
            view.directionText = "向下"
            view.cropTopPixels = 80
            view.cropBottomPixels = 120

            let image = try XCTUnwrap(render(view: view))
            XCTAssertTrue(hasVisibleVariation(image))
            writeSnapshotIfRequested(image, name: "shotmark-longshot-preview-\(name).png")
        }
    }

    private func mouseEvent(type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }

    private func makeSampleImage(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        for row in 0..<8 {
            let color = row.isMultiple(of: 2)
                ? NSColor(calibratedRed: 0.18, green: 0.42, blue: 0.78, alpha: 1)
                : NSColor(calibratedRed: 0.08, green: 0.12, blue: 0.20, alpha: 1)
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: 0, y: row * height / 8, width: width, height: height / 8))
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func render(view: NSView) -> NSImage? {
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
        for y in stride(from: 0, to: representation.pixelsHigh, by: 6) {
            for x in stride(from: 0, to: representation.pixelsWide, by: 6) {
                guard let color = representation.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                colors.insert(String(format: "%.2f-%.2f-%.2f", color.redComponent, color.greenComponent, color.blueComponent))
            }
        }
        return colors.count >= 6
    }

    private func writeSnapshotIfRequested(_ image: NSImage, name: String) {
        guard ProcessInfo.processInfo.environment["SHOTMARK_WRITE_UI_SNAPSHOTS"] == "1",
              let representation = image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)),
              let data = representation.representation(using: .png, properties: [:]) else {
            return
        }
        try? data.write(to: URL(fileURLWithPath: "/tmp").appendingPathComponent(name))
    }
}
