import CoreImage
import CoreImage.CIFilterBuiltins
import XCTest
@testable import ShotMark

final class OCRServiceTests: XCTestCase {
    func testRecognizeContentDecodesQRCodePayload() throws {
        let payload = "https://shotmark.app/qr-test?version=1"
        let image = try makeQRCode(payload: payload)
        let expectation = expectation(description: "QR recognition")
        var recognized: OCRRecognitionResult?
        var recognitionError: Error?

        OCRService().recognizeContent(in: image) { result in
            switch result {
            case .success(let content):
                recognized = content
            case .failure(let error):
                recognitionError = error
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 10)
        XCTAssertNil(recognitionError)
        XCTAssertEqual(recognized?.codes.map(\.payload), [payload])
        XCTAssertEqual(recognized?.codes.first?.displayName, "二维码")
    }

    func testClipboardContentIncludesTextAndEveryDetectedCode() {
        let codes = [
            OCRDetectedCode(
                payload: "https://shotmark.app/one",
                symbology: .qr,
                boundingBox: .zero
            ),
            OCRDetectedCode(
                payload: "CODE-128-123",
                symbology: .code128,
                boundingBox: .zero
            )
        ]

        XCTAssertEqual(
            OCRClipboardContent.compose(text: "  识别文字\n第二行  ", codes: codes),
            "识别文字\n第二行\n\nhttps://shotmark.app/one\nCODE-128-123"
        )
        XCTAssertEqual(
            OCRClipboardContent.compose(text: "", codes: codes),
            "https://shotmark.app/one\nCODE-128-123"
        )
        XCTAssertEqual(
            OCRClipboardContent.compose(text: "Only text", codes: []),
            "Only text"
        )
    }

    private func makeQRCode(payload: String) throws -> CGImage {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(
            by: CGAffineTransform(scaleX: 12, y: 12)
        ), let image = CIContext(options: [.useSoftwareRenderer: true]).createCGImage(
            output,
            from: output.extent
        ) else {
            throw NSError(domain: "OCRServiceTests", code: 1)
        }
        return image
    }
}
