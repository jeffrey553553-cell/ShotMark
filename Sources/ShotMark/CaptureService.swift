import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

enum CaptureServiceError: LocalizedError {
    case noDisplay
    case captureFailed
    case cropFailed

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            return "没有找到可截图的显示器。"
        case .captureFailed:
            return "ScreenCaptureKit 没有返回截图。请检查屏幕录制权限。"
        case .cropFailed:
            return "截图裁剪失败。"
        }
    }
}

final class CaptureService {
    func capture(selection: CaptureSelection, completion: @escaping (Result<CaptureResult, Error>) -> Void) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            if let error {
                completion(.failure(error))
                return
            }

            guard
                let displayID = selection.screen.displayID,
                let display = content?.displays.first(where: { $0.displayID == displayID })
            else {
                completion(.failure(CaptureServiceError.noDisplay))
                return
            }

            let scale = selection.screen.backingScaleFactor
            let ownBundleIdentifier = Bundle.main.bundleIdentifier
            let excludedWindows = content?.windows.filter { window in
                window.owningApplication?.bundleIdentifier == ownBundleIdentifier
            } ?? []
            let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
            let config = SCStreamConfiguration()
            config.width = Int(selection.screen.frame.width * scale)
            config.height = Int(selection.screen.frame.height * scale)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = false
            config.captureResolution = .best
            config.shouldBeOpaque = true

            SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, error in
                if let error {
                    completion(.failure(error))
                    return
                }
                guard let fullImage = image else {
                    completion(.failure(CaptureServiceError.captureFailed))
                    return
                }

                let cropRect = self.cropRect(for: selection, fullImage: fullImage)
                guard let cropped = fullImage.cropping(to: cropRect) else {
                    completion(.failure(CaptureServiceError.cropFailed))
                    return
                }

                completion(.success(CaptureResult(
                    image: cropped,
                    selectionRectInScreen: selection.rectInScreen,
                    screenScale: scale,
                    createdAt: Date()
                )))
            }
        }
    }

    private func cropRect(for selection: CaptureSelection, fullImage: CGImage) -> CGRect {
        let screenFrame = selection.screen.frame
        let scaleX = CGFloat(fullImage.width) / screenFrame.width
        let scaleY = CGFloat(fullImage.height) / screenFrame.height
        let local = selection.rectInScreen.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)

        return CGRect(
            x: local.minX * scaleX,
            y: (screenFrame.height - local.maxY) * scaleY,
            width: local.width * scaleX,
            height: local.height * scaleY
        ).integral
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
