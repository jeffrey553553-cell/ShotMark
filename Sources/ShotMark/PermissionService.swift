import ApplicationServices
import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

enum PermissionService {
    static var hasScreenRecordingAccess: Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func verifyScreenRecordingAccess(completion: @escaping (Bool) -> Void) {
        if hasScreenRecordingAccess {
            completion(true)
            return
        }

        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            if error != nil {
                completion(false)
                return
            }
            completion(!(content?.displays.isEmpty ?? true))
        }
    }

    @discardableResult
    static func requestScreenRecordingAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static var hasAccessibilityAccess: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestAccessibilityAccess() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openPrivacySettings() {
        openScreenRecordingSettings()
    }

    static var hasMicrophoneAccess: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestMicrophoneAccess(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { isGranted in
                completion(isGranted)
            }
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }

    static func openScreenRecordingSettings() {
        openSettingsURL([
            "x-apple.systempreferences:com.apple.SystemSettings.PrivacySecurity.extension?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy"
        ])
    }

    static func openAccessibilitySettings() {
        openSettingsURL([
            "x-apple.systempreferences:com.apple.SystemSettings.PrivacySecurity.extension?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy"
        ])
    }

    static func openMicrophoneSettings() {
        openSettingsURL([
            "x-apple.systempreferences:com.apple.SystemSettings.PrivacySecurity.extension?Privacy_Microphone",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
            "x-apple.systempreferences:com.apple.preference.security?Privacy"
        ])
    }

    static func isLikelyScreenRecordingPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        let text = "\(nsError.domain) \(nsError.code) \(nsError.localizedDescription)".lowercased()
        return text.contains("screencapture")
            || text.contains("screen capture")
            || text.contains("screen recording")
            || text.contains("not authorized")
            || text.contains("permission")
            || text.contains("denied")
            || text.contains("录制权限")
            || text.contains("屏幕录制")
    }

    private static func openSettingsURL(_ candidates: [String]) {
        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            NSWorkspace.shared.open(url)
            return
        }
    }
}
