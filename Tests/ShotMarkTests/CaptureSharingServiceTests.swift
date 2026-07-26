import Foundation
import XCTest
@testable import ShotMark

final class CaptureSharingServiceTests: XCTestCase {
    private var rootURL: URL!

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShotMarkSharingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let rootURL {
            try? FileManager.default.removeItem(at: rootURL)
        }
    }

    func testSharingUsesConcreteSemanticFileURL() throws {
        let store = makeStore()
        let record = try store.addImage(
            data: Data("managed-png".utf8),
            kind: .screenshot,
            createdAt: Date(),
            pixelWidth: 640,
            pixelHeight: 400
        )
        let dragProvider = CaptureDragItemProvider(
            cacheRootURL: rootURL.appendingPathComponent("DragCache")
        )

        let items = try CaptureSharingService.items(
            for: record,
            store: store,
            dragItemProvider: dragProvider
        )
        let url = try XCTUnwrap(items.first as? NSURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path!))
        XCTAssertTrue(url.lastPathComponent?.hasPrefix("Screenshot ") == true)
        XCTAssertEqual(url.pathExtension, "png")
    }

    func testSharingPreservesExternalFileFormatAndName() throws {
        let externalURL = rootURL.appendingPathComponent("Review Export.tiff")
        try Data("tiff".utf8).write(to: externalURL)
        let store = makeStore()
        let record = try store.addImage(
            data: Data("managed-png".utf8),
            kind: .screenshot,
            createdAt: Date(),
            pixelWidth: 640,
            pixelHeight: 400,
            externalURL: externalURL
        )

        let items = try CaptureSharingService.items(for: record, store: store)
        let url = try XCTUnwrap(items.first as? NSURL)

        XCTAssertEqual((url as URL).standardizedFileURL, externalURL.standardizedFileURL)
        XCTAssertEqual(url.lastPathComponent, "Review Export.tiff")
    }

    private func makeStore() -> CaptureHistoryStore {
        CaptureHistoryStore(
            rootURL: rootURL.appendingPathComponent("History"),
            retentionPolicy: CaptureHistoryRetentionPolicy(
                maximumItemCount: 0,
                maximumAge: 0
            )
        )
    }
}
