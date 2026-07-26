import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShotMark

final class ExportServiceTests: XCTestCase {
    func testRenderedExportIsPNGWithExpectedPixelSize() throws {
        let capture = try XCTUnwrap(DemoCaptureFactory.makeCapture())
        let state = EditorState(capture: capture)
        state.annotations = [
            .rectangle(
                rect: CGRect(x: 40, y: 40, width: 180, height: 90),
                color: .systemRed,
                lineWidth: 6,
                filled: false
            )
        ]
        let data = try ExportService().pngData(for: state)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))

        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.png.identifier)
        XCTAssertEqual(image.width, capture.image.width)
        XCTAssertEqual(image.height, capture.image.height)
        XCTAssertGreaterThan(data.count, 100)
    }

    func testDefaultImageURLsUseDownloadsAndPNG() {
        let date = Date(timeIntervalSince1970: 1_788_000_000)
        let screenshotURL = ExportService.defaultSaveURL(createdAt: date)
        let longScreenshotURL = ExportService.defaultLongScreenshotURL(createdAt: date)

        XCTAssertEqual(screenshotURL.deletingLastPathComponent(), AppSettings.defaultSaveDirectory)
        XCTAssertEqual(longScreenshotURL.deletingLastPathComponent(), AppSettings.defaultSaveDirectory)
        XCTAssertEqual(screenshotURL.pathExtension, "png")
        XCTAssertEqual(longScreenshotURL.pathExtension, "png")
        XCTAssertTrue(screenshotURL.lastPathComponent.hasPrefix("Screenshot "))
        XCTAssertTrue(longScreenshotURL.lastPathComponent.hasPrefix("Long Screenshot "))
    }

    func testDefaultRecordingURLUsesDownloadsAndMP4() {
        let url = ExportService.defaultRecordingURL(createdAt: Date(timeIntervalSince1970: 1_788_000_000))

        XCTAssertEqual(url.deletingLastPathComponent(), AppSettings.defaultSaveDirectory)
        XCTAssertEqual(url.pathExtension, "mp4")
        XCTAssertTrue(url.lastPathComponent.hasPrefix("Recording "))
    }
}
