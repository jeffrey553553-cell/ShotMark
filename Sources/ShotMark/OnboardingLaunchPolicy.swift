import AppKit
import Foundation

enum OnboardingLaunchDecision: Equatable {
    case skip
    case present
    case migrateExistingUser
}

enum OnboardingLaunchPolicy {
    static func decision(
        hasCompletedOnboarding: Bool,
        hasPresentedOnboarding: Bool,
        hasScreenRecordingAccess: Bool
    ) -> OnboardingLaunchDecision {
        if hasCompletedOnboarding {
            return .skip
        }
        if hasPresentedOnboarding {
            return .present
        }
        if hasScreenRecordingAccess {
            return .migrateExistingUser
        }
        return .present
    }
}

enum ApplicationRelauncher {
    static func helperArguments(bundlePath: String) -> [String] {
        [
            "-c",
            "sleep 1; exec /usr/bin/open -n \"$1\"",
            "shotmark-relaunch",
            bundlePath
        ]
    }

    static func relaunch(bundleURL: URL = Bundle.main.bundleURL) {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = helperArguments(bundlePath: bundleURL.path)
        do {
            try helper.run()
            NSApp.terminate(nil)
        } catch {
            NSWorkspace.shared.open(bundleURL)
            NSApp.terminate(nil)
        }
    }
}
