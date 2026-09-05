import CoreGraphics
import XCTest
@testable import ShotMark

final class PreviousCaptureAreaTests: XCTestCase {
    func testPreviousAreaPersistsAcrossSettingsRecreation() throws {
        let suiteName = "PreviousCaptureAreaTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let area = StoredCaptureArea(
            displayID: 7,
            displayUUID: "persistent-display",
            displayFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            normalizedRect: CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.5)
        )

        AppSettings(defaults: defaults).setPreviousCaptureArea(area)

        XCTAssertEqual(AppSettings(defaults: defaults).previousCaptureArea, area)
    }

    func testMatchesDisplayByStableUUIDAfterDisplayOrderAndFrameChange() {
        let stored = StoredCaptureArea(
            displayID: 11,
            displayUUID: "external-display",
            displayFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            normalizedRect: CGRect(x: 0.25, y: 0.2, width: 0.5, height: 0.4)
        )
        let displays = [
            CaptureDisplayDescriptor(
                displayID: 22,
                displayUUID: "built-in-display",
                frame: CGRect(x: 0, y: 0, width: 1512, height: 982)
            ),
            CaptureDisplayDescriptor(
                displayID: 33,
                displayUUID: "external-display",
                frame: CGRect(x: -2560, y: 0, width: 2560, height: 1440)
            )
        ]

        XCTAssertEqual(stored.resolvedDisplayIndex(in: displays), 1)
        XCTAssertEqual(
            stored.resolvedRect(on: displays[1].frame),
            CGRect(x: -1920, y: 288, width: 1280, height: 576)
        )
    }

    func testFallsBackToDisplayIDWhenUUIDIsUnavailable() {
        let stored = StoredCaptureArea(
            displayID: 44,
            displayUUID: nil,
            displayFrame: .zero,
            normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.4)
        )
        let displays = [
            CaptureDisplayDescriptor(displayID: 55, displayUUID: nil, frame: CGRect(x: 0, y: 0, width: 100, height: 100)),
            CaptureDisplayDescriptor(displayID: 44, displayUUID: nil, frame: CGRect(x: 100, y: 0, width: 100, height: 100))
        ]

        XCTAssertEqual(stored.resolvedDisplayIndex(in: displays), 1)
    }

    func testDoesNotGuessWhenPreviousDisplayIsMissingFromMultiDisplaySetup() {
        let stored = StoredCaptureArea(
            displayID: 44,
            displayUUID: "missing",
            displayFrame: CGRect(x: 5000, y: 0, width: 1920, height: 1080),
            normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.4)
        )
        let displays = [
            CaptureDisplayDescriptor(displayID: 1, displayUUID: "one", frame: CGRect(x: 0, y: 0, width: 100, height: 100)),
            CaptureDisplayDescriptor(displayID: 2, displayUUID: "two", frame: CGRect(x: 100, y: 0, width: 100, height: 100))
        ]

        XCTAssertNil(stored.resolvedDisplayIndex(in: displays))
    }

    func testSingleDisplayFallbackPreservesRelativeArea() {
        let stored = StoredCaptureArea(
            displayID: 99,
            displayUUID: "removed",
            displayFrame: CGRect(x: 0, y: 0, width: 200, height: 100),
            normalizedRect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        )
        let display = CaptureDisplayDescriptor(
            displayID: 1,
            displayUUID: "only",
            frame: CGRect(x: 0, y: 0, width: 1000, height: 800)
        )

        XCTAssertEqual(stored.resolvedDisplayIndex(in: [display]), 0)
        XCTAssertEqual(
            stored.resolvedRect(on: display.frame),
            CGRect(x: 250, y: 200, width: 500, height: 400)
        )
    }

    func testRejectsTinyOrInvalidRestoredArea() {
        let stored = StoredCaptureArea(
            displayID: nil,
            displayUUID: nil,
            displayFrame: .zero,
            normalizedRect: CGRect(x: 0, y: 0, width: 0.001, height: 0.001)
        )

        XCTAssertNil(stored.resolvedRect(on: CGRect(x: 0, y: 0, width: 1000, height: 800)))
    }
}
