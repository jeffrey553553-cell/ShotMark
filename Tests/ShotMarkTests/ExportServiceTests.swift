import AppKit
import ImageIO
import XCTest
@testable import ShotMark

final class ExportServiceTests: XCTestCase {
    func testEveryAdvertisedImageFormatProducesDecodablePixels() throws {
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
        let service = ExportService()

        for format in ImageExportFormat.allCases {
            let payload = try service.imagePayload(
                for: state,
                format: format,
                quality: 0.82
            )
            let source = try XCTUnwrap(CGImageSourceCreateWithData(payload.fileData as CFData, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))

            XCTAssertEqual(
                CGImageSourceGetType(source) as String?,
                format.uniformType.identifier,
                "Unexpected encoded type for \(format.title)"
            )
            XCTAssertEqual(image.width, capture.image.width)
            XCTAssertEqual(image.height, capture.image.height)
            XCTAssertGreaterThan(payload.fileData.count, 100)
        }
    }

    func testConfiguredPayloadAlwaysKeepsPNGHistoryCopy() throws {
        let capture = try XCTUnwrap(DemoCaptureFactory.makeCapture())
        let payload = try ExportService().imagePayload(
            for: EditorState(capture: capture),
            format: .jpeg,
            quality: 0.7
        )

        let source = try XCTUnwrap(CGImageSourceCreateWithData(payload.pngData as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, ImageExportFormat.png.uniformType.identifier)
        XCTAssertEqual(payload.fileFormat, .jpeg)
    }

    func testPinnedPNGCanBeTranscodedToEverySaveFormat() throws {
        let capture = try XCTUnwrap(DemoCaptureFactory.makeCapture())
        let service = ExportService()
        let png = try service.pngData(for: EditorState(capture: capture))

        for format in ImageExportFormat.allCases {
            let data = try service.transcodePNGData(png, to: format, quality: 0.8)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            XCTAssertEqual(CGImageSourceGetType(source) as String?, format.uniformType.identifier)
        }
    }
}
