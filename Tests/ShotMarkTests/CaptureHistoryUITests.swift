import AppKit
import XCTest
@testable import ShotMark

final class CaptureHistoryUITests: XCTestCase {
    private var rootURL: URL!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShotMarkHistoryUITests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        QuickAccessWindowController.shared.dismiss()
        if let rootURL {
            try? FileManager.default.removeItem(at: rootURL)
        }
    }

    func testQuickAccessCardRendersThumbnailAndActions() throws {
        let store = CaptureHistoryStore(rootURL: rootURL)
        let record = try store.addImage(
            data: makeSamplePNG(),
            kind: .screenshot,
            createdAt: Date(),
            pixelWidth: 640,
            pixelHeight: 400
        )
        QuickAccessWindowController.shared.show(
            record: record,
            store: store,
            message: "已复制到剪切板",
            screen: NSScreen.main
        )
        runMainLoop()

        let window = try XCTUnwrap(NSApp.windows.first {
            $0.identifier?.rawValue == "ShotMarkQuickAccessPanel"
        })
        let image = try XCTUnwrap(render(window: window))
        XCTAssertEqual(image.size.width, 360, accuracy: 1)
        XCTAssertEqual(image.size.height, 122, accuracy: 1)
        XCTAssertTrue(hasVisibleVariation(image))
        writeSnapshotIfRequested(image, name: "shotmark-quick-access.png")
    }

    func testHistoryWindowRendersStoredRecord() throws {
        let store = CaptureHistoryStore(rootURL: rootURL)
        _ = try store.addImage(
            data: makeSamplePNG(),
            kind: .longScreenshot,
            createdAt: Date(),
            pixelWidth: 640,
            pixelHeight: 1_280
        )
        let controller = CaptureHistoryWindowController(store: store)
        controller.showWindow(nil)
        controller.window?.layoutIfNeeded()
        runMainLoop()

        let image = try XCTUnwrap(controller.window.flatMap(render(window:)))
        XCTAssertGreaterThanOrEqual(image.size.width, 640)
        XCTAssertGreaterThanOrEqual(image.size.height, 420)
        XCTAssertTrue(hasVisibleVariation(image))
        writeSnapshotIfRequested(image, name: "shotmark-history-window.png")
        controller.close()
    }

    private func makeSamplePNG() throws -> Data {
        let image = NSImage(size: CGSize(width: 640, height: 400))
        image.lockFocus()
        NSColor(calibratedRed: 0.08, green: 0.12, blue: 0.20, alpha: 1).setFill()
        CGRect(x: 0, y: 0, width: 640, height: 400).fill()
        NSColor(calibratedRed: 0.20, green: 0.68, blue: 0.96, alpha: 1).setFill()
        NSBezierPath(roundedRect: CGRect(x: 54, y: 62, width: 260, height: 220), xRadius: 18, yRadius: 18).fill()
        NSColor.white.withAlphaComponent(0.92).setFill()
        NSBezierPath(ovalIn: CGRect(x: 390, y: 170, width: 110, height: 110)).fill()
        image.unlockFocus()

        let representation = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        return try XCTUnwrap(representation.representation(using: .png, properties: [:]))
    }

    private func render(window: NSWindow) -> NSImage? {
        guard let view = window.contentView else { return nil }
        view.layoutSubtreeIfNeeded()
        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
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
                if let color = representation.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                    colors.insert(String(format: "%.2f-%.2f-%.2f-%.2f", color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent))
                }
            }
        }
        return colors.count >= 3
    }

    private func runMainLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
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
