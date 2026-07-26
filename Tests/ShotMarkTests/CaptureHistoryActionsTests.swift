import AppKit
import XCTest
@testable import ShotMark

@MainActor
final class CaptureHistoryActionsTests: XCTestCase {
    func testCopyUsesManagedPNGWhenExternalSaveUsesAnotherFormat() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShotMarkHistoryActionTests-\(UUID().uuidString)", isDirectory: true)
        let externalJPEG = root.appendingPathComponent("Saved Screenshot.jpg")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: externalJPEG)

        let capture = try XCTUnwrap(DemoCaptureFactory.makeCapture())
        let pngData = try ExportService().pngData(for: EditorState(capture: capture))
        let store = CaptureHistoryStore(rootURL: root.appendingPathComponent("History"))
        let record = try store.addImage(
            data: pngData,
            kind: .screenshot,
            createdAt: Date(),
            pixelWidth: capture.image.width,
            pixelHeight: capture.image.height,
            externalURL: externalJPEG
        )

        try CaptureHistoryActions.copy(record, store: store)

        XCTAssertEqual(NSPasteboard.general.data(forType: .png), pngData)
    }
}
