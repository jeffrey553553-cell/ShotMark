import AppKit
import CoreGraphics
import Foundation

enum CaptureAreaError: LocalizedError {
    case previousDisplayUnavailable

    var errorDescription: String? {
        switch self {
        case .previousDisplayUnavailable:
            return "上次使用的显示器当前不可用。请重新框选一次，ShotMark 会记住新的区域。"
        }
    }
}

struct CaptureDisplayDescriptor: Equatable {
    let displayID: UInt32?
    let displayUUID: String?
    let frame: CGRect
}

struct StoredCaptureArea: Codable, Equatable {
    let displayID: UInt32?
    let displayUUID: String?
    let displayFrame: CGRect
    let normalizedRect: CGRect

    init(selection: CaptureSelection) {
        let screen = selection.screen
        let localRect = selection.rectInScreen.offsetBy(
            dx: -screen.frame.minX,
            dy: -screen.frame.minY
        )
        displayID = screen.shotMarkDisplayID
        displayUUID = screen.shotMarkDisplayUUID
        displayFrame = screen.frame
        normalizedRect = Self.normalize(localRect, inside: screen.frame.size)
    }

    init(
        displayID: UInt32?,
        displayUUID: String?,
        displayFrame: CGRect,
        normalizedRect: CGRect
    ) {
        self.displayID = displayID
        self.displayUUID = displayUUID
        self.displayFrame = displayFrame
        self.normalizedRect = normalizedRect
    }

    func resolve(in screens: [NSScreen]) -> CaptureSelection? {
        let descriptors = screens.map {
            CaptureDisplayDescriptor(
                displayID: $0.shotMarkDisplayID,
                displayUUID: $0.shotMarkDisplayUUID,
                frame: $0.frame
            )
        }
        guard
            let index = resolvedDisplayIndex(in: descriptors),
            screens.indices.contains(index),
            let rect = resolvedRect(on: descriptors[index].frame)
        else {
            return nil
        }
        return CaptureSelection(rectInScreen: rect, screen: screens[index])
    }

    func resolvedDisplayIndex(in displays: [CaptureDisplayDescriptor]) -> Int? {
        if let displayUUID,
           let index = displays.firstIndex(where: { $0.displayUUID == displayUUID }) {
            return index
        }
        if let displayID,
           let index = displays.firstIndex(where: { $0.displayID == displayID }) {
            return index
        }
        if let index = displays.firstIndex(where: { $0.frame == displayFrame }) {
            return index
        }
        return displays.count == 1 ? displays.indices.first : nil
    }

    func resolvedRect(on screenFrame: CGRect) -> CGRect? {
        guard
            screenFrame.width > 0,
            screenFrame.height > 0,
            normalizedRect.width > 0,
            normalizedRect.height > 0
        else {
            return nil
        }

        let clampedNormalized = normalizedRect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clampedNormalized.isNull, clampedNormalized.width > 0, clampedNormalized.height > 0 else {
            return nil
        }
        let rect = CGRect(
            x: Self.roundedPoint(screenFrame.minX + clampedNormalized.minX * screenFrame.width),
            y: Self.roundedPoint(screenFrame.minY + clampedNormalized.minY * screenFrame.height),
            width: Self.roundedPoint(clampedNormalized.width * screenFrame.width),
            height: Self.roundedPoint(clampedNormalized.height * screenFrame.height)
        )
        return rect.width >= 8 && rect.height >= 8 ? rect : nil
    }

    private static func normalize(_ rect: CGRect, inside size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        return CGRect(
            x: rect.minX / size.width,
            y: rect.minY / size.height,
            width: rect.width / size.width,
            height: rect.height / size.height
        )
    }

    private static func roundedPoint(_ value: CGFloat) -> CGFloat {
        (value * 1_000).rounded() / 1_000
    }
}

extension NSScreen {
    var shotMarkDisplayUUID: String? {
        guard
            let displayID = shotMarkDisplayID,
            let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue()
        else {
            return nil
        }
        return CFUUIDCreateString(kCFAllocatorDefault, uuid) as String
    }
}
