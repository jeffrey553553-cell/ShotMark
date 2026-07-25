import AppKit
import XCTest
@testable import ShotMark

final class RecordingControlUITests: XCTestCase {
    override func setUpWithError() throws {
        _ = NSApplication.shared
    }

    func testControlRendersAndDispatchesPauseAndStopSeparately() throws {
        let view = RecordingControlView(state: .recording(
            startedAt: Date().addingTimeInterval(-12),
            elapsedBeforeStart: 0
        ))
        view.frame = CGRect(x: 0, y: 0, width: 184, height: 38)
        var pauseCount = 0
        var stopCount = 0
        view.onTogglePause = { pauseCount += 1 }
        view.onStop = { stopCount += 1 }

        view.mouseDown(with: try mouseEvent(at: CGPoint(x: 20, y: 19)))
        view.mouseDown(with: try mouseEvent(at: CGPoint(x: 110, y: 19)))

        XCTAssertEqual(pauseCount, 1)
        XCTAssertEqual(stopCount, 1)
        let rendered = try XCTUnwrap(render(view: view))
        XCTAssertTrue(hasVisibleVariation(rendered))
        writeSnapshotIfRequested(rendered, name: "shotmark-recording-control.png")
    }

    func testPausedControlRendersFrozenTime() throws {
        let view = RecordingControlView(state: .paused(elapsed: 65))
        view.frame = CGRect(x: 0, y: 0, width: 184, height: 38)

        let rendered = try XCTUnwrap(render(view: view))
        XCTAssertTrue(hasVisibleVariation(rendered))
        writeSnapshotIfRequested(rendered, name: "shotmark-recording-control-paused.png")
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
