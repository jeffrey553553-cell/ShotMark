import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import ShotMark

final class CaptureDragItemProviderTests: XCTestCase {
    private var rootURL: URL!
    private var cacheURL: URL!

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShotMarkDragProviderTests-\(UUID().uuidString)", isDirectory: true)
        cacheURL = rootURL.appendingPathComponent("DragCache", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let rootURL {
            try? FileManager.default.removeItem(at: rootURL)
        }
    }

    func testSavedImageKeepsExternalURLAndFileName() throws {
        let store = makeStore()
        let externalURL = rootURL.appendingPathComponent("My Export.heic")
        try Data("external-image".utf8).write(to: externalURL)
        let record = try store.addImage(
            data: Data("managed-png".utf8),
            kind: .screenshot,
            createdAt: Date(timeIntervalSince1970: 1_000),
            pixelWidth: 640,
            pixelHeight: 400,
            externalURL: externalURL
        )
        let provider = makeProvider()

        let result = try provider.dragURL(for: record, store: store)

        XCTAssertEqual(result.standardizedFileURL, externalURL.standardizedFileURL)
        XCTAssertEqual(result.lastPathComponent, "My Export.heic")
    }

    func testManagedImageGetsStableSemanticFileName() throws {
        let store = makeStore()
        let data = Data("managed-png".utf8)
        let record = try store.addImage(
            data: data,
            kind: .longScreenshot,
            createdAt: Date(timeIntervalSince1970: 1_709_215_200),
            pixelWidth: 640,
            pixelHeight: 1_400
        )
        let provider = makeProvider()

        let firstURL = try provider.dragURL(for: record, store: store)
        let secondURL = try provider.dragURL(for: record, store: store)

        XCTAssertEqual(firstURL, secondURL)
        XCTAssertTrue(firstURL.lastPathComponent.hasPrefix("Long Screenshot "))
        XCTAssertEqual(firstURL.pathExtension, "png")
        XCTAssertEqual(try Data(contentsOf: firstURL), data)
        XCTAssertFalse(firstURL.lastPathComponent.contains(record.id.uuidString))
    }

    func testMissingExternalImageFallsBackToManagedCopy() throws {
        let store = makeStore()
        let externalURL = rootURL.appendingPathComponent("Moved Screenshot.jpg")
        try Data("external-image".utf8).write(to: externalURL)
        let managedData = Data("managed-png".utf8)
        let record = try store.addImage(
            data: managedData,
            kind: .screenshot,
            createdAt: Date(),
            pixelWidth: 640,
            pixelHeight: 400,
            externalURL: externalURL
        )
        try FileManager.default.removeItem(at: externalURL)

        let result = try makeProvider().dragURL(for: record, store: store)

        XCTAssertTrue(result.lastPathComponent.hasPrefix("Screenshot "))
        XCTAssertEqual(result.pathExtension, "png")
        XCTAssertEqual(try Data(contentsOf: result), managedData)
    }

    func testItemProviderAdvertisesFileURLAndSuggestedName() throws {
        let store = makeStore()
        let record = try store.addImage(
            data: Data("managed-png".utf8),
            kind: .pinnedScreenshot,
            createdAt: Date(timeIntervalSince1970: 1_000),
            pixelWidth: 320,
            pixelHeight: 200
        )
        let provider = try makeProvider().itemProvider(for: record, store: store)

        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
        XCTAssertTrue(provider.suggestedName?.hasPrefix("Pinned Screenshot ") == true)
        XCTAssertEqual(provider.suggestedName?.hasSuffix(".png"), true)
    }

    func testMissingVideoFailsInsteadOfCreatingFakeFile() throws {
        let videoURL = rootURL.appendingPathComponent("Recording.mp4")
        try Data("video".utf8).write(to: videoURL)
        let store = makeStore()
        let record = try store.addVideo(url: videoURL, createdAt: Date())
        try FileManager.default.removeItem(at: videoURL)

        XCTAssertThrowsError(try makeProvider().dragURL(for: record, store: store)) { error in
            XCTAssertEqual(
                error as? CaptureDragItemProviderError,
                .fileMissing
            )
        }
    }

    private func makeProvider() -> CaptureDragItemProvider {
        CaptureDragItemProvider(cacheRootURL: cacheURL)
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
