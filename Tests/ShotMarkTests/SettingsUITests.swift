import AppKit
import SwiftUI
import XCTest
@testable import ShotMark

@MainActor
final class SettingsUITests: XCTestCase {
    func testDarkSettingsWindowRendersShortcutAndPermissionSections() throws {
        try renderSettings(
            appearanceName: .darkAqua,
            snapshotPath: "/tmp/shotmark-settings-dark.png"
        )
    }

    func testLightSettingsWindowRendersShortcutAndPermissionSections() throws {
        try renderSettings(
            appearanceName: .aqua,
            snapshotPath: "/tmp/shotmark-settings-light.png"
        )
    }

    private func renderSettings(
        appearanceName: NSAppearance.Name,
        snapshotPath: String
    ) throws {
        let application = NSApplication.shared
        let previousAppearance = application.appearance
        application.appearance = NSAppearance(named: appearanceName)
        defer { application.appearance = previousAppearance }
        let controller = SettingsWindowController(
            onShortcutChange: { _ in },
            onShortcutRecordingStateChange: { _ in },
            currentVersion: "0.1.52"
        )
        let window = try XCTUnwrap(controller.window)
        controller.showWindow(nil)
        window.orderFrontRegardless()
        defer { controller.close() }
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        view.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 500)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 500)

        if ProcessInfo.processInfo.environment["SHOTMARK_WRITE_UI_SNAPSHOTS"] == "1" {
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: snapshotPath))
        }
    }
}
