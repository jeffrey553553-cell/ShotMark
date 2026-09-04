import AppKit
import XCTest
@testable import ShotMark

@MainActor
final class OnboardingUITests: XCTestCase {
    func testOnboardingRendersInLightAndDarkAppearances() throws {
        try render(appearance: .aqua, path: "/tmp/shotmark-onboarding-light.png")
        try render(appearance: .darkAqua, path: "/tmp/shotmark-onboarding-dark.png")
    }

    private func render(appearance: NSAppearance.Name, path: String) throws {
        let application = NSApplication.shared
        let previousAppearance = application.appearance
        application.appearance = NSAppearance(named: appearance)
        defer { application.appearance = previousAppearance }

        let controller = OnboardingWindowController(
            shortcut: .defaultShortcut,
            initialPermissions: OnboardingPermissionSnapshot(
                screenRecordingGranted: false,
                accessibilityGranted: false
            ),
            appIcon: try XCTUnwrap(NSImage(contentsOfFile: "Resources/ShotMarkIcon.png")),
            onStartCapture: {},
            onDismiss: {},
            onRelaunch: {}
        )
        let window = try XCTUnwrap(controller.window)
        controller.showWindow(nil)
        window.orderFrontRegardless()
        defer {
            window.delegate = nil
            controller.close()
        }
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        view.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let scale = window.backingScaleFactor
        XCTAssertEqual(bitmap.pixelsWide, Int((view.bounds.width * scale).rounded()))
        XCTAssertEqual(bitmap.pixelsHigh, Int((view.bounds.height * scale).rounded()))

        if ProcessInfo.processInfo.environment["SHOTMARK_WRITE_UI_SNAPSHOTS"] == "1" {
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: path))
        }
    }
}
