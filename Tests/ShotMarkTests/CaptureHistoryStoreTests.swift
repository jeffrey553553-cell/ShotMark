import Foundation
import XCTest
@testable import ShotMark

final class CaptureHistoryStoreTests: XCTestCase {
    private var rootURL: URL!

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShotMarkHistoryTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let rootURL {
            try? FileManager.default.removeItem(at: rootURL)
        }
    }

    func testImageRecordPersistsAndReloads() throws {
        let store = makeStore()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let record = try store.addImage(
            data: Data([1, 2, 3, 4]),
            kind: .screenshot,
            createdAt: createdAt,
            pixelWidth: 640,
            pixelHeight: 480
        )

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.records, [record])
        XCTAssertEqual(try XCTUnwrap(reloaded.resolvedURL(for: record)).lastPathComponent, "\(record.id.uuidString).png")
    }

    func testDeletingHistoryNeverDeletesExternalExport() throws {
        let externalURL = rootURL
            .deletingLastPathComponent()
            .appendingPathComponent("ShotMarkExternal-\(UUID().uuidString).png")
        try Data([8, 9, 10]).write(to: externalURL)
        defer { try? FileManager.default.removeItem(at: externalURL) }

        let store = makeStore()
        let record = try store.addImage(
            data: Data([1, 2, 3]),
            kind: .screenshot,
            createdAt: Date(),
            pixelWidth: 10,
            pixelHeight: 10,
            externalURL: externalURL
        )
        let internalURL = try XCTUnwrap(store.resolvedURL(for: record, preferExternal: false))

        try store.delete(id: record.id)

        XCTAssertTrue(FileManager.default.fileExists(atPath: externalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: internalURL.path))
        XCTAssertTrue(store.records.isEmpty)
    }

    func testVideoDeletionOnlyRemovesHistoryReference() throws {
        let videoURL = rootURL
            .deletingLastPathComponent()
            .appendingPathComponent("ShotMarkRecording-\(UUID().uuidString).mp4")
        try Data([0, 1, 2, 3]).write(to: videoURL)
        defer { try? FileManager.default.removeItem(at: videoURL) }

        let store = makeStore()
        let record = try store.addVideo(url: videoURL, createdAt: Date())
        try store.delete(id: record.id)

        XCTAssertTrue(FileManager.default.fileExists(atPath: videoURL.path))
        XCTAssertTrue(store.records.isEmpty)
    }

    func testMissingExternalImageFallsBackToManagedCopy() throws {
        let externalURL = rootURL
            .deletingLastPathComponent()
            .appendingPathComponent("ShotMarkMoved-\(UUID().uuidString).png")
        try Data([7, 8, 9]).write(to: externalURL)

        let store = makeStore()
        let record = try store.addImage(
            data: Data([1, 2, 3]),
            kind: .screenshot,
            createdAt: Date(),
            pixelWidth: 10,
            pixelHeight: 10,
            externalURL: externalURL
        )
        try FileManager.default.removeItem(at: externalURL)

        let resolved = try XCTUnwrap(store.resolvedURL(for: record))
        XCTAssertNotEqual(resolved.path, externalURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolved.path))
    }

    func testMissingExternalVideoCanStillBeRemovedFromHistory() throws {
        let videoURL = rootURL
            .deletingLastPathComponent()
            .appendingPathComponent("ShotMarkMissing-\(UUID().uuidString).mp4")
        try Data([0, 1, 2]).write(to: videoURL)
        let store = makeStore()
        let record = try store.addVideo(url: videoURL, createdAt: Date())
        try FileManager.default.removeItem(at: videoURL)

        XCTAssertNil(store.resolvedURL(for: record))
        try store.delete(id: record.id)
        XCTAssertTrue(store.records.isEmpty)
    }

    func testCorruptedIndexRecoversWithoutBlockingNewHistory() throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: rootURL.appendingPathComponent("index.json"))

        let store = makeStore()
        XCTAssertTrue(store.records.isEmpty)
        let record = try store.addImage(
            data: Data([1, 2, 3]),
            kind: .screenshot,
            createdAt: Date(),
            pixelWidth: 10,
            pixelHeight: 10
        )

        XCTAssertEqual(store.records, [record])
        let reloaded = try XCTUnwrap(makeStore().records.first)
        XCTAssertEqual(reloaded.id, record.id)
        XCTAssertEqual(reloaded.kind, record.kind)
        XCTAssertEqual(reloaded.createdAt.timeIntervalSince1970, record.createdAt.timeIntervalSince1970, accuracy: 0.001)
    }

    func testRetentionPrunesByCountAndDeletesOnlyManagedMedia() throws {
        let store = makeStore(policy: CaptureHistoryRetentionPolicy(maximumItemCount: 2, maximumAge: 0))
        for index in 0..<3 {
            try store.addImage(
                data: Data(repeating: UInt8(index), count: 4),
                kind: .screenshot,
                createdAt: Date(timeIntervalSince1970: TimeInterval(index + 1)),
                pixelWidth: 10,
                pixelHeight: 10
            )
        }

        XCTAssertEqual(store.records.count, 2)
        XCTAssertEqual(store.records.map(\.createdAt), [
            Date(timeIntervalSince1970: 3),
            Date(timeIntervalSince1970: 2)
        ])
        let mediaFiles = try FileManager.default.contentsOfDirectory(
            at: rootURL.appendingPathComponent("Media"),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(mediaFiles.count, 2)
    }

    func testRetentionPrunesByAge() throws {
        let now = Date()
        let store = makeStore(policy: CaptureHistoryRetentionPolicy(maximumItemCount: 0, maximumAge: 100))
        try store.addImage(
            data: Data([1]),
            kind: .screenshot,
            createdAt: now.addingTimeInterval(-101),
            pixelWidth: 1,
            pixelHeight: 1
        )
        try store.addImage(
            data: Data([2]),
            kind: .screenshot,
            createdAt: now.addingTimeInterval(-50),
            pixelWidth: 1,
            pixelHeight: 1
        )

        try store.prune(now: now)
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.records.first?.createdAt, now.addingTimeInterval(-50))
    }

    private func makeStore(
        policy: CaptureHistoryRetentionPolicy = CaptureHistoryRetentionPolicy(
            maximumItemCount: 200,
            maximumAge: 0
        )
    ) -> CaptureHistoryStore {
        CaptureHistoryStore(rootURL: rootURL, retentionPolicy: policy)
    }
}
