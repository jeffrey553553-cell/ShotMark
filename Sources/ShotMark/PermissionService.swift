import ApplicationServices
import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

enum MicrophonePermissionState: Equatable {
    case authorized
    case notDetermined
    case denied
    case restricted
    case unknown

    init(_ status: AVAuthorizationStatus) {
        switch status {
        case .authorized: self = .authorized
        case .notDetermined: self = .notDetermined
        case .denied: self = .denied
        case .restricted: self = .restricted
        @unknown default: self = .unknown
        }
    }

    var isAuthorized: Bool {
        self == .authorized
    }

    var statusText: String {
        switch self {
        case .authorized: "已允许"
        case .notDetermined: "尚未请求"
        case .denied: "已拒绝"
        case .restricted: "受系统限制"
        case .unknown: "状态未知"
        }
    }
}

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
        microphonePermissionState.isAuthorized
    }

    static var microphonePermissionState: MicrophonePermissionState {
        MicrophonePermissionState(AVCaptureDevice.authorizationStatus(for: .audio))
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
            if NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}
