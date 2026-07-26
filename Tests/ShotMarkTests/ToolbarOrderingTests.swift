import XCTest
@testable import ShotMark

final class ToolbarOrderingTests: XCTestCase {
    func testNumericShortcutButtonsComeFirstInOneThroughNineOrder() {
        let buttons = Array(SelectionOverlayView.OverlayButton.toolbarOrder.prefix(9))

        XCTAssertEqual(
            buttons,
            [.callout, .rectangle, .arrow, .number, .mosaic, .ocr, .pin, .longScreenshot, .record]
        )
        XCTAssertEqual(buttons.compactMap(\.defaultShortcutKey), (1...9).map(String.init))
    }

    func testLetterShortcutButtonsFollowNumericTools() {
        let buttons = Array(SelectionOverlayView.OverlayButton.toolbarOrder.dropFirst(9).prefix(4))

        XCTAssertEqual(buttons, [.ellipse, .pen, .highlighter, .text])
        XCTAssertEqual(buttons.compactMap(\.defaultShortcutKey), ["E", "P", "H", "T"])
    }

    func testToolbarOrderContainsEveryButtonExactlyOnce() {
        let order = SelectionOverlayView.OverlayButton.toolbarOrder

        XCTAssertEqual(order.count, SelectionOverlayView.OverlayButton.allCases.count)
        XCTAssertEqual(Set(order), Set(SelectionOverlayView.OverlayButton.allCases))
    }

    func testToolbarButtonPersistenceIDsAreStableAndUnique() {
        let buttons = SelectionOverlayView.OverlayButton.allCases
        let ids = buttons.map(\.persistenceID)

        XCTAssertEqual(Set(ids).count, buttons.count)
        XCTAssertEqual(
            ids.compactMap(SelectionOverlayView.OverlayButton.init(persistenceID:)),
            buttons
        )
    }

    func testToolbarShortcutPreferencesSurviveSettingsRecreation() throws {
        let suiteName = "ShotMarkTests.ToolbarShortcuts.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let expected = ToolbarShortcutPreferences(
            overrides: ["mosaic": "M", "ocr": "F6"],
            clearedButtonIDs: ["pin"]
        )

        AppSettings(defaults: defaults).setToolbarShortcutPreferences(expected)

        XCTAssertEqual(AppSettings(defaults: defaults).toolbarShortcutPreferences, expected)
    }
}
