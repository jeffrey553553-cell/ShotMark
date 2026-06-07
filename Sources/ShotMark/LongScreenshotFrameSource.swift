import AppKit
import CoreImage
import CoreMedia
import Foundation
import ScreenCaptureKit

enum LongScreenshotFrameSourceError: LocalizedError {
    case noDisplay

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            "没有找到要采集的显示器。"
        }
    }
}

final class LongScreenshotFrameSource: NSObject {
    var onFrame: ((LongScreenshotFrame) -> Void)?
    var onFailure: ((Error) -> Void)?

    private let sampleQueue = DispatchQueue(label: "com.shotmark.long-screenshot.stream", qos: .userInteractive)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let minimumPublishInterval: TimeInterval

    private var stream: SCStream?
    private var lastPublishedAt: TimeInterval = 0
    private var nextSequenceNumber = 0

    init(previewFPS: Int = 30) {
        minimumPublishInterval = 1.0 / Double(max(1, previewFPS))
    }

    var isRunning: Bool {
        stream != nil
    }

    func start(selection: CaptureSelection, completion: @escaping (Result<Void, Error>) -> Void) {
        stop()
        lastPublishedAt = 0
        nextSequenceNumber = 0

        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            guard let self else { return }
            if let error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }

            guard
                let displayID = selection.screen.shotMarkDisplayID,
                let display = content?.displays.first(where: { $0.displayID == displayID })
            else {
                DispatchQueue.main.async { completion(.failure(LongScreenshotFrameSourceError.noDisplay)) }
                return
            }

            let filter: SCContentFilter
            if let currentApplication = content?.applications.first(where: { $0.processID == getpid() }) {
                filter = SCContentFilter(display: display, excludingApplications: [currentApplication], exceptingWindows: [])
            } else {
                let ownBundleIdentifier = Bundle.main.bundleIdentifier
                let excludedWindows = content?.windows.filter { window in
                    window.owningApplication?.bundleIdentifier == ownBundleIdentifier
                } ?? []
                filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
            }

            let configuration = self.streamConfiguration(for: selection)
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)

            do {
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.sampleQueue)
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }

            DispatchQueue.main.async {
                self.stream = stream
                stream.startCapture { [weak self, weak stream] error in
                    DispatchQueue.main.async {
                        guard let self, self.stream === stream else { return }
                        if let error {
                            self.stop()
                            completion(.failure(error))
                            return
                        }
                        completion(.success(()))
                    }
                }
            }
        }
    }

    func stop() {
        let activeStream = stream
        stream = nil
        guard let activeStream else { return }

        do {
            try activeStream.removeStreamOutput(self, type: .screen)
        } catch {
            // Best-effort teardown. The stream may already be stopping.
        }

        activeStream.stopCapture(completionHandler: nil)
    }

    private func streamConfiguration(for selection: CaptureSelection) -> SCStreamConfiguration {
        let scale = max(1, selection.screen.backingScaleFactor)
        let configuration = SCStreamConfiguration()
        configuration.width = max(2, Int((selection.rectInScreen.width * scale).rounded()))
        configuration.height = max(2, Int((selection.rectInScreen.height * scale).rounded()))
        configuration.sourceRect = sourceRect(for: selection)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.scalesToFit = false
        configuration.preservesAspectRatio = true
        configuration.showsCursor = false
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 6
        configuration.captureResolution = .best
        configuration.shouldBeOpaque = true
        return configuration
    }

    private func sourceRect(for selection: CaptureSelection) -> CGRect {
        let screenFrame = selection.screen.frame
        let local = selection.rectInScreen.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
        return CGRect(
            x: local.minX,
            y: screenFrame.height - local.maxY,
            width: local.width,
            height: local.height
        ).integral
    }
}

extension LongScreenshotFrameSource: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        autoreleasepool {
            guard type == .screen, sampleBuffer.isValid else { return }
            guard let pixelBuffer = sampleBuffer.imageBuffer else { return }

            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
               let statusRaw = attachments.first?[.status] as? Int,
               let status = SCFrameStatus(rawValue: statusRaw),
               status != .complete {
                return
            }

            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastPublishedAt >= minimumPublishInterval else { return }

            let imageRect = CGRect(
                x: 0,
                y: 0,
                width: CVPixelBufferGetWidth(pixelBuffer),
                height: CVPixelBufferGetHeight(pixelBuffer)
            )
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            guard let cgImage = ciContext.createCGImage(ciImage, from: imageRect) else { return }

            lastPublishedAt = now
            nextSequenceNumber += 1
            let frame = LongScreenshotFrame(sequenceNumber: nextSequenceNumber, image: cgImage, capturedAt: Date())

            DispatchQueue.main.async { [weak self] in
                self?.onFrame?(frame)
            }
        }
    }
}

extension LongScreenshotFrameSource: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.onFailure?(error)
        }
    }
}
