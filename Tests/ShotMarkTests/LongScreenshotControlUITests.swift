import AppKit
import XCTest
@testable import ShotMark

final class LongScreenshotControlUITests: XCTestCase {
    override func setUpWithError() throws {
        _ = NSApplication.shared
    }

    func testControlDefaultsToManualAndAutomaticRequiresAUserClick() throws {
        let view = LongScreenshotControlView(frame: CGRect(x: 0, y: 0, width: 226, height: 40))
        var automaticToggleCount = 0
        view.onAutomaticToggle = { automaticToggleCount += 1 }

        XCTAssertEqual(view.captureMode, .manual)
        XCTAssertEqual(automaticToggleCount, 0)

        view.mouseDown(with: try mouseEvent(at: CGPoint(x: 45, y: 20)))

        XCTAssertEqual(automaticToggleCount, 1)
    }

    func testControlRendersManualAndRunningAutomaticStates() throws {
        let view = LongScreenshotControlView(frame: CGRect(x: 0, y: 0, width: 226, height: 40))
        let manualImage = try XCTUnwrap(render(view: view))
        XCTAssertTrue(hasVisibleVariation(manualImage))
        writeSnapshotIfRequested(manualImage, name: "shotmark-longshot-control-manual.png")

        view.captureMode = .automatic
        view.needsDisplay = true
        let automaticImage = try XCTUnwrap(render(view: view))
        XCTAssertTrue(hasVisibleVariation(automaticImage))
        writeSnapshotIfRequested(automaticImage, name: "shotmark-longshot-control-automatic.png")
    }

    private func mouseEvent(at point: CGPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
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
        for y in stride(from: 0, to: representation.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: representation.pixelsWide, by: 8) {
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

    private func writeSnapshotIfRequested(_ image: NSImage, name: String) {
        guard ProcessInfo.processInfo.environment["SHOTMARK_WRITE_UI_SNAPSHOTS"] == "1",
              let representation = image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)),
              let data = representation.representation(using: .png, properties: [:]) else {
            return
        }
        try? data.write(to: URL(fileURLWithPath: "/tmp").appendingPathComponent(name))
    }
}
