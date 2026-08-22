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

    func testTextAndMoreFollowNumericTools() {
        let buttons = Array(SelectionOverlayView.OverlayButton.toolbarOrder.dropFirst(9).prefix(2))

        XCTAssertEqual(buttons, [.text, .more])
        XCTAssertEqual(buttons.compactMap(\.defaultShortcutKey), ["T"])
    }

    func testSecondaryDrawingToolsLiveOnlyInMoreMenu() {
        let order = SelectionOverlayView.OverlayButton.toolbarOrder

        XCTAssertEqual(SelectionOverlayView.OverlayButton.moreTools, [.ellipse, .pen, .highlighter])
        XCTAssertTrue(SelectionOverlayView.OverlayButton.moreTools.allSatisfy { !order.contains($0) })
        XCTAssertEqual(
            SelectionOverlayView.OverlayButton.moreTools.compactMap(\.defaultShortcutKey),
            ["E", "P", "H"]
        )
    }

    func testToolbarAndMoreMenuContainEveryButtonExactlyOnce() {
        let combined = SelectionOverlayView.OverlayButton.toolbarOrder
            + SelectionOverlayView.OverlayButton.moreTools

        XCTAssertEqual(combined.count, SelectionOverlayView.OverlayButton.allCases.count)
        XCTAssertEqual(Set(combined), Set(SelectionOverlayView.OverlayButton.allCases))
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
