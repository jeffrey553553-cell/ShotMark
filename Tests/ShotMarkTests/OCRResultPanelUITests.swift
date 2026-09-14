import AppKit
import Vision
import XCTest
@testable import ShotMark

@MainActor
final class OCRResultPanelUITests: XCTestCase {
    func testMixedTextAndCodesRenderInLightAndDarkAppearances() throws {
        try render(appearance: .aqua, path: "/tmp/shotmark-ocr-codes-light.png")
        try render(appearance: .darkAqua, path: "/tmp/shotmark-ocr-codes-dark.png")
    }

    private func render(appearance: NSAppearance.Name, path: String) throws {
        let application = NSApplication.shared
        let previousAppearance = application.appearance
        application.appearance = NSAppearance(named: appearance)
        defer { application.appearance = previousAppearance }

        let controller = OCRResultPanelController(text: "OCR 识别中...")
        let initialView = try XCTUnwrap(controller.window?.contentView)
        let initialCopyButton = try XCTUnwrap(
            allSubviews(of: NSButton.self, in: initialView).first { $0.title == "复制全部" }
        )
        XCTAssertFalse(initialCopyButton.isEnabled)
        controller.update(result: OCRRecognitionResult(
            lines: [
                OCRLine(text: "ShotMark 识别出的正文", boundingBox: .zero),
                OCRLine(text: "Text stays selectable.", boundingBox: .zero)
            ],
            codes: [
                OCRDetectedCode(
                    payload: "https://shotmark.app/example",
                    symbology: .qr,
                    boundingBox: .zero
                ),
                OCRDetectedCode(
                    payload: "CODE-128-123456",
                    symbology: .code128,
                    boundingBox: .zero
                )
            ]
        ))
        let window = try XCTUnwrap(controller.window)
        window.orderFrontRegardless()
        defer { controller.close() }
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        view.layoutSubtreeIfNeeded()

        let popup = try XCTUnwrap(allSubviews(of: NSPopUpButton.self, in: view).first)
        XCTAssertEqual(popup.numberOfItems, 2)
        XCTAssertTrue(allSubviews(of: NSButton.self, in: view).contains { $0.title == "复制码" })

        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 300)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 200)

        if ProcessInfo.processInfo.environment["SHOTMARK_WRITE_UI_SNAPSHOTS"] == "1" {
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: path))
        }

        controller.update(result: OCRRecognitionResult(
            lines: [],
            codes: [
                OCRDetectedCode(
                    payload: "shotmark-code-only",
                    symbology: .qr,
                    boundingBox: .zero
                )
            ]
        ))
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(initialCopyButton.isEnabled)
        XCTAssertTrue(
            allSubviews(of: NSTextView.self, in: view).contains {
                $0.string.contains("已识别下方二维码或条码")
            }
        )
    }

    private func allSubviews<T: NSView>(of type: T.Type, in root: NSView) -> [T] {
        root.subviews.flatMap { child -> [T] in
            let match = child as? T
            return (match.map { [$0] } ?? []) + allSubviews(of: type, in: child)
        }
    }
}
