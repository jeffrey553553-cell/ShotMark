import ApplicationServices
import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

struct WindowCandidate {
    let id: CGWindowID
    let processID: pid_t
    let title: String
    let ownerName: String
    let screenRect: CGRect
    let localRect: CGRect
    let source: String
}

final class WindowDetectionService {
    private struct RawWindow {
        var id: CGWindowID
        var processID: pid_t
        var title: String
        var ownerName: String
        var quartzRect: CGRect
        var appKitRect: CGRect?
        var layer: Int
        var alpha: Double
        var order: Int
        var source: String
    }

    func candidates(for screen: NSScreen, completion: @escaping ([WindowCandidate]) -> Void) {
        let cgWindows = cgWindowMap()
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, _ in
            let raw = self.mergedWindows(screen: screen, shareableWindows: content?.windows ?? [], cgWindows: cgWindows)
            let calibrated = self.calibrateWithAccessibilityIfPossible(raw)
            let candidates = self.candidates(from: calibrated, for: screen)
            DispatchQueue.main.async {
                completion(candidates)
            }
        }
    }

    func candidatesSynchronously(for screen: NSScreen) -> [WindowCandidate] {
        candidates(from: Array(cgWindowMap().values), for: screen)
    }

    private func mergedWindows(screen: NSScreen, shareableWindows: [SCWindow], cgWindows: [CGWindowID: RawWindow]) -> [RawWindow] {
        var merged: [RawWindow] = []
        var seen = Set<CGWindowID>()

        for scWindow in shareableWindows {
            let id = scWindow.windowID
            guard scWindow.isOnScreen else { continue }
            guard let app = scWindow.owningApplication else { continue }
            let processID = app.processID
            guard processID != getpid() else { continue }

            let cg = cgWindows[id]
            let frame = scWindow.frame
            let layer = Int(scWindow.windowLayer)
            let alpha = cg?.alpha ?? 1
            let ownerName = app.applicationName
            let title = scWindow.title ?? cg?.title ?? ""
            let appKitFrame = appKitRect(fromQuartzRect: frame, on: screen)
            guard !isIgnoredWindow(ownerName: ownerName, title: title, rect: appKitFrame, layer: layer, alpha: alpha, screen: screen) else {
                continue
            }

            merged.append(RawWindow(
                id: id,
                processID: processID,
                title: title,
                ownerName: ownerName,
                quartzRect: frame,
                appKitRect: appKitFrame,
                layer: layer,
                alpha: alpha,
                order: cg?.order ?? merged.count + 10_000,
                source: cg == nil ? "sck" : "sck+cg"
            ))
            seen.insert(id)
        }

        for window in cgWindows.values where !seen.contains(window.id) {
            guard !isIgnoredWindow(
                ownerName: window.ownerName,
                title: window.title,
                rect: appKitRect(for: window, on: screen),
                layer: window.layer,
                alpha: window.alpha,
                screen: screen
            ) else {
                continue
            }
            var fallback = window
            fallback.appKitRect = appKitRect(for: window, on: screen)
            merged.append(fallback)
        }

        return merged.sorted { first, second in
            if first.layer != second.layer {
                return first.layer < second.layer
            }
            return first.order < second.order
        }
    }

    private func cgWindowMap() -> [CGWindowID: RawWindow] {
        guard let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }

        var result: [CGWindowID: RawWindow] = [:]
        for (order, info) in windowInfo.enumerated() {
            guard
                let windowID = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                (info[kCGWindowIsOnscreen as String] as? Bool) != false,
                let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary
            else {
                continue
            }

            var rect = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsDictionary as CFDictionary, &rect) else {
                continue
            }

            let ownerName = (info[kCGWindowOwnerName as String] as? String) ?? ""
            let title = (info[kCGWindowName as String] as? String) ?? ""
            result[CGWindowID(windowID)] = RawWindow(
                id: CGWindowID(windowID),
                processID: ownerPID,
                title: title,
                ownerName: ownerName,
                quartzRect: rect,
                appKitRect: nil,
                layer: layer,
                alpha: (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
                order: order,
                source: "cg"
            )
        }
        return result
    }

    private func calibrateWithAccessibilityIfPossible(_ windows: [RawWindow]) -> [RawWindow] {
        guard PermissionService.hasAccessibilityAccess else {
            return windows
        }

        var axRectsByPID: [pid_t: [CGRect]] = [:]
        for processID in Set(windows.map(\.processID)) {
            axRectsByPID[processID] = accessibilityWindowRects(for: processID)
        }

        return windows.map { window in
            guard let rects = axRectsByPID[window.processID], !rects.isEmpty else {
                return window
            }
            guard let best = rects.min(by: {
                rectDistance($0, window.appKitRect ?? window.quartzRect) < rectDistance($1, window.appKitRect ?? window.quartzRect)
            }) else {
                return window
            }
            guard rectDistance(best, window.appKitRect ?? window.quartzRect) <= 80 else {
                return window
            }
            var calibrated = window
            calibrated.appKitRect = best
            calibrated.source += "+ax"
            return calibrated
        }
    }

    private func accessibilityWindowRects(for processID: pid_t) -> [CGRect] {
        let app = AXUIElementCreateApplication(processID)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement]
        else {
            return []
        }

        return elements.compactMap { element in
            var positionValue: CFTypeRef?
            var sizeValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
                  AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
                  let positionAX = positionValue,
                  let sizeAX = sizeValue
            else {
                return nil
            }

            guard CFGetTypeID(positionAX) == AXValueGetTypeID(),
                  CFGetTypeID(sizeAX) == AXValueGetTypeID()
            else {
                return nil
            }

            var origin = CGPoint.zero
            var size = CGSize.zero
            guard AXValueGetValue(positionAX as! AXValue, .cgPoint, &origin),
                  AXValueGetValue(sizeAX as! AXValue, .cgSize, &size)
            else {
                return nil
            }

            return CGRect(origin: origin, size: size).integral
        }
    }

    private func candidates(from windows: [RawWindow], for screen: NSScreen) -> [WindowCandidate] {
        windows.compactMap { window in
            guard !isIgnoredWindow(
                ownerName: window.ownerName,
                title: window.title,
                rect: appKitRect(for: window, on: screen),
                layer: window.layer,
                alpha: window.alpha,
                screen: screen
            ) else {
                return nil
            }

            let windowRect = appKitRect(for: window, on: screen)
            let clipped = windowRect.intersection(screen.frame).integral
            guard !clipped.isNull, !clipped.isEmpty, clipped.width >= 48, clipped.height >= 48 else {
                return nil
            }

            let local = clipped.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
            return WindowCandidate(
                id: window.id,
                processID: window.processID,
                title: window.title,
                ownerName: window.ownerName,
                screenRect: clipped,
                localRect: local,
                source: window.source
            )
        }
    }

    private func isIgnoredWindow(ownerName: String, title: String, rect: CGRect, layer: Int, alpha: Double, screen: NSScreen) -> Bool {
        if layer != 0 || alpha <= 0.05 {
            return true
        }
        if ownerName == "Window Server" || ownerName == "Dock" || ownerName == "ShotMark" {
            return true
        }
        if title == "Desktop" || title == "Backstop Menubar" {
            return true
        }

        let clipped = rect.intersection(screen.frame)
        if clipped.isNull || clipped.isEmpty {
            return true
        }

        let isNearlyFullScreen = clipped.width >= screen.frame.width - 2 && clipped.height >= screen.frame.height - 2
        return isNearlyFullScreen && title.isEmpty
    }

    private func rectDistance(_ first: CGRect, _ second: CGRect) -> CGFloat {
        abs(first.minX - second.minX)
            + abs(first.minY - second.minY)
            + abs(first.width - second.width)
            + abs(first.height - second.height)
    }

    private func appKitRect(for window: RawWindow, on screen: NSScreen) -> CGRect {
        if let appKitRect = window.appKitRect {
            return appKitRect
        }
        return appKitRect(fromQuartzRect: window.quartzRect, on: screen)
    }

    private func appKitRect(fromQuartzRect quartzRect: CGRect, on screen: NSScreen) -> CGRect {
        guard let displayID = screen.shotMarkDisplayID else {
            return quartzRect
        }

        let displayBounds = CGDisplayBounds(displayID)
        let localX = quartzRect.minX - displayBounds.minX
        let localYFromTop = quartzRect.minY - displayBounds.minY
        return CGRect(
            x: screen.frame.minX + localX,
            y: screen.frame.maxY - localYFromTop - quartzRect.height,
            width: quartzRect.width,
            height: quartzRect.height
        ).integral
    }
}
