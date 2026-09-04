import XCTest
@testable import ShotMark

final class OnboardingLaunchPolicyTests: XCTestCase {
    func testFreshInstallWithoutPermissionPresentsOnboarding() {
        XCTAssertEqual(
            OnboardingLaunchPolicy.decision(
                hasCompletedOnboarding: false,
                hasPresentedOnboarding: false,
                hasScreenRecordingAccess: false
            ),
            .present
        )
    }

    func testStartedOnboardingRemainsRecoverableAfterRelaunch() {
        XCTAssertEqual(
            OnboardingLaunchPolicy.decision(
                hasCompletedOnboarding: false,
                hasPresentedOnboarding: true,
                hasScreenRecordingAccess: true
            ),
            .present
        )
    }

    func testExistingAuthorizedUserMigratesWithoutInterruption() {
        XCTAssertEqual(
            OnboardingLaunchPolicy.decision(
                hasCompletedOnboarding: false,
                hasPresentedOnboarding: false,
                hasScreenRecordingAccess: true
            ),
            .migrateExistingUser
        )
    }

    func testCompletedOnboardingNeverReopensAutomatically() {
        XCTAssertEqual(
            OnboardingLaunchPolicy.decision(
                hasCompletedOnboarding: true,
                hasPresentedOnboarding: true,
                hasScreenRecordingAccess: false
            ),
            .skip
        )
    }

    func testOnboardingStatePersistsAcrossSettingsInstances() {
        let suiteName = "ShotMarkOnboardingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.hasPresentedOnboarding)
        XCTAssertFalse(settings.hasCompletedOnboarding)
        settings.hasPresentedOnboarding = true
        settings.hasCompletedOnboarding = true

        let restored = AppSettings(defaults: defaults)
        XCTAssertTrue(restored.hasPresentedOnboarding)
        XCTAssertTrue(restored.hasCompletedOnboarding)
    }

    func testRelaunchUsesBundlePathAsArgumentInsteadOfShellInterpolation() {
        let path = "/Applications/Shot Mark's Test.app"
        let arguments = ApplicationRelauncher.helperArguments(bundlePath: path)
        XCTAssertEqual(arguments.last, path)
        XCTAssertFalse(arguments[1].contains(path))
        XCTAssertEqual(arguments[2], "shotmark-relaunch")
    }
}
