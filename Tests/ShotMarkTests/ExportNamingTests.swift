import Foundation
import XCTest
@testable import ShotMark

final class ExportNamingTests: XCTestCase {
    func testDefaultTemplatePreservesExistingShotMarkFilename() throws {
        let date = try makeLocalDate(year: 2026, month: 7, day: 26, hour: 9, minute: 8, second: 7)

        let filename = ExportNaming.filename(
            template: ExportNaming.defaultTemplate,
            kind: .screenshot,
            createdAt: date,
            fileExtension: "png",
            randomToken: "unused"
        )

        XCTAssertEqual(filename, "Screenshot 2026-07-26 09.08.07.png")
    }

    func testTemplateExpandsAllPlaceholdersAndSanitizesPathCharacters() throws {
        let date = try makeLocalDate(year: 2026, month: 7, day: 26, hour: 19, minute: 3, second: 4)

        let filename = ExportNaming.filename(
            template: "{type}/{date}: {time}  {random}",
            kind: .longScreenshot,
            createdAt: date,
            fileExtension: "heic",
            randomToken: "a1b2c3"
        )

        XCTAssertEqual(filename, "Long Screenshot-2026-07-26- 19.03.04 a1b2c3.heic")
    }

    func testBlankTemplateFallsBackToDefault() throws {
        let date = try makeLocalDate(year: 2026, month: 1, day: 2, hour: 3, minute: 4, second: 5)

        let filename = ExportNaming.filename(
            template: "   ",
            kind: .recording,
            createdAt: date,
            fileExtension: "mp4"
        )

        XCTAssertEqual(filename, "Recording 2026-01-02 03.04.05.mp4")
    }

    func testUniqueURLAddsStableNumericSuffixWithoutOverwriting() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShotMarkNamingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let date = try makeLocalDate(year: 2026, month: 7, day: 26, hour: 9, minute: 8, second: 7)
        let existing = directory.appendingPathComponent("Screenshot 2026-07-26 09.08.07.png")
        try Data([0x01]).write(to: existing)

        let result = ExportNaming.uniqueURL(
            directory: directory,
            template: ExportNaming.defaultTemplate,
            kind: .screenshot,
            createdAt: date,
            fileExtension: "png"
        )

        XCTAssertEqual(result.lastPathComponent, "Screenshot 2026-07-26 09.08.07 2.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: existing.path))
    }

    private func makeLocalDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        second: Int
    ) throws -> Date {
        try XCTUnwrap(Calendar.current.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        )))
    }
}
